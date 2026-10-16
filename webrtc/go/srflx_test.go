package dcwebrtc

import (
	"net"
	"strings"
	"testing"
	"time"
)

// fakeStunServer answers Binding requests with a Binding success
// carrying XOR-MAPPED-ADDRESS. When fixed is set, the mapped address
// is that fixed address (proving XOR decoding); otherwise it echoes
// the requester's source address (real srflx-on-loopback semantics).
func fakeStunServer(t *testing.T, fixed *net.UDPAddr) string {
	t.Helper()
	addr, err := net.ResolveUDPAddr("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.ListenUDP("udp4", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, src, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			msg := DecodeStun(buf[:n])
			if msg == nil || msg.Type != StunTypeBindingRequest {
				continue
			}
			mapped := src
			if fixed != nil {
				mapped = fixed
			}
			resp := &StunMessage{Type: StunTypeBindingSuccess, TransactionID: msg.TransactionID}
			resp.addAttr(StunAttrXorMappedAddress, xorMappedAddress(mapped, msg.TransactionID))
			_, _ = conn.WriteToUDP(resp.Encode(nil), src)
		}
	}()
	return conn.LocalAddr().String()
}

func TestGatherSrflx(t *testing.T) {
	fixed := &net.UDPAddr{IP: net.ParseIP("203.0.113.9"), Port: 54321}
	server := fakeStunServer(t, fixed)
	peer, err := NewPeer(PeerOptions{RequirePeerCertificate: false, LocalIPs: []string{"127.0.0.1"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := peer.GatherSrflx(server, 2*time.Second); err != nil {
		t.Fatal(err)
	}
	var srflx *Candidate
	for i := range peer.agent.LocalCandidates {
		if peer.agent.LocalCandidates[i].Type == "srflx" {
			srflx = &peer.agent.LocalCandidates[i]
		}
		if peer.agent.LocalCandidates[i].Type == "host" &&
			peer.agent.LocalCandidates[i].Priority>>24 != 126 {
			t.Fatalf("host priority type bits = %d", peer.agent.LocalCandidates[i].Priority>>24)
		}
	}
	if srflx == nil {
		t.Fatalf("no srflx candidate in %v", peer.agent.LocalCandidates)
	}
	if srflx.Address != "203.0.113.9" || srflx.Port != 54321 {
		t.Fatalf("srflx = %s:%d, want 203.0.113.9:54321", srflx.Address, srflx.Port)
	}
	if srflx.Priority>>24 != 100 {
		t.Fatalf("srflx priority type bits = %d, want 100", srflx.Priority>>24)
	}
	sdp := srflx.ToSDP()
	if !strings.Contains(sdp, "typ srflx") || !strings.Contains(sdp, "raddr 127.0.0.1") {
		t.Fatalf("srflx SDP = %q", sdp)
	}
	parsed := CandidateFromSDP(strings.TrimPrefix(sdp, "a="))
	if parsed == nil || parsed.Type != "srflx" || parsed.RAddr != "127.0.0.1" || parsed.RPort != srflx.RPort {
		t.Fatalf("parsed = %+v", parsed)
	}
}

func TestSrflxOfferAnswerConnect(t *testing.T) {
	server := fakeStunServer(t, nil)
	newSrflxPeer := func() *Peer {
		// The advertised host address is deliberately unreachable, so
		// a successful connection can only have used the srflx
		// candidate learned from the STUN server.
		peer, err := NewPeer(PeerOptions{RequirePeerCertificate: false, StunServers: []string{server}, LocalIPs: []string{"10.11.12.13"}})
		if err != nil {
			t.Fatal(err)
		}
		return peer
	}
	offerer := newSrflxPeer()
	answerer := newSrflxPeer()

	offer := offerer.CreateOffer()
	if !strings.Contains(offer, "typ srflx") {
		t.Fatalf("offer has no srflx candidate:\n%s", offer)
	}
	answer, err := answerer.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(answer, "typ srflx") {
		t.Fatalf("answer has no srflx candidate:\n%s", answer)
	}
	if err := offerer.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}
	// Connects run concurrently: ConnectWithOptions blocks in the
	// DTLS handshake until the peer's side also runs.
	type connResult struct {
		ep  *DcEndpoint
		err error
	}
	connA := make(chan connResult, 1)
	connB := make(chan connResult, 1)
	go func() {
		ep, err := offerer.ConnectWithOptions(true)
		connA <- connResult{ep, err}
	}()
	go func() {
		ep, err := answerer.ConnectWithOptions(false)
		connB <- connResult{ep, err}
	}()
	resA := <-connA
	if resA.err != nil {
		t.Fatal(resA.err)
	}
	resB := <-connB
	if resB.err != nil {
		t.Fatal(resB.err)
	}
	epA, epB := resA.ep, resB.ep
	type result struct {
		text string
		err  error
	}
	done := make(chan result, 1)
	epA.SetOnChannel(func(ch *DataChannel) {
		ch.OnMessage(func(data []byte, isText bool) {
			done <- result{string(data), nil}
		})
	})
	out := epB.OpenChannel(DefaultChannelParams("echo"))
	out.Send([]byte("via-srflx"))
	select {
	case res := <-done:
		if res.text != "via-srflx" {
			t.Fatalf("got %q", res.text)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for message over srflx-connected peers")
	}
}
