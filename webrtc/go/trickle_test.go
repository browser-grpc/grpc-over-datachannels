package dcwebrtc

import (
	"net"
	"strings"
	"testing"
	"time"
)

// Trickle ICE (RFC 8445 §4.1.1): candidates are removed from the
// SDP and delivered incrementally through AddRemoteCandidate /
// SetOnLocalCandidate instead. The peers here can only connect
// because the trickled candidates arrive.

func stripCandidateLines(sdp string) string {
	var kept []string
	for _, line := range strings.Split(sdp, "\r\n") {
		if !strings.HasPrefix(line, "a=candidate:") {
			kept = append(kept, line)
		}
	}
	return strings.Join(kept, "\r\n")
}

func candidateLinesOf(sdp string) []string {
	var lines []string
	for _, line := range strings.Split(sdp, "\r\n") {
		if strings.HasPrefix(line, "a=candidate:") {
			lines = append(lines, line)
		}
	}
	return lines
}

func tricklePeer(t *testing.T) *Peer {
	t.Helper()
	peer, err := NewPeer(PeerOptions{LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(peer.Close)
	return peer
}

func TestAddRemoteCandidateParsing(t *testing.T) {
	a := tricklePeer(t)
	b := tricklePeer(t)

	offer := a.CreateOffer()
	lines := candidateLinesOf(offer)
	if len(lines) == 0 {
		t.Fatal("offer has no candidates to trickle")
	}
	answer, err := b.HandleOffer(stripCandidateLines(offer))
	if err != nil {
		t.Fatal(err)
	}
	_ = answer
	if len(b.agent.RemoteCandidates) != 0 {
		t.Fatalf("stripped offer left %d remote candidates", len(b.agent.RemoteCandidates))
	}
	// End-of-candidates, empty, and malformed lines are no-ops.
	if b.AddRemoteCandidate("") || b.AddRemoteCandidate("a=end-of-candidates") ||
		b.AddRemoteCandidate("not a candidate") {
		t.Fatal("no-op/malformed line reported as added")
	}
	for _, line := range lines {
		if !b.AddRemoteCandidate(line) {
			t.Fatalf("candidate not added: %s", line)
		}
	}
	// Duplicates (either spelling) are no-ops.
	if b.AddRemoteCandidate(lines[0]) || b.AddRemoteCandidate(strings.TrimPrefix(lines[0], "a=")) {
		t.Fatal("duplicate candidate reported as added")
	}
	if len(b.agent.RemoteCandidates) != len(lines) {
		t.Fatalf("remote candidates = %d, want %d", len(b.agent.RemoteCandidates), len(lines))
	}
}

func TestTrickleLocalCandidateCallback(t *testing.T) {
	fixed := &net.UDPAddr{IP: net.ParseIP("203.0.113.9"), Port: 54321}
	server := fakeStunServer(t, fixed)
	peer := tricklePeer(t)

	var fired []string
	peer.SetOnLocalCandidate(func(line string) { fired = append(fired, line) })
	// Registration replays the host candidate.
	if len(fired) != 1 || !strings.Contains(fired[0], "typ host") {
		t.Fatalf("replay fired %v", fired)
	}
	// A later srflx gathering fires as the candidate is added.
	if err := peer.GatherSrflx(server, 2*time.Second); err != nil {
		t.Fatal(err)
	}
	if len(fired) != 2 || !strings.Contains(fired[1], "typ srflx") {
		t.Fatalf("after gather fired %v", fired)
	}
	if lines := peer.LocalCandidateLines(); len(lines) != 2 {
		t.Fatalf("LocalCandidateLines = %v", lines)
	}
}

func runTrickleEcho(t *testing.T, duringConnect bool) {
	t.Helper()
	a := tricklePeer(t)
	b := tricklePeer(t)

	offer := a.CreateOffer()
	answer, err := b.HandleOffer(stripCandidateLines(offer))
	if err != nil {
		t.Fatal(err)
	}
	if err := a.HandleAnswer(stripCandidateLines(answer)); err != nil {
		t.Fatal(err)
	}
	offerLines := candidateLinesOf(offer)
	answerLines := candidateLinesOf(answer)

	type result struct {
		endpoint *DcEndpoint
		err      error
	}
	results := make(chan result, 2)
	connectBoth := func() {
		go func() {
			endpoint, err := a.ConnectWithOptions(true)
			results <- result{endpoint, err}
		}()
		go func() {
			endpoint, err := b.ConnectWithOptions(true)
			results <- result{endpoint, err}
		}()
	}
	trickleAll := func() {
		for _, line := range offerLines {
			b.AddRemoteCandidate(line)
		}
		b.AddRemoteCandidate("a=end-of-candidates")
		for _, line := range answerLines {
			a.AddRemoteCandidate(line)
		}
		a.AddRemoteCandidate("a=end-of-candidates")
	}
	if duringConnect {
		connectBoth()
		// Let the connect loops start with zero candidates, then
		// trickle in while ICE is running.
		time.Sleep(200 * time.Millisecond)
		trickleAll()
	} else {
		trickleAll()
		connectBoth()
	}

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
			reply := append([]byte("echo:"), data...)
			channel.Send(reply)
		})
	})
	channel := epA.OpenChannel(DefaultChannelParams("echo"))
	got := make(chan []byte, 1)
	channel.OnMessage(func(data []byte, isText bool) {
		cp := make([]byte, len(data))
		copy(cp, data)
		got <- cp
	})
	channel.Send([]byte("via-trickle"))
	select {
	case data := <-got:
		if string(data) != "echo:via-trickle" {
			t.Fatalf("got %q", data)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("echo timed out")
	}
}

func TestTrickleEcho(t *testing.T) { runTrickleEcho(t, false) }

func TestTrickleDuringConnectEcho(t *testing.T) { runTrickleEcho(t, true) }
