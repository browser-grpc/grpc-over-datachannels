package dcwebrtc

import (
	"os"
	"testing"
	"time"
)

// Live STUN smoke test (opt-in): every other STUN test runs
// against an in-process fake on loopback, so nothing exercised
// a real public STUN server, real NAT mapping, or real UDP
// egress. This test gathers a server-reflexive candidate from
// Google's public STUN server. It is OUT of the default gate
// (CI stays hermetic): run via `make test-live-stun` or with
// GRPC_DC_LIVE_STUN=1 in the environment.

func TestLiveStunSrflx(t *testing.T) {
	if os.Getenv("GRPC_DC_LIVE_STUN") == "" {
		t.Skip("GRPC_DC_LIVE_STUN not set; live STUN smoke test skipped")
	}
	peer, err := NewPeer(PeerOptions{RequirePeerCertificate: false})
	if err != nil {
		t.Fatal(err)
	}
	if err := peer.GatherSrflx("stun.l.google.com:19302", 5*time.Second); err != nil {
		t.Fatalf("GatherSrflx against Google STUN: %v", err)
	}
	var srflx *Candidate
	for i := range peer.agent.LocalCandidates {
		if peer.agent.LocalCandidates[i].Type == "srflx" {
			srflx = &peer.agent.LocalCandidates[i]
		}
	}
	if srflx == nil {
		t.Fatalf("no srflx candidate gathered: %v", peer.agent.LocalCandidates)
	}
	ip := srflx.Address
	if ip == "127.0.0.1" || ip == "::1" {
		t.Fatalf("srflx address is loopback, want the public egress mapping: %s", ip)
	}
	t.Logf("live srflx: %s:%d (raddr %s:%d)", srflx.Address, srflx.Port, srflx.RAddr, srflx.RPort)
}
