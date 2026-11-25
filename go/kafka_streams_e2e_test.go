package grpcdc_test

// Kafka Streams generated-scenario interpreter (Go): runs
// the racket/kafka-streams-spec.rkt table stamped into
// kafka_streams_scenarios_generated.go. Env-gated like the
// other kafka suites (KAFKA_E2E_PROXY_ADDR).

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

func operatorByName(name string) kafkav1.Operator {
	switch name {
	case "TOKENIZE_WORDS":
		return kafkav1.Operator_TOKENIZE_WORDS
	case "GROUP_BY_KEY":
		return kafkav1.Operator_GROUP_BY_KEY
	case "COUNT":
		return kafkav1.Operator_COUNT
	case "MAP_VALUES":
		return kafkav1.Operator_MAP_VALUES
	case "FILTER":
		return kafkav1.Operator_FILTER
	case "SELECT_KEY":
		return kafkav1.Operator_SELECT_KEY
	case "AGGREGATE":
		return kafkav1.Operator_AGGREGATE
	case "REDUCE":
		return kafkav1.Operator_REDUCE
	}
	return kafkav1.Operator_OPERATOR_UNSPECIFIED
}

func TestKafkaStreamsScenarios(t *testing.T) {
	addr := os.Getenv("KAFKA_E2E_PROXY_ADDR")
	if addr == "" {
		t.Skip("KAFKA_E2E_PROXY_ADDR not set")
	}
	for _, sc := range KafkaStreamsScenarios {
		sc := sc
		t.Run(sc.Name, func(t *testing.T) {
			transport, err := grpcdc.DialSidecar(addr)
			if err != nil {
				t.Fatalf("dial proxy: %v", err)
			}
			defer transport.Close()
			channel := grpcdc.NewChannel(transport)
			kafka := kafkav1.NewKafkaClient(channel)
			streams := kafkav1.NewKafkaStreamsClient(channel)
			ctx := context.Background()
			suffix := make([]byte, 6)
			_, _ = rand.Read(suffix)
			id := hex.EncodeToString(suffix)
			source := "go-streams-in-" + id
			sink := "go-streams-out-" + id
			name := "go-" + sc.Name + "-" + id
			for _, topic := range []string{source, sink} {
				created, err := kafka.CreateTopics(ctx, &kafkav1.CreateTopicsRequest{
					Topics:    []*kafkav1.NewTopic{{Name: topic, NumPartitions: 1, ReplicationFactor: 1}},
					TimeoutMs: 15000,
				})
				if err != nil || len(created.Results) != 1 || created.Results[0].ErrorCode != 0 {
					t.Fatalf("create topic %s: %v %+v", topic, err, created)
				}
			}
			defer func() {
				_, _ = streams.DeleteTopology(ctx, &kafkav1.DeleteTopologyRequest{Name: name})
				_, _ = kafka.DeleteTopics(ctx, &kafkav1.DeleteTopicsRequest{Topics: []string{source, sink}})
			}()
			steps := make([]*kafkav1.Step, 0, len(sc.Chain))
			for _, st := range sc.Chain {
				steps = append(steps, &kafkav1.Step{
					Operator:   operatorByName(st.Operator),
					Param:      st.Param,
					Aggregator: kafkav1.Aggregator(st.Aggregator),
				})
			}
			info, err := streams.CreateTopology(ctx, &kafkav1.CreateTopologyRequest{
				Topology: &kafkav1.Topology{
					Name:        name,
					SourceTopic: source,
					SinkTopic:   sink,
					Steps:       steps,
				},
			})
			if err != nil || info.State != "RUNNING" {
				t.Fatalf("create topology: %v %+v", err, info)
			}
			for _, line := range sc.Lines {
				resp, err := kafka.Produce(ctx, &kafkav1.ProduceRequest{
					Topic:     source,
					Partition: 0,
					Records:   []*kafkav1.Record{{Value: []byte(line)}},
				})
				if err != nil || resp.ErrorCode != 0 {
					t.Fatalf("produce: %v %+v", err, resp)
				}
			}
			for key, want := range sc.Store {
				deadline := time.Now().Add(20 * time.Second)
				var got *kafkav1.GetStoreValueResponse
				for {
					got, err = streams.GetStoreValue(ctx, &kafkav1.GetStoreValueRequest{Topology: name, Key: key})
					if err == nil && got.Found && got.Value == want {
						break
					}
					if time.Now().After(deadline) {
						t.Fatalf("store %s: got %+v want %d", key, got, want)
					}
					time.Sleep(250 * time.Millisecond)
				}
			}
			// Final sink values.
			stream, err := kafka.Consume(ctx, &kafkav1.ConsumeRequest{
				Topic: sink, Partition: 0, Offset: 0, MaxRecords: 200,
			})
			if err != nil {
				t.Fatalf("consume sink: %v", err)
			}
			final := map[string]string{}
			type chunkRes struct {
				chunk *kafkav1.ConsumeResponse
				err   error
			}
			chunkCh := make(chan chunkRes, 1)
			go func() {
				for {
					chunk, err := stream.Recv()
					chunkCh <- chunkRes{chunk, err}
					if err != nil {
						return
					}
				}
			}()
			deadline := time.After(20 * time.Second)
		outer:
			for len(final) < len(sc.Sink) {
				select {
				case res := <-chunkCh:
					if res.err != nil {
						break outer
					}
					for _, r := range res.chunk.Records {
						final[string(r.Key)] = string(r.Value)
					}
				case <-deadline:
					break outer
				}
			}
			_ = stream
			if len(final) != len(sc.Sink) {
				t.Fatalf("sink final: got %v want %v", final, sc.Sink)
			}
			for k, v := range sc.Sink {
				if final[k] != v {
					t.Fatalf("sink[%s]: got %q want %q", k, final[k], v)
				}
			}
		})
	}
}
