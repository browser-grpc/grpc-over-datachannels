//go:build kafka_native

package grpcdc_test

// Kafka differential (Go): the same transactional and
// share-group scenarios through both form factors against the
// same broker — mirroring the Python and JS differentials.
// Env-gated: KAFKA_E2E_BROKER=host:port (native) and
// KAFKA_E2E_PROXY_ADDR=host:port (kafka_proxy --tcp). Skipped
// otherwise.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"testing"
	"time"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	kafkav1 "github.com/browser-grpc/grpc-over-datachannels/go/kafka"
)

func diffSetup(t *testing.T) (*kafkav1.KafkaNativeClient, *kafkav1.KafkaClient, string) {
	t.Helper()
	broker := os.Getenv("KAFKA_E2E_BROKER")
	proxyAddr := os.Getenv("KAFKA_E2E_PROXY_ADDR")
	if broker == "" || proxyAddr == "" {
		t.Skip("KAFKA_E2E_BROKER / KAFKA_E2E_PROXY_ADDR not set")
	}
	native, err := kafkav1.NewKafkaNativeClient(broker)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(native.Close)
	transport, err := grpcdc.DialSidecar(proxyAddr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { transport.Close() })
	proxy := kafkav1.NewKafkaClient(grpcdc.NewChannel(transport))

	suffix := make([]byte, 8)
	_, _ = rand.Read(suffix)
	topic := "go-kafka-diff-" + hex.EncodeToString(suffix)
	created, err := native.CreateTopics(&kafkav1.CreateTopicsRequest{
		Topics:    []*kafkav1.NewTopic{{Name: topic, NumPartitions: 1, ReplicationFactor: 1}},
		TimeoutMs: 15000,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(created.Results) != 1 || created.Results[0].ErrorCode != 0 {
		t.Fatalf("create topics: %+v", created.Results)
	}
	t.Cleanup(func() {
		_, _ = native.DeleteTopics(&kafkav1.DeleteTopicsRequest{Topics: []string{topic}, TimeoutMs: 15000})
	})
	return native, proxy, topic
}

func TestKafkaDifferentialTransactional(t *testing.T) {
	native, proxy, topic := diffSetup(t)
	ctx := context.Background()

	txnNative := func(label string, commit bool) {
		opened, err := native.OpenProducer(&kafkav1.OpenProducerRequest{
			TransactionalId: "grpc-dc-go-diff-txn-" + label, TransactionTimeoutMs: 60000})
		if err != nil {
			t.Fatal(err)
		}
		if opened.ErrorCode != 0 {
			t.Fatalf("open producer: %+v", opened)
		}
		produced, err := native.Produce(&kafkav1.ProduceRequest{
			Topic: topic, Partition: 0, Acks: kafkav1.Acks_ACKS_ALL,
			Records:   []*kafkav1.Record{{Value: []byte(label)}},
			SessionId: opened.SessionId})
		if err != nil {
			t.Fatal(err)
		}
		if produced.ErrorCode != 0 {
			t.Fatalf("produce: %+v", produced)
		}
		ended, err := native.EndTransaction(&kafkav1.EndTransactionRequest{SessionId: opened.SessionId, Commit: commit})
		if err != nil {
			t.Fatal(err)
		}
		if ended.ErrorCode != 0 {
			t.Fatalf("end txn: %+v", ended)
		}
	}
	txnProxy := func(label string, commit bool) {
		opened, err := proxy.OpenProducer(ctx, &kafkav1.OpenProducerRequest{
			TransactionalId: "grpc-dc-go-diff-txn-" + label, TransactionTimeoutMs: 60000})
		if err != nil {
			t.Fatal(err)
		}
		if opened.ErrorCode != 0 {
			t.Fatalf("open producer: %+v", opened)
		}
		produced, err := proxy.Produce(ctx, &kafkav1.ProduceRequest{
			Topic: topic, Partition: 0, Acks: kafkav1.Acks_ACKS_ALL,
			Records:   []*kafkav1.Record{{Value: []byte(label)}},
			SessionId: opened.SessionId})
		if err != nil {
			t.Fatal(err)
		}
		if produced.ErrorCode != 0 {
			t.Fatalf("produce: %+v", produced)
		}
		ended, err := proxy.EndTransaction(ctx, &kafkav1.EndTransactionRequest{SessionId: opened.SessionId, Commit: commit})
		if err != nil {
			t.Fatal(err)
		}
		if ended.ErrorCode != 0 {
			t.Fatalf("end txn: %+v", ended)
		}
	}

	consumeCommittedNative := func(want int) []string {
		deadline := time.Now().Add(20 * time.Second)
		for time.Now().Before(deadline) {
			stream, err := native.Consume(&kafkav1.ConsumeRequest{
				Topic: topic, Partition: 0, Offset: -2, MaxRecords: 10, MaxWaitMs: 1000, ReadCommitted: true})
			if err != nil {
				t.Fatal(err)
			}
			values := []string{}
			for {
				chunk, ok, err := stream.Next()
				if err != nil {
					t.Fatal(err)
				}
				if !ok {
					break
				}
				for _, r := range chunk.Records {
					values = append(values, string(r.Value))
				}
				if len(values) >= want {
					break
				}
			}
			stream.Close()
			if len(values) >= want {
				return values
			}
			time.Sleep(250 * time.Millisecond)
		}
		t.Fatalf("read_committed consume timed out (want %d)", want)
		return nil
	}
	consumeCommittedProxy := func(want int) []string {
		deadline := time.Now().Add(20 * time.Second)
		for time.Now().Before(deadline) {
			stream, err := proxy.Consume(ctx, &kafkav1.ConsumeRequest{
				Topic: topic, Partition: 0, Offset: -2, MaxRecords: 10, MaxWaitMs: 1000, ReadCommitted: true})
			if err != nil {
				t.Fatal(err)
			}
			values := []string{}
			for len(values) < want {
				chunk, err := stream.Recv()
				if err != nil {
					break
				}
				for _, r := range chunk.Records {
					values = append(values, string(r.Value))
				}
			}
			if len(values) >= want {
				return values
			}
			time.Sleep(250 * time.Millisecond)
		}
		t.Fatalf("read_committed consume timed out (want %d)", want)
		return nil
	}

	// Proxy transacts, native reads committed; then swapped.
	txnProxy("tx-proxy-commit", true)
	txnProxy("tx-proxy-abort", false)
	if got := consumeCommittedNative(1); len(got) != 1 || got[0] != "tx-proxy-commit" {
		t.Fatalf("native read_committed = %v", got)
	}
	txnNative("tx-native-commit", true)
	txnNative("tx-native-abort", false)
	if got := consumeCommittedProxy(2); len(got) != 2 || got[0] != "tx-proxy-commit" || got[1] != "tx-native-commit" {
		t.Fatalf("proxy read_committed = %v", got)
	}
}

func TestKafkaDifferentialShare(t *testing.T) {
	native, proxy, topic := diffSetup(t)
	ctx := context.Background()

	produceProxy := func(values ...string) {
		records := make([]*kafkav1.Record, 0, len(values))
		for _, v := range values {
			records = append(records, &kafkav1.Record{Value: []byte(v)})
		}
		produced, err := proxy.Produce(ctx, &kafkav1.ProduceRequest{
			Topic: topic, Partition: 0, Acks: kafkav1.Acks_ACKS_ALL, Records: records})
		if err != nil {
			t.Fatal(err)
		}
		if produced.ErrorCode != 0 {
			t.Fatalf("produce: %+v", produced)
		}
	}
	produceNative := func(values ...string) {
		records := make([]*kafkav1.Record, 0, len(values))
		for _, v := range values {
			records = append(records, &kafkav1.Record{Value: []byte(v)})
		}
		produced, err := native.Produce(&kafkav1.ProduceRequest{
			Topic: topic, Partition: 0, Acks: kafkav1.Acks_ACKS_ALL, Records: records})
		if err != nil {
			t.Fatal(err)
		}
		if produced.ErrorCode != 0 {
			t.Fatalf("produce: %+v", produced)
		}
	}

	// Native share-consumes what the proxy produced; ACCEPT retires.
	opened, err := native.OpenShareGroup(&kafkav1.OpenShareGroupRequest{
		GroupId: "go-share-diff-native-" + topic[len(topic)-8:], Topics: []string{topic}})
	if err != nil {
		t.Skipf("share group open raised: %v", err)
	}
	if opened.ErrorCode != 0 {
		t.Skipf("broker refused share group (error %d)", opened.ErrorCode)
	}
	session := opened.SessionId
	_, _ = native.SharePoll(&kafkav1.SharePollRequest{SessionId: session, MaxRecords: 10, MaxWaitMs: 500})
	produceProxy("s1", "s2")
	var first []*kafkav1.SharePollRecord
	deadline := time.Now().Add(30 * time.Second)
	for len(first) < 2 && time.Now().Before(deadline) {
		resp, err := native.SharePoll(&kafkav1.SharePollRequest{SessionId: session, MaxRecords: 10, MaxWaitMs: 500})
		if err != nil {
			t.Fatal(err)
		}
		first = append(first, resp.Records...)
		if len(first) == 0 {
			time.Sleep(200 * time.Millisecond)
		}
	}
	if len(first) != 2 {
		t.Fatalf("native share delivery timed out: %d records", len(first))
	}
	entries := make([]*kafkav1.ShareAckEntry, 0, len(first))
	for _, r := range first {
		entries = append(entries, &kafkav1.ShareAckEntry{Topic: topic, Partition: 0, Offset: r.Offset, AckType: 1})
	}
	acked, err := native.ShareAck(&kafkav1.ShareAckRequest{SessionId: session, Entries: entries})
	if err != nil {
		t.Fatal(err)
	}
	if acked.ErrorCode != 0 {
		t.Fatalf("share ack: %+v", acked)
	}
	described, err := native.DescribeShareGroups(&kafkav1.DescribeShareGroupsRequest{GroupIds: []string{"go-share-diff-native-" + topic[len(topic)-8:]}})
	if err != nil {
		t.Fatal(err)
	}
	if described.ErrorCode != 0 {
		t.Fatalf("describe share groups: %+v", described)
	}
	_, _ = native.CloseShareGroup(&kafkav1.CloseShareGroupRequest{SessionId: session})

	// Native produces, proxy share-consumes; RELEASE redelivers.
	pOpened, err := proxy.OpenShareGroup(ctx, &kafkav1.OpenShareGroupRequest{
		GroupId: "go-share-diff-proxy-" + topic[len(topic)-8:], Topics: []string{topic}})
	if err != nil {
		t.Skipf("share group open raised: %v", err)
	}
	if pOpened.ErrorCode != 0 {
		t.Skipf("broker refused share group (error %d)", pOpened.ErrorCode)
	}
	pSession := pOpened.SessionId
	_, _ = proxy.SharePoll(ctx, &kafkav1.SharePollRequest{SessionId: pSession, MaxRecords: 10, MaxWaitMs: 500})
	produceNative("s3")
	pollProxy := func(want int) []*kafkav1.SharePollRecord {
		out := []*kafkav1.SharePollRecord{}
		deadline := time.Now().Add(30 * time.Second)
		for len(out) < want && time.Now().Before(deadline) {
			resp, err := proxy.SharePoll(ctx, &kafkav1.SharePollRequest{SessionId: pSession, MaxRecords: 10, MaxWaitMs: 500})
			if err != nil {
				t.Fatal(err)
			}
			out = append(out, resp.Records...)
			if len(out) == 0 {
				time.Sleep(200 * time.Millisecond)
			}
		}
		return out
	}
	third := pollProxy(1)
	if len(third) != 1 || string(third[0].Value) != "s3" {
		t.Fatalf("proxy share delivery = %+v", third)
	}
	released, err := proxy.ShareAck(ctx, &kafkav1.ShareAckRequest{
		SessionId: pSession,
		Entries:   []*kafkav1.ShareAckEntry{{Topic: topic, Partition: 0, Offset: third[0].Offset, AckType: 2}}})
	if err != nil {
		t.Fatal(err)
	}
	if released.ErrorCode != 0 {
		t.Fatalf("share release: %+v", released)
	}
	redelivered := pollProxy(1)
	if len(redelivered) != 1 || redelivered[0].Offset != third[0].Offset || redelivered[0].DeliveryCount != 2 {
		t.Fatalf("redelivery = %+v", redelivered)
	}
	_, _ = proxy.CloseShareGroup(ctx, &kafkav1.CloseShareGroupRequest{SessionId: pSession})
}
