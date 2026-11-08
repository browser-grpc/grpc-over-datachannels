package dcwebrtc

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// SACK a_rwnd must shrink by gap-buffered bytes and recover
// when the gap fills (RFC 9260 3.3.4); duplicates of a buffered
// TSN must not double-count. Mirrors the Rust regression test.
func sackArwnd(t *testing.T, packet []byte) uint32 {
	t.Helper()
	if packet[12] != SctpChunkSack {
		t.Fatalf("expected a SACK chunk, got type %d", packet[12])
	}
	return binary.BigEndian.Uint32(packet[20:24])
}

func TestSackRwndShrinksForGapBufferedBytesAndRecovers(t *testing.T) {
	client := NewClientAssociation(SctpPort, SctpPort)
	server := NewServerAssociation(SctpPort, SctpPort)
	var now int64
	var exchange func(to *Association, packets [][]byte)
	exchange = func(to *Association, packets [][]byte) {
		for _, p := range packets {
			replies, _ := to.HandlePacket(p, now)
			if to == server {
				exchange(client, replies)
			} else {
				exchange(server, replies)
			}
		}
	}
	init := client.Connect(now)
	ack, _ := server.HandlePacket(init, now)
	exchange(client, ack)
	if !client.IsEstablished() || !server.IsEstablished() {
		t.Fatal("not established")
	}

	payload := bytes.Repeat([]byte("x"), 5000)
	pkts := client.SendData(0, PpidBinary, payload, SendOptions{}, now)
	if len(pkts) < 2 {
		t.Fatalf("expected >= 2 fragments, got %d", len(pkts))
	}
	// Only the second fragment: gap-buffered, window -1000.
	sacks, _ := server.HandlePacket(pkts[1], now)
	if got := sackArwnd(t, sacks[0]); got != initialRwnd-1000 {
		t.Fatalf("gap-buffered a_rwnd: got %d want %d", got, initialRwnd-1000)
	}
	// Duplicate of the same TSN must not double-count.
	sacks, _ = server.HandlePacket(pkts[1], now)
	if got := sackArwnd(t, sacks[0]); got != initialRwnd-1000 {
		t.Fatalf("duplicate a_rwnd: got %d want %d", got, initialRwnd-1000)
	}
	// Filling the gap restores the full window.
	sacks, _ = server.HandlePacket(pkts[0], now)
	if got := sackArwnd(t, sacks[0]); got != initialRwnd {
		t.Fatalf("recovered a_rwnd: got %d want %d", got, initialRwnd)
	}
}
