package dcwebrtc

// IPv6 ICE candidates: XOR address helpers are family-aware
// (RFC 5389: the IPv6 mask is magic cookie + transaction ID),
// candidates round-trip through SDP in canonical form, and two
// peers connect over ::1 host candidates only.

import (
	"net"
	"strings"
	"testing"
	"time"
)

func TestXorAddressIPv6RoundTrip(t *testing.T) {
	req := newStunMessage(StunTypeBindingRequest)
	addr := &net.UDPAddr{IP: net.ParseIP("2001:db8::42"), Port: 51234}
	value := xorAddress(addr, req.TransactionID)
	if len(value) != 20 || value[1] != 2 {
		t.Fatalf("bad ipv6 xor value: %d bytes family %d", len(value), value[1])
	}
	got := decodeXorAddress(value, req.TransactionID, true)
	if got == nil || got.String() != addr.String() {
		t.Fatalf("round trip: got %v want %v", got, addr)
	}
	// IPv4-mapped input encodes as IPv4 and decodes to dotted.
	mapped := &net.UDPAddr{IP: net.ParseIP("::ffff:203.0.113.9"), Port: 7}
	v4 := xorAddress(mapped, req.TransactionID)
	if len(v4) != 8 || v4[1] != 1 {
		t.Fatalf("mapped should encode as ipv4: %d bytes family %d", len(v4), v4[1])
	}
	if d := decodeXorAddress(v4, req.TransactionID, true); d == nil || d.String() != "203.0.113.9:7" {
		t.Fatalf("mapped decode: %v", d)
	}
}

func TestCandidateIPv6SDPRoundTrip(t *testing.T) {
	line := "a=candidate:1 1 udp 2130706431 2001:0db8:0000:0000:0000:0000:0000:0001 54321 typ host generation 0"
	cand := CandidateFromSDP(strings.TrimPrefix(line, "a="))
	if cand == nil {
		t.Fatal("parse failed")
	}
	if cand.Address != "2001:db8::1" || cand.Port != 54321 {
		t.Fatalf("got %+v", cand)
	}
	if !strings.Contains(cand.ToSDP(), "2001:db8::1 54321 typ host") {
		t.Fatalf("render: %s", cand.ToSDP())
	}
}

// connectPair connects two peers with the given local IPs and
// echoes one message; wantInOffer must appear in the offer SDP.
func connectPair(t *testing.T, ipsA, ipsB []string, wantInOffer, payload string) {
	t.Helper()
	newPeer := func(ips []string) *Peer {
		peer, err := NewPeer(PeerOptions{
			LocalIPs:               ips,
			RequirePeerCertificate: true,
		})
		if err != nil {
			t.Fatal(err)
		}
		return peer
	}
	a := newPeer(ipsA)
	defer a.Close()
	b := newPeer(ipsB)
	defer b.Close()

	offer := a.CreateOffer()
	if !strings.Contains(offer, wantInOffer) {
		t.Fatalf("offer lacks %q:\n%s", wantInOffer, offer)
	}
	answer, err := b.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}
	type result struct {
		ep  *DcEndpoint
		err error
		who string
	}
	results := make(chan result, 2)
	go func() {
		ep, err := a.ConnectWithOptions(true)
		results <- result{ep, err, "a"}
	}()
	go func() {
		ep, err := b.ConnectWithOptions(true)
		results <- result{ep, err, "b"}
	}()
	var epA, epB *DcEndpoint
	for i := 0; i < 2; i++ {
		select {
		case r := <-results:
			if r.err != nil {
				t.Fatalf("connect: %v", r.err)
			}
			if r.who == "a" {
				epA = r.ep
			} else {
				epB = r.ep
			}
		case <-time.After(30 * time.Second):
			t.Fatal("connect timed out")
		}
	}

	replies := make(chan string, 4)
	epB.SetOnChannel(func(channel *DataChannel) {
		channel.OnMessage(func(data []byte, isText bool) {
			channel.Send([]byte("echo:" + string(data)))
		})
	})
	ch := epA.OpenChannel(DefaultChannelParams("echo"))
	ch.OnMessage(func(data []byte, isText bool) { replies <- string(data) })
	ch.Send([]byte(payload))
	select {
	case text := <-replies:
		if text != "echo:"+payload {
			t.Fatalf("reply %q", text)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no echo reply")
	}
}

func TestPeersConnectOverIPv6Loopback(t *testing.T) {
	connectPair(t, []string{"::1"}, []string{"::1"}, "::1 ", "over-v6")
}

// A dual-stack peer (udp6 socket) still pairs with an IPv4-only
// peer; IPv4 packets arrive mapped and are normalized.
func TestDualStackPeerConnectsToIPv4Peer(t *testing.T) {
	connectPair(t, []string{"127.0.0.1", "::1"}, []string{"127.0.0.1"}, "::1 ", "dual-stack")
}
