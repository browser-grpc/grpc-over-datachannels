package grpcdc_test

// Kafka proxy end-to-end: generated Go client -> Rust kafka_proxy
// (--tcp) -> Apache Kafka / Redpanda.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise, so the plain `make test-go` run stays
// broker-free.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"testing"
	"time"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	kafkav1 "github.com/browser-grpc/grpc-over-datachannels/go/kafka"
)

func kafkaClient(t *testing.T) (*kafkav1.KafkaClient, string) {
	t.Helper()
	addr := os.Getenv("KAFKA_E2E_PROXY_ADDR")
	if addr == "" {
		t.Skip("KAFKA_E2E_PROXY_ADDR not set")
	}
	transport, err := grpcdc.DialSidecar(addr)
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	t.Cleanup(func() { transport.Close() })
	client := kafkav1.NewKafkaClient(grpcdc.NewChannel(transport))
	suffix := make([]byte, 8)
	if _, err := rand.Read(suffix); err != nil {
		t.Fatal(err)
	}
	topic := "go-kafka-e2e-" + hex.EncodeToString(suffix)
	ctx := context.Background()
	created, err := client.CreateTopics(ctx, &kafkav1.CreateTopicsRequest{
		Topics:    []*kafkav1.NewTopic{{Name: topic, NumPartitions: 1, ReplicationFactor: 1}},
		TimeoutMs: 15000,
	})
	if err != nil {
		t.Fatalf("create topics: %v", err)
	}
	if len(created.Results) != 1 || created.Results[0].ErrorCode != 0 {
		t.Fatalf("create topics: %+v", created.Results)
	}
	t.Cleanup(func() {
		_, _ = client.DeleteTopics(ctx, &kafkav1.DeleteTopicsRequest{Topics: []string{topic}})
	})
	// Wait until the partition is visible.
	deadline := time.Now().Add(15 * time.Second)
	for {
		latest, err := client.ListOffsets(ctx, &kafkav1.ListOffsetsRequest{Topic: topic, Partition: 0, Timestamp: -1})
		if err == nil && latest.ErrorCode == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("topic not visible: %v %+v", err, latest)
		}
		time.Sleep(250 * time.Millisecond)
	}
	return client, topic
}

func produce(t *testing.T, client *kafkav1.KafkaClient, topic string, values []string) []int64 {
	t.Helper()
	offsets := make([]int64, 0, len(values))
	for _, value := range values {
		resp, err := client.Produce(context.Background(), &kafkav1.ProduceRequest{
			Topic:     topic,
			Partition: 0,
			Records:   []*kafkav1.Record{{Key: []byte("k-" + value), Value: []byte(value)}},
		})
		if err != nil {
			t.Fatalf("produce: %v", err)
		}
		if resp.ErrorCode != 0 {
			t.Fatalf("produce error_code=%d", resp.ErrorCode)
		}
		offsets = append(offsets, resp.BaseOffset)
	}
	return offsets
}

func consume(t *testing.T, client *kafkav1.KafkaClient, topic string, offset int64, count int) []*kafkav1.FetchedRecord {
	t.Helper()
	stream, err := client.Consume(context.Background(), &kafkav1.ConsumeRequest{
		Topic: topic, Partition: 0, Offset: offset, MaxRecords: int32(count),
	})
	if err != nil {
		t.Fatalf("consume: %v", err)
	}
	var got []*kafkav1.FetchedRecord
	for len(got) < count {
		chunk, err := stream.Recv()
		if err != nil {
			t.Fatalf("consume recv after %d records: %v", len(got), err)
		}
		if chunk.ErrorCode != 0 {
			t.Fatalf("consume error_code=%d", chunk.ErrorCode)
		}
		got = append(got, chunk.Records...)
	}
	return got
}

func values(records []*kafkav1.FetchedRecord) []string {
	out := make([]string, len(records))
	for i, r := range records {
		out[i] = string(r.Value)
	}
	return out
}

func TestKafkaProduceConsumeRoundtrip(t *testing.T) {
	client, topic := kafkaClient(t)
	offsets := produce(t, client, topic, []string{"v0", "v1", "v2"})
	if fmt.Sprint(offsets) != "[0 1 2]" {
		t.Fatalf("offsets=%v", offsets)
	}
	latest, err := client.ListOffsets(context.Background(), &kafkav1.ListOffsetsRequest{Topic: topic, Partition: 0, Timestamp: -1})
	if err != nil {
		t.Fatalf("list offsets: %v", err)
	}
	if latest.Offset != 3 || latest.ErrorCode != 0 {
		t.Fatalf("latest=%+v", latest)
	}
	got := consume(t, client, topic, 0, 3)
	if fmt.Sprint(values(got)) != "[v0 v1 v2]" {
		t.Fatalf("values=%v", values(got))
	}
	for i, r := range got {
		if r.Offset != int64(i) || string(r.Key) != "k-v"+fmt.Sprint(i) {
			t.Fatalf("record %d = %+v", i, r)
		}
	}
}

func TestKafkaPerPartitionOrdering(t *testing.T) {
	client, topic := kafkaClient(t)
	want := make([]string, 10)
	for i := range want {
		want[i] = fmt.Sprintf("seq-%02d", i)
	}
	offsets := produce(t, client, topic, want)
	for i, off := range offsets {
		if off != int64(i) {
			t.Fatalf("offsets=%v", offsets)
		}
	}
	got := consume(t, client, topic, 0, 10)
	if fmt.Sprint(values(got)) != fmt.Sprint(want) {
		t.Fatalf("values=%v", values(got))
	}
}

func TestKafkaOffsetResume(t *testing.T) {
	client, topic := kafkaClient(t)
	produce(t, client, topic, []string{"a", "b", "c", "d"})
	first := consume(t, client, topic, 0, 2)
	if fmt.Sprint(values(first)) != "[a b]" {
		t.Fatalf("first=%v", values(first))
	}
	rest := consume(t, client, topic, 2, 2)
	if fmt.Sprint(values(rest)) != "[c d]" {
		t.Fatalf("rest=%v", values(rest))
	}
}
