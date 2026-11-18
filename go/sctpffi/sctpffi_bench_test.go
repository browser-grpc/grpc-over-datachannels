// FFI overhead ruler: one client->server message delivery
// through the Rust core via cgo, same shape as the mirrored
// Go stack bench in webrtc/go (BenchmarkGoSctpPair).
//
//go:build dc_sctp

package sctpffi

import "testing"

func BenchmarkFFISctpPair(b *testing.B) {
	client := NewClient(5000, 5000)
	defer client.Close()
	server := NewServer(5000, 5000)
	defer server.Close()
	handshake(b, client, server, 0)
	msg := make([]byte, 200)
	for i := range msg {
		msg[i] = 7
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		packets, err := client.SendData(1, 63, msg, Reliable, 0)
		if err != nil {
			b.Fatal(err)
		}
		for _, p := range packets {
			if _, _, err := server.HandlePacket(p, 0); err != nil {
				b.Fatal(err)
			}
		}
	}
}
