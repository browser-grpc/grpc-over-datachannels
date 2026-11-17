package dcwebrtc

import (
	"testing"
	"time"
)

// LinkStats live (Go): DcEndpoint.LinkStats fills the SCTP
// leg on a live peer connection (TCP/HTTP2 legs stay nil on
// a plain DataChannel).

func TestLinkStatsFillsSctpLegLive(t *testing.T) {
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

	epB.SetOnChannel(func(channel *DataChannel) {
		channel.OnMessage(func(data []byte, isText bool) {
			channel.Send(data)
		})
	})
	channel := epA.OpenChannel(DefaultChannelParams("grpc"))
	got := make(chan []byte, 1)
	channel.OnMessage(func(data []byte, isText bool) {
		cp := make([]byte, len(data))
		copy(cp, data)
		got <- cp
	})
	channel.Send([]byte("hello-stats"))
	select {
	case data := <-got:
		if string(data) != "hello-stats" {
			t.Fatalf("echo = %q", data)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("echo timed out")
	}

	stats := epA.LinkStats()
	if stats.Sctp == nil {
		t.Fatal("sctp leg missing")
	}
	if stats.Sctp.ChunksSent <= 0 || stats.Sctp.ChunksReceived <= 0 {
		t.Fatalf("sctp counters not filled: %+v", stats.Sctp)
	}
	if stats.Tcp != nil || stats.Http2 != nil {
		t.Fatalf("plain channel must have nil tcp/http2 legs: %+v", stats)
	}
}
