package dcwebrtc

import (
	"bytes"
	"testing"
)

// Regression: fragments of two consecutive ordered messages must
// never merge across the message boundary. If message B's BEGIN
// fragment lands before message A's END fragment, the old merge
// concatenated B into A: A was delivered corrupt (or dropped by
// the caller) and B's SSN never completed, wedging every later
// message on the stream while SACKs kept advancing.
func TestSctpInterleavedFragmentsDoNotMergeAcrossMessages(t *testing.T) {
	client := NewClientAssociation(SctpPort, SctpPort)
	server := NewServerAssociation(SctpPort, SctpPort)
	exchange := func(to *Association, packets [][]byte, now int64) ([][]byte, []SctpEvent) {
		var out [][]byte
		var events []SctpEvent
		for _, p := range packets {
			p2, e2 := to.HandlePacket(p, now)
			out = append(out, p2...)
			events = append(events, e2...)
		}
		return out, events
	}
	var now int64
	init := client.Connect(now)
	ack, _ := exchange(server, [][]byte{init}, now)
	echo, _ := exchange(client, ack, now)
	ackPackets, _ := exchange(server, echo, now)
	_, _ = exchange(client, ackPackets, now)
	if !client.IsEstablished() || !server.IsEstablished() {
		t.Fatal("not established")
	}

	msgA := bytes.Repeat([]byte("a"), 1500)
	msgB := bytes.Repeat([]byte("b"), 1500)
	pktsA := client.SendData(0, PpidBinary, msgA, SendOptions{}, now)
	pktsB := client.SendData(0, PpidBinary, msgB, SendOptions{}, now)
	if len(pktsA) != 2 || len(pktsB) != 2 {
		t.Fatalf("fragment counts: A=%d B=%d", len(pktsA), len(pktsB))
	}
	// B's BEGIN fragment arrives before A's END fragment.
	interleaved := [][]byte{pktsA[0], pktsB[0], pktsA[1], pktsB[1]}
	var got [][]byte
	for _, p := range interleaved {
		_, events := server.HandlePacket(p, now)
		for _, ev := range events {
			if ev.Type == "data" {
				got = append(got, ev.Payload)
			}
		}
	}
	// A following message must still deliver (SSN not stranded).
	pktsC := client.SendData(0, PpidBinary, []byte("third"), SendOptions{}, now)
	_, events := exchange(server, pktsC, now)
	for _, ev := range events {
		if ev.Type == "data" {
			got = append(got, ev.Payload)
		}
	}
	if len(got) != 3 || !bytes.Equal(got[0], msgA) || !bytes.Equal(got[1], msgB) || string(got[2]) != "third" {
		t.Fatalf("deliveries: %d messages, first bytes %q", len(got), firstBytes(got))
	}
}

func firstBytes(msgs [][]byte) []string {
	out := make([]string, len(msgs))
	for i, m := range msgs {
		if len(m) > 8 {
			m = m[:8]
		}
		out[i] = string(m)
	}
	return out
}
