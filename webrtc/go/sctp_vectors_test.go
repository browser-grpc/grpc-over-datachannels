package dcwebrtc

import (
	"bytes"
	"encoding/json"
	"os"
	"testing"
)

// Generated conformance vectors (fixtures/sctp_vectors.json):
// all three mirrored SCTP stacks run
// the same fragment-delivery scenarios. Thin interpreter only —
// scenarios are generated data.

type sctpVectorFile struct {
	Scenarios []struct {
		Name     string `json:"name"`
		Stream   uint16 `json:"stream"`
		Messages []struct {
			Fill string `json:"fill"`
			Size int    `json:"size"`
		} `json:"messages"`
		Deliver []int `json:"deliver"`
		Expect  []int `json:"expect"`
	} `json:"scenarios"`
}

func TestSctpVectors(t *testing.T) {
	raw, err := os.ReadFile("../../fixtures/sctp_vectors.json")
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}
	var file sctpVectorFile
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatalf("parse vectors: %v", err)
	}
	if len(file.Scenarios) == 0 {
		t.Fatal("no scenarios")
	}
	for _, sc := range file.Scenarios {
		t.Run(sc.Name, func(t *testing.T) {
			client := NewClientAssociation(SctpPort, SctpPort)
			server := NewServerAssociation(SctpPort, SctpPort)
			var now int64
			exchange := func(to *Association, packets [][]byte) {
				for _, p := range packets {
					replies, _ := to.HandlePacket(p, now)
					_ = replies
				}
			}
			init := client.Connect(now)
			ack, _ := server.HandlePacket(init, now)
			echo, _ := client.HandlePacket(ack[0], now)
			for _, p := range echo {
				replies, _ := server.HandlePacket(p, now)
				exchange(client, replies)
			}
			if !client.IsEstablished() || !server.IsEstablished() {
				t.Fatal("not established")
			}
			var packets [][]byte
			var want [][]byte
			for _, m := range sc.Messages {
				payload := bytes.Repeat([]byte(m.Fill), m.Size)
				want = append(want, payload)
				packets = append(packets, client.SendData(sc.Stream, PpidBinary, payload, SendOptions{}, now)...)
			}
			var got [][]byte
			for _, idx := range sc.Deliver {
				_, events := server.HandlePacket(packets[idx], now)
				for _, ev := range events {
					if ev.Type == "data" {
						got = append(got, ev.Payload)
					}
				}
			}
			if len(got) != len(sc.Expect) {
				t.Fatalf("deliveries %d, want %d", len(got), len(sc.Expect))
			}
			for i, msgIdx := range sc.Expect {
				if !bytes.Equal(got[i], want[msgIdx]) {
					t.Fatalf("delivery %d: payload mismatch (len %d vs %d)", i, len(got[i]), len(want[msgIdx]))
				}
			}
		})
	}
}
