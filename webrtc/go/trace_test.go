package dcwebrtc

import (
	"sync"
	"testing"
	"time"
)

// Stack tracing parity: Connect emits ice.nominated,
// dtls.handshake, endpoint.ready to the registered observer;
// dormant (and harmless) with none, and a panicking observer
// cannot break the connection. The Go stack has no DTLS
// session resumption, so the handshake detail is always "full".

func traceConnectPair(t *testing.T) {
	t.Helper()
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
	errs := make(chan error, 2)
	go func() {
		_, err := a.Connect()
		errs <- err
	}()
	go func() {
		_, err := b.Connect()
		errs <- err
	}()
	for i := 0; i < 2; i++ {
		select {
		case err := <-errs:
			if err != nil {
				t.Fatalf("connect: %v", err)
			}
		case <-time.After(30 * time.Second):
			t.Fatal("connect timed out")
		}
	}
}

func TestStackTraceEvents(t *testing.T) {
	var mu sync.Mutex
	var events []StackEvent
	SetStackObserver(func(e StackEvent) {
		mu.Lock()
		events = append(events, e)
		mu.Unlock()
	})
	traceConnectPair(t)
	SetStackObserver(nil)

	counts := map[string]int{}
	roles := map[string]bool{}
	for _, e := range events {
		counts[e.Name]++
		if e.Name == "endpoint.ready" {
			roles[e.Detail] = true
		}
		if e.Name == "dtls.handshake" && e.Detail != "full" {
			t.Errorf("dtls.handshake detail = %q, want full", e.Detail)
		}
	}
	for _, name := range []string{"ice.nominated", "dtls.handshake", "endpoint.ready"} {
		if counts[name] != 2 {
			t.Errorf("%s count = %d, want 2 (events: %v)", name, counts[name], events)
		}
	}
	if !roles["client"] || !roles["server"] {
		t.Errorf("endpoint.ready roles = %v", roles)
	}

	// Dormant and panicking observers are both safe.
	SetStackObserver(nil)
	traceConnectPair(t)
	SetStackObserver(func(StackEvent) { panic("observer blew up") })
	traceConnectPair(t)
	SetStackObserver(nil)
}
