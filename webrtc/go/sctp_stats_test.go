package dcwebrtc

import "testing"

// AssociationStats: loss-injected counters must move exactly
// where the events happen (mirrors the Rust/JS stats tests).

func TestSctpStatsCountRetransmitsAndDuplicates(t *testing.T) {
	client := NewClientAssociation(SctpPort, SctpPort)
	server := NewServerAssociation(SctpPort, SctpPort)
	var now int64

	var deliverToServer func(packets [][]byte) []SctpEvent
	deliverToServer = func(packets [][]byte) []SctpEvent {
		var events []SctpEvent
		for _, p := range packets {
			replies, ev := server.HandlePacket(p, now)
			events = append(events, ev...)
			for _, r := range replies {
				back, _ := client.HandlePacket(r, now)
				events = append(events, deliverToServer(back)...)
			}
		}
		return events
	}

	init := client.Connect(now)
	events := deliverToServer([][]byte{init})
	_ = events
	if !client.IsEstablished() || !server.IsEstablished() {
		t.Fatal("not established")
	}

	packets := client.SendData(0, 63, []byte("lost once"), SendOptions{}, now)
	if len(packets) == 0 {
		t.Fatal("no packets")
	}
	sent := client.Stats()
	if sent.ChunksSent < 1 || sent.PacketsSent < 1 {
		t.Fatalf("sent stats: %+v", sent)
	}
	// Drop the first transmission; RTO retransmit must count.
	now += 1500
	retransmitted, _ := client.Tick(now)
	if len(retransmitted) == 0 {
		t.Fatal("expected retransmission after RTO")
	}
	afterTick := client.Stats()
	if afterTick.Retransmits < 1 {
		t.Fatalf("retransmits: %+v", afterTick)
	}
	if afterTick.FastRetransmits != 0 {
		t.Fatalf("timeout path is not fast retransmit: %+v", afterTick)
	}
	ev := deliverToServer(retransmitted)
	dataEvents := 0
	for _, e := range ev {
		if e.Type == "data" {
			dataEvents++
		}
	}
	if dataEvents != 1 {
		t.Fatalf("data events = %d", dataEvents)
	}
	_ = deliverToServer(retransmitted) // duplicate delivery
	serverStats := server.Stats()
	if serverStats.ChunksReceived < 2 {
		t.Fatalf("chunks received: %+v", serverStats)
	}
	if serverStats.DupChunks < 1 {
		t.Fatalf("duplicate delivery must count: %+v", serverStats)
	}
	if serverStats.PacketsReceived < 1 {
		t.Fatalf("packets received: %+v", serverStats)
	}
}
