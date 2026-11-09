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
	// Only the second fragment: gap-buffered, window -1152.
	sacks, _ := server.HandlePacket(pkts[1], now)
	if got := sackArwnd(t, sacks[0]); got != initialRwnd-1152 {
		t.Fatalf("gap-buffered a_rwnd: got %d want %d", got, initialRwnd-1152)
	}
	// Duplicate of the same TSN must not double-count.
	sacks, _ = server.HandlePacket(pkts[1], now)
	if got := sackArwnd(t, sacks[0]); got != initialRwnd-1152 {
		t.Fatalf("duplicate a_rwnd: got %d want %d", got, initialRwnd-1152)
	}
	// Filling the gap restores the full window.
	sacks, _ = server.HandlePacket(pkts[0], now)
	if got := sackArwnd(t, sacks[0]); got != initialRwnd {
		t.Fatalf("recovered a_rwnd: got %d want %d", got, initialRwnd)
	}
}

// RTO must follow the measured RTT (RFC 9260 6.3), not the
// fixed 1000ms initial value: a delayed-but-not-lost flight
// must not be spuriously retransmitted.
func TestRtoFollowsMeasuredRttNotFixedTimer(t *testing.T) {
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

	// Round 1: DATA at now=0, SACK returns at now=600 -> first
	// RTT sample 600ms -> SRTT=600, RTTVAR=300, RTO=1800.
	pkts := client.SendData(0, PpidBinary, []byte("one"), SendOptions{}, now)
	sacks, _ := server.HandlePacket(pkts[0], now)
	now += 600
	client.HandlePacket(sacks[0], now)

	// Round 2 at now=600: no spurious retransmit at +1100.
	pkts = client.SendData(0, PpidBinary, []byte("two"), SendOptions{}, now)
	if len(pkts) != 1 {
		t.Fatalf("expected 1 packet, got %d", len(pkts))
	}
	packets, _ := client.Tick(now + 1100)
	if len(packets) != 0 {
		t.Fatalf("spurious retransmit at fixed RTO: %d packets", len(packets))
	}
	// Past the measured RTO (600 + 1800) retransmission fires.
	packets, _ = client.Tick(now + 1801)
	if len(packets) == 0 {
		t.Fatal("retransmit must fire past measured RTO")
	}
}
