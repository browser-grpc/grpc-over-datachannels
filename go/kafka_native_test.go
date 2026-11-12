//go:build kafka_native

package grpcdc_test

// Kafka native end-to-end: generated Go messages ->
// libkafka_native in-process via cgo (no proxy, no gRPC
// hop). Env-gated: KAFKA_E2E_BROKER=host:port.

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"testing"
	"time"

	kafkav1 "github.com/browser-grpc/grpc-over-datachannels/go/kafka"
)

func TestKafkaNativeRoundtrip(t *testing.T) {
	broker := os.Getenv("KAFKA_E2E_BROKER")
	if broker == "" {
		t.Skip("KAFKA_E2E_BROKER not set")
	}
	client, err := kafkav1.NewKafkaNativeClient(broker)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	suffix := make([]byte, 8)
	if _, err := rand.Read(suffix); err != nil {
		t.Fatal(err)
	}
	topic := "go-kafka-native-" + hex.EncodeToString(suffix)
	created, err := client.CreateTopics(&kafkav1.CreateTopicsRequest{
		Topics:    []*kafkav1.NewTopic{{Name: topic, NumPartitions: 1, ReplicationFactor: 1}},
		TimeoutMs: 15000,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(created.Results) != 1 || created.Results[0].ErrorCode != 0 {
		t.Fatalf("create topic: %+v", created.Results)
	}
	defer client.DeleteTopics(&kafkav1.DeleteTopicsRequest{Topics: []string{topic}, TimeoutMs: 15000})

	deadline := time.Now().Add(15 * time.Second)
	for {
		meta, err := client.Metadata(&kafkav1.MetadataRequest{Topics: []string{topic}})
		if err != nil {
			t.Fatal(err)
		}
		ready := false
		for _, tp := range meta.Topics {
			if tp.Name == topic && len(tp.Partitions) > 0 {
				ready = true
			}
		}
		if ready {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("topic not visible")
		}
		time.Sleep(250 * time.Millisecond)
	}

	produced, err := client.Produce(&kafkav1.ProduceRequest{
		Topic:     topic,
		Partition: 0,
		Records: []*kafkav1.Record{
			{Value: []byte("one")},
			{Value: []byte("two")},
			{Value: []byte("three")},
		},
		Acks: kafkav1.Acks_ACKS_ALL,
	})
	if err != nil {
		t.Fatal(err)
	}
	if produced.ErrorCode != 0 {
		t.Fatalf("produce: %d", produced.ErrorCode)
	}

	stream, err := client.Consume(&kafkav1.ConsumeRequest{
		Topic: topic, Partition: 0, Offset: -2, MaxRecords: 10, MaxWaitMs: 2000,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	var values []string
	for len(values) < 3 {
		chunk, ok, err := stream.Next()
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			break
		}
		if chunk.ErrorCode != 0 {
			t.Fatalf("consume error %d", chunk.ErrorCode)
		}
		for _, r := range chunk.Records {
			values = append(values, string(r.Value))
		}
	}
	if len(values) != 3 || values[0] != "one" || values[1] != "two" || values[2] != "three" {
		t.Fatalf("values: %v", values)
	}

	latest, err := client.ListOffsets(&kafkav1.ListOffsetsRequest{Topic: topic, Partition: 0, Timestamp: -1})
	if err != nil {
		t.Fatal(err)
	}
	if latest.ErrorCode != 0 || latest.Offset != 3 {
		t.Fatalf("listOffsets: %+v", latest)
	}
}
