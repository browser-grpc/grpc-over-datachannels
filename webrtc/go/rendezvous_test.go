package dcwebrtc

import (
	"fmt"
	"net"
	"testing"
	"time"
)

// A native peer plays the browser dialer: it synthesizes the
// listener's description locally (HandleAnswer on the
// descriptor-rendered answer), runs ICE as controlling agent,
// and opens a channel. The listener must spawn a session peer
// from the first Binding request's ufrag, answer DTLS as
// server with the fixed certificate, and echo on the channel.
// Two sequential dialers prove per-ufrag session demux on the
// one listener socket.
func TestRendezvousDialAndEcho(t *testing.T) {
	heard := make(chan string, 4)
	listener, err := ListenRendezvous(&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0}, RendezvousOptions{
		OnChannel: func(channel *DataChannel, peer *Peer) {
			channel.OnMessage(func(data []byte, isText bool) {
				heard <- string(data)
				channel.Send([]byte("re:" + string(data)))
			})
		},
		OnError: func(err error) { t.Logf("rendezvous: %v", err) },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	desc := listener.Descriptor("127.0.0.1")
	if desc.IceUfrag == "" || desc.IcePwd == "" || desc.Fingerprint == "" || desc.Setup != "passive" {
		t.Fatalf("incomplete descriptor: %+v", desc)
	}

	for dial := 0; dial < 2; dial++ {
		dialer, err := NewPeer(PeerOptions{})
		if err != nil {
			t.Fatal(err)
		}
		remote := SessionDescription{
			Ufrag:       desc.IceUfrag,
			Pwd:         desc.IcePwd,
			Fingerprint: desc.Fingerprint,
			Setup:       "passive",
			Candidates:  []Candidate{HostCandidate("127.0.0.1", desc.Port, "1")},
		}
		if err := dialer.HandleAnswer(remote.Generate("answer")); err != nil {
			t.Fatal(err)
		}
		endpoint, err := dialer.ConnectWithOptions(true)
		if err != nil {
			t.Fatalf("dial %d connect: %v", dial, err)
		}
		channel := endpoint.OpenChannel(DefaultChannelParams("grpc"))
		reply := make(chan string, 1)
		channel.OnMessage(func(data []byte, isText bool) { reply <- string(data) })
		want := fmt.Sprintf("hello-rendezvous-%d", dial)
		channel.Send([]byte(want))
		select {
		case got := <-heard:
			if got != want {
				t.Fatalf("dial %d: listener heard %q, want %q", dial, got, want)
			}
		case <-time.After(15 * time.Second):
			t.Fatalf("dial %d: listener heard nothing", dial)
		}
		select {
		case got := <-reply:
			if got != "re:"+want {
				t.Fatalf("dial %d: reply %q, want %q", dial, got, "re:"+want)
			}
		case <-time.After(15 * time.Second):
			t.Fatalf("dial %d: no reply", dial)
		}
		dialer.Close()
	}
}
