package dcwebrtc

// DC message chunking end-to-end (DcEndpoint.SetChunkMessages):
// a 1 MiB binary message crosses as [0xF0, flags] chunks and
// reassembles whole — the path that lets browser peers (256 KiB
// RTCDataChannel message cap) exchange multi-MB grpc-dc frames.
// Mirrors webrtc/js/test/chunking.test.js.

import (
	"bytes"
	"testing"
	"time"
)

func TestChunkedPeersEchoOneMiB(t *testing.T) {
	a, err := NewPeer(PeerOptions{LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := NewPeer(PeerOptions{LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()

	offer := a.CreateOffer()
	answer, err := b.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}
	type result struct {
		endpoint *DcEndpoint
		err      error
	}
	results := make(chan result, 2)
	go func() {
		endpoint, err := a.ConnectWithOptions(true)
		results <- result{endpoint, err}
	}()
	go func() {
		endpoint, err := b.ConnectWithOptions(true)
		results <- result{endpoint, err}
	}()
	var endpoints []*DcEndpoint
	for i := 0; i < 2; i++ {
		select {
		case r := <-results:
			if r.err != nil {
				t.Fatalf("connect: %v", r.err)
			}
			endpoints = append(endpoints, r.endpoint)
		case <-time.After(30 * time.Second):
			t.Fatal("connect timed out")
		}
	}
	epA, epB := endpoints[0], endpoints[1]
	epA.SetChunkMessages(true)
	epB.SetChunkMessages(true)

	received := make(chan []byte, 1)
	epB.SetOnChannel(func(channel *DataChannel) {
		channel.OnMessage(func(data []byte, isText bool) {
			if !isText {
				channel.Send(data)
			}
		})
	})
	epA.SetOnChannel(func(channel *DataChannel) {})
	channel := epA.OpenChannel(ChannelParams{Label: "chunk"})
	channel.OnMessage(func(data []byte, isText bool) {
		if !isText {
			received <- data
		}
	})
	big := bytes.Repeat([]byte("A"), 1024*1024)
	channel.Send(big)
	select {
	case echoed := <-received:
		if !bytes.Equal(echoed, big) {
			t.Fatalf("echo mismatch: %d bytes", len(echoed))
		}
	case <-time.After(30 * time.Second):
		t.Fatal("no 1 MiB echo within deadline")
	}
	_ = received
}
