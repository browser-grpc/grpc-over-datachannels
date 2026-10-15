package dcwebrtc

import (
	"testing"
	"time"
)

// Consent freshness (RFC 7675): while both peers answer, no
// failure fires; once the remote socket dies, consent expires
// and OnConsentFailure surfaces it.

func TestConsentFreshnessDetectsDeadPeer(t *testing.T) {
	failed := make(chan struct{}, 1)
	newPeer := func(onFail func()) *Peer {
		peer, err := NewPeer(PeerOptions{
			LocalIPs:               []string{"127.0.0.1"},
			RequirePeerCertificate: true,
			ConsentInterval:        100 * time.Millisecond,
			ConsentExpiry:          800 * time.Millisecond,
			OnConsentFailure:       onFail,
		})
		if err != nil {
			t.Fatal(err)
		}
		return peer
	}
	a := newPeer(func() { failed <- struct{}{} })
	defer a.Close()
	b := newPeer(nil)
	defer b.Close()

	offer := a.CreateOffer()
	answer, err := b.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}
	type result struct{ err error }
	results := make(chan result, 2)
	go func() {
		_, err := a.ConnectWithOptions(true)
		results <- result{err}
	}()
	go func() {
		_, err := b.ConnectWithOptions(true)
		results <- result{err}
	}()
	for i := 0; i < 2; i++ {
		select {
		case r := <-results:
			if r.err != nil {
				t.Fatalf("connect: %v", r.err)
			}
		case <-time.After(30 * time.Second):
			t.Fatal("connect timed out")
		}
	}

	// Healthy pair: consent responses keep flowing, no failure.
	select {
	case <-failed:
		t.Fatal("consent failure fired on a healthy pair")
	case <-time.After(1800 * time.Millisecond):
	}
	if a.ConsentExpired() {
		t.Fatal("consent reported expired on a healthy pair")
	}

	// Kill the remote: its socket stops answering checks.
	_ = b.socket.Close()
	select {
	case <-failed:
	case <-time.After(10 * time.Second):
		t.Fatal("consent failure never fired after the peer died")
	}
	if !a.ConsentExpired() {
		t.Fatal("consent not reported expired after the peer died")
	}
}
