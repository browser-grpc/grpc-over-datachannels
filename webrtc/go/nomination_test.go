package dcwebrtc

import (
	"encoding/hex"
	"net"
	"testing"
	"time"
)

// The nominating check is a STUN transaction, not a one-shot:
// it must be retransmitted (paced) until its Binding success
// arrives, and stop once the pair is nominated.
func TestNominationRetransmit(t *testing.T) {
	a := NewIceAgent(true) // controlling
	b := NewIceAgent(false)
	srcA := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 4000}
	srcB := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 5000}
	a.LocalCandidates = []Candidate{HostCandidate("127.0.0.1", 4000, "a")}
	b.LocalCandidates = []Candidate{HostCandidate("127.0.0.1", 5000, "b")}
	a.SetRemote(b.LocalUfrag, b.LocalPwd, b.LocalCandidates)
	b.SetRemote(a.LocalUfrag, a.LocalPwd, a.LocalCandidates)

	nominating := func() int {
		n := 0
		for _, entry := range a.outstanding {
			if entry.nominate {
				n++
			}
		}
		return n
	}

	// B's regular check validates the pair at A.
	a.HandleStun(b.DueChecks()[0].Bytes, srcB)

	checks := a.DueChecks()
	if nominating() != 1 {
		t.Fatalf("first DueChecks: %d nominating checks, want 1", nominating())
	}
	a.DueChecks()
	if nominating() != 1 {
		t.Fatalf("immediate DueChecks must be paced, got %d nominating", nominating())
	}

	// Age the stamp past the retransmit interval: a fresh
	// nominating transaction is due.
	key := b.LocalCandidates[0].Key()
	a.nominatingSentAt[key] = time.Now().Add(-time.Second)
	checks = a.DueChecks()
	if nominating() != 2 {
		t.Fatalf("after retransmit interval: %d nominating, want 2", nominating())
	}

	// Deliver the newest nominating check to B and return its
	// success to A: the pair nominates and checks stop.
	var nominatingBytes []byte
	for _, check := range checks {
		msg := DecodeStun(check.Bytes)
		if entry, ok := a.outstanding[hex.EncodeToString(msg.TransactionID[:])]; ok && entry.nominate {
			nominatingBytes = check.Bytes
		}
	}
	if nominatingBytes == nil {
		t.Fatal("no nominating check in DueChecks output")
	}
	responses, _ := b.HandleStun(nominatingBytes, srcA)
	if len(responses) != 1 {
		t.Fatalf("controlled side produced %d responses, want 1", len(responses))
	}
	a.HandleStun(responses[0].Bytes, srcB)
	if a.Nominated == nil {
		t.Fatal("pair not nominated after success response")
	}
	if due := a.DueChecks(); len(due) != 0 {
		t.Fatalf("checks continue after nomination: %d", len(due))
	}
}
