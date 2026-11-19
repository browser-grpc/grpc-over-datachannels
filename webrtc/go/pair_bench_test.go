package dcwebrtc

import "testing"

// Mirrored-stack ruler for the FFI comparison in
// go/sctpffi: one client->server message delivery through
// this Go SCTP stack, same shape and payload.
func BenchmarkGoSctpPair(b *testing.B) {
	client := newSctpAssoc(true)
	server := newSctpAssoc(false)
	var now int64
	pump := func(from, to sctpAssoc, packets [][]byte) {
		pending := packets
		for len(pending) > 0 {
			var out [][]byte
			for _, p := range pending {
				packets2, _ := to.HandlePacket(p, now)
				out = append(out, packets2...)
			}
			from, to = to, from
			pending = out
		}
	}
	init := client.Connect(now)
	pump(client, server, [][]byte{init})
	if !client.IsEstablished() || !server.IsEstablished() {
		b.Fatal("not established")
	}
	msg := make([]byte, 200)
	for i := range msg {
		msg[i] = 7
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		packets := client.SendData(1, PpidBinary, msg, SendOptions{}, now)
		for _, p := range packets {
			server.HandlePacket(p, now)
		}
	}
}
