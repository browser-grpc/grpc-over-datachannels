// Conformance through the cgo binding: the shared
// fixtures/sctp_vectors.json scenarios, client and server
// both living in the Rust core.
//
//go:build dc_sctp

package sctpffi

import (
	"bytes"
	"encoding/json"
	"os"
	"testing"
)

// fill in the fixtures is a one-char string ("a").
type scenarioRaw struct {
	Name     string `json:"name"`
	Stream   uint16 `json:"stream"`
	Messages []struct {
		Size int    `json:"size"`
		Fill string `json:"fill"`
	} `json:"messages"`
	Deliver []int `json:"deliver"`
	Expect  []int `json:"expect"`
}

func handshake(t testing.TB, client, server *Association, now uint64) {
	t.Helper()
	init, err := client.Connect(now)
	if err != nil {
		t.Fatal(err)
	}
	replies, _, err := server.HandlePacket(init, now)
	if err != nil {
		t.Fatal(err)
	}
	replies2, _, err := client.HandlePacket(replies[0], now)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range replies2 {
		replies3, _, err := server.HandlePacket(p, now)
		if err != nil {
			t.Fatal(err)
		}
		for _, q := range replies3 {
			if _, _, err := client.HandlePacket(q, now); err != nil {
				t.Fatal(err)
			}
		}
	}
	if !client.Established() || !server.Established() {
		t.Fatal("not established")
	}
}

func TestFFISctpVectors(t *testing.T) {
	raw, err := os.ReadFile("../../fixtures/sctp_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Scenarios []scenarioRaw `json:"scenarios"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	const now = uint64(0)
	for _, sc := range doc.Scenarios {
		t.Run(sc.Name, func(t *testing.T) {
			client := NewClient(5000, 5000)
			defer client.Close()
			server := NewServer(5000, 5000)
			defer server.Close()
			handshake(t, client, server, now)
			var packets [][]byte
			var want [][]byte
			for _, m := range sc.Messages {
				payload := bytes.Repeat([]byte(m.Fill), m.Size)
				want = append(want, payload)
				pkts, err := client.SendData(sc.Stream, 63, payload, Reliable, now)
				if err != nil {
					t.Fatal(err)
				}
				packets = append(packets, pkts...)
			}
			var got [][]byte
			for _, idx := range sc.Deliver {
				_, events, err := server.HandlePacket(packets[idx], now)
				if err != nil {
					t.Fatal(err)
				}
				for _, ev := range events {
					if ev.Kind == EventData {
						if ev.Stream != sc.Stream {
							t.Fatalf("stream %d, want %d", ev.Stream, sc.Stream)
						}
						got = append(got, ev.Payload)
					}
				}
			}
			if len(got) != len(sc.Expect) {
				t.Fatalf("got %d messages, want %d", len(got), len(sc.Expect))
			}
			for i, wi := range sc.Expect {
				if !bytes.Equal(got[i], want[wi]) {
					t.Fatalf("message %d mismatch", i)
				}
			}
			stats, err := server.Stats()
			if err != nil {
				t.Fatal(err)
			}
			if stats[3] < uint64(len(got)) {
				t.Fatalf("chunks_received %d < delivered %d", stats[3], len(got))
			}
		})
	}
}
