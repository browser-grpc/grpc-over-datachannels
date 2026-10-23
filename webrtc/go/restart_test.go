package dcwebrtc

// ICE restart (RFC 8445 §5.1): fresh credentials and a new
// nomination underneath the live DTLS/SCTP association. Media
// (the same DataChannel) keeps flowing, renomination fires on
// both peers, and either side may initiate.

import (
	"strings"
	"testing"
	"time"
)

func TestICERestartRenominates(t *testing.T) {
	renominatedA := make(chan struct{}, 4)
	renominatedB := make(chan struct{}, 4)
	failed := make(chan struct{}, 1)
	newPeer := func(onRenominated func()) *Peer {
		peer, err := NewPeer(PeerOptions{
			LocalIPs:               []string{"127.0.0.1"},
			RequirePeerCertificate: true,
			ConsentInterval:        100 * time.Millisecond,
			ConsentExpiry:          800 * time.Millisecond,
			OnConsentFailure:       func() { failed <- struct{}{} },
			OnRenominated:          onRenominated,
		})
		if err != nil {
			t.Fatal(err)
		}
		return peer
	}
	a := newPeer(func() { renominatedA <- struct{}{} })
	defer a.Close()
	b := newPeer(func() { renominatedB <- struct{}{} })
	defer b.Close()

	offer := a.CreateOffer()
	answer, err := b.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}
	offerDesc, _ := ParseSDP(offer)
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

	replies := make(chan string, 8)
	epB.SetOnChannel(func(channel *DataChannel) {
		channel.OnMessage(func(data []byte, isText bool) {
			channel.Send([]byte("echo:" + string(data)))
		})
	})
	ch := epA.OpenChannel(DefaultChannelParams("echo"))
	ch.OnMessage(func(data []byte, isText bool) { replies <- string(data) })
	echo := func(msg string) {
		t.Helper()
		ch.Send([]byte(msg))
		select {
		case text := <-replies:
			if text != "echo:"+msg {
				t.Fatalf("reply %q for %q", text, msg)
			}
		case <-time.After(10 * time.Second):
			t.Fatalf("no echo reply for %q", msg)
		}
	}
	echo("before-restart")

	restart := func(initiator, responder *Peer, expectUfragOf string) {
		t.Helper()
		restartOffer := initiator.CreateRestartOffer()
		desc, err := ParseSDP(restartOffer)
		if err != nil {
			t.Fatal(err)
		}
		if desc.Ufrag == expectUfragOf {
			t.Fatalf("restart offer kept ufrag %q", desc.Ufrag)
		}
		restartAnswer, err := responder.HandleRestartOffer(restartOffer)
		if err != nil {
			t.Fatal(err)
		}
		if err := initiator.HandleRestartAnswer(restartAnswer); err != nil {
			t.Fatal(err)
		}
		// Media must keep flowing on the same channel, before
		// and after renomination.
		echo("during-restart")
		for _, ch := range []chan struct{}{renominatedA, renominatedB} {
			select {
			case <-ch:
			case <-time.After(10 * time.Second):
				t.Fatal("renomination never fired")
			}
		}
		echo("after-restart")
	}

	restart(a, b, offerDesc.Ufrag)
	if got := a.agent.Generation(); got != 1 {
		t.Fatalf("offerer generation = %d, want 1", got)
	}
	if got := b.agent.Generation(); got != 1 {
		t.Fatalf("answerer generation = %d, want 1", got)
	}

	// The other side may initiate the next restart.
	restart(b, a, strings.Clone(b.agent.LocalUfrag))
	if got := a.agent.Generation(); got != 2 {
		t.Fatalf("offerer generation after second restart = %d, want 2", got)
	}

	// Consent keeps passing on the new pair: no failure may
	// fire well past the (short) expiry.
	select {
	case <-failed:
		t.Fatal("consent failure fired after restart")
	case <-time.After(1800 * time.Millisecond):
	}
}
