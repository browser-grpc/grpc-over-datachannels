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

	// Long-lived leg: with a 6 s consent expiry, the session
	// must still answer after 9 s. The dialer's password is
	// never learned by the listener, so its consent checks
	// can never be answered — the session survives only
	// because the dialer's own Binding requests (sent every
	// 1 s here) refresh server-side consent (RFC 7675).
	t.Run("long-lived past consent window", func(t *testing.T) {
		short, err := ListenRendezvous(&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0}, RendezvousOptions{
			ConsentInterval: 500 * time.Millisecond,
			ConsentExpiry:   6 * time.Second,
			OnChannel: func(channel *DataChannel, peer *Peer) {
				channel.OnMessage(func(data []byte, isText bool) {
					channel.Send([]byte("re:" + string(data)))
				})
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		defer short.Close()
		sdesc := short.Descriptor("127.0.0.1")
		dialer, err := NewPeer(PeerOptions{
			ConsentInterval: time.Second,
			ConsentExpiry:   30 * time.Second,
		})
		if err != nil {
			t.Fatal(err)
		}
		defer dialer.Close()
		remote := SessionDescription{
			Ufrag:       sdesc.IceUfrag,
			Pwd:         sdesc.IcePwd,
			Fingerprint: sdesc.Fingerprint,
			Setup:       "passive",
			Candidates:  []Candidate{HostCandidate("127.0.0.1", sdesc.Port, "1")},
		}
		if err := dialer.HandleAnswer(remote.Generate("answer")); err != nil {
			t.Fatal(err)
		}
		endpoint, err := dialer.ConnectWithOptions(true)
		if err != nil {
			t.Fatal(err)
		}
		channel := endpoint.OpenChannel(DefaultChannelParams("grpc"))
		replies := make(chan string, 4)
		channel.OnMessage(func(data []byte, isText bool) { replies <- string(data) })
		channel.Send([]byte("before"))
		select {
		case got := <-replies:
			if got != "re:before" {
				t.Fatalf("reply %q", got)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("no reply before wait")
		}
		time.Sleep(9 * time.Second)
		channel.Send([]byte("after"))
		select {
		case got := <-replies:
			if got != "re:after" {
				t.Fatalf("reply %q", got)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("session died inside the consent window")
		}
	})

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
