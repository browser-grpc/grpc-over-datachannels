
package dcwebrtc

import (
	"net"
	"strings"
	"sync"
	"time"

	"github.com/browser-grpc/grpc-over-datachannels/webrtc/go/iceffi"
)

// ICE agent (default): the shared Rust core
// (crates/dc-ice-ffi) behind the same IceAgent API the
// mirrored Go stack exposes (ice_agent.go). The public
// fields stay Go-side mirrors (peer.go reads and appends
// them directly); every method syncs pending changes into
// the core before it acts. Core-owned state — validity,
// nomination, consent, generation — is read back from the
// core, never shadowed.

type IceAgent struct {
	LocalUfrag  string
	LocalPwd    string
	RemoteUfrag string
	RemotePwd   string

	LocalCandidates  []Candidate
	RemoteCandidates []Candidate
	Nominated        *net.UDPAddr

	core         *iceffi.Agent
	syncedUfrag  string
	syncedPwd    string
	pushedLocal  int
	pushedRemote map[string]bool

	// mu guards RemoteCandidates, exactly as in the
	// mirrored agent (peer.go locks it directly).
	mu sync.Mutex
}

// NewIceAgent builds an agent on the Rust core;
// controlling selects the ICE role.
func NewIceAgent(controlling bool) *IceAgent {
	agent := &IceAgent{
		core:         iceffi.New(controlling),
		pushedRemote: map[string]bool{},
	}
	agent.LocalUfrag = agent.core.LocalUfrag()
	agent.LocalPwd = agent.core.LocalPwd()
	agent.syncedUfrag = agent.LocalUfrag
	agent.syncedPwd = agent.LocalPwd
	return agent
}

// syncLocked pushes Go-side mirror changes (credentials
// overwritten directly, appended local candidates,
// mDNS-rewritten remote candidates) into the core.
// Caller must hold mu (or be in construction).
func (a *IceAgent) syncLocked() {
	if a.LocalUfrag != a.syncedUfrag || a.LocalPwd != a.syncedPwd {
		_ = a.core.SetLocalCredentials(a.LocalUfrag, a.LocalPwd)
		a.syncedUfrag = a.LocalUfrag
		a.syncedPwd = a.LocalPwd
	}
	for a.pushedLocal < len(a.LocalCandidates) {
		c := a.LocalCandidates[a.pushedLocal]
		_ = a.core.AddLocalCandidate(strings.TrimPrefix(c.ToSDP(), "a="))
		a.pushedLocal++
	}
	for _, c := range a.RemoteCandidates {
		if !a.pushedRemote[c.Key()] {
			_, _ = a.core.AddRemoteCandidate(strings.TrimPrefix(c.ToSDP(), "a="))
			a.pushedRemote[c.Key()] = true
		}
	}
}

// refreshNominatedLocked mirrors the core's nominated
// pair into the public field.
func (a *IceAgent) refreshNominatedLocked() {
	addr := a.core.Nominated()
	if addr == "" {
		a.Nominated = nil
		return
	}
	if udp, err := net.ResolveUDPAddr("udp", addr); err == nil {
		a.Nominated = udp
	}
}

// Controlling reports the (possibly repaired) ICE role.
func (a *IceAgent) Controlling() bool { return a.core.Controlling() }

// SetControlling sets the ICE role before checks begin.
func (a *IceAgent) SetControlling(controlling bool) { a.core.SetControlling(controlling) }

// SetRemote installs the peer's credentials and candidates.
func (a *IceAgent) SetRemote(ufrag, pwd string, candidates []Candidate) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.RemoteUfrag = ufrag
	a.RemotePwd = pwd
	a.RemoteCandidates = candidates
	_ = a.core.SetRemote(ufrag, pwd)
	a.pushedRemote = map[string]bool{}
	a.syncLocked()
}

// Restart begins an ICE restart (RFC 8445 §5.1): the core
// regenerates credentials and bumps its generation; the
// nominated pair is retained until renomination.
func (a *IceAgent) Restart() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.core.Restart()
	a.LocalUfrag = a.core.LocalUfrag()
	a.LocalPwd = a.core.LocalPwd()
	a.syncedUfrag = a.LocalUfrag
	a.syncedPwd = a.LocalPwd
}

// Generation is the current ICE generation.
func (a *IceAgent) Generation() int { return int(a.core.Generation()) }

// Renominated reports whether the nominated pair belongs
// to the current generation.
func (a *IceAgent) Renominated() bool { return a.core.Renominated() }

// NominatedAddr is the currently nominated remote address.
func (a *IceAgent) NominatedAddr() *net.UDPAddr {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.refreshNominatedLocked()
	return a.Nominated
}

// AddRemoteCandidate trickles one remote candidate in;
// false when already known (same address:port).
func (a *IceAgent) AddRemoteCandidate(c Candidate) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, existing := range a.RemoteCandidates {
		if existing.Key() == c.Key() {
			return false
		}
	}
	a.RemoteCandidates = append(a.RemoteCandidates, c)
	a.syncLocked()
	return true
}

func udpAddr(addr string) *net.UDPAddr {
	udp, _ := net.ResolveUDPAddr("udp", addr)
	return udp
}

func addrCandidate(addr string) Candidate {
	udp := udpAddr(addr)
	if udp == nil {
		return Candidate{}
	}
	return Candidate{Address: udp.IP.String(), Port: udp.Port}
}

// DueChecks returns the checks due now.
func (a *IceAgent) DueChecks() []Check {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.syncLocked()
	packets, err := a.core.DueChecks()
	if err != nil {
		return nil
	}
	out := make([]Check, 0, len(packets))
	for _, p := range packets {
		out = append(out, Check{Bytes: p.Bytes, Remote: addrCandidate(p.Addr)})
	}
	return out
}

// HandleStun processes one STUN packet from src.
func (a *IceAgent) HandleStun(raw []byte, src *net.UDPAddr) ([]StunResponse, []IceEvent) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.syncLocked()
	packets, events, err := a.core.HandleStun(raw, src.String())
	if err != nil {
		return nil, nil
	}
	responses := make([]StunResponse, 0, len(packets))
	for _, p := range packets {
		responses = append(responses, StunResponse{Bytes: p.Bytes, Remote: udpAddr(p.Addr)})
	}
	out := make([]IceEvent, 0, len(events))
	for _, ev := range events {
		typ := "pair-valid"
		if ev.Kind == iceffi.EventNominated {
			typ = "nominated"
		}
		out = append(out, IceEvent{Type: typ, Remote: udpAddr(ev.Addr)})
	}
	a.refreshNominatedLocked()
	return responses, out
}

// ConsentCheck builds one consent-freshness Binding
// request for the nominated pair, or false before
// nomination / during a restart.
func (a *IceAgent) ConsentCheck() (Check, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.syncLocked()
	packets, err := a.core.ConsentCheck()
	if err != nil || len(packets) == 0 {
		return Check{}, false
	}
	return Check{Bytes: packets[0].Bytes, Remote: addrCandidate(packets[0].Addr)}, true
}

// TouchConsent marks consent as freshly confirmed.
func (a *IceAgent) TouchConsent() { a.core.TouchConsent() }

// ConsentExpired reports whether consent for the
// nominated pair has lapsed within expiry.
func (a *IceAgent) ConsentExpired(expiry time.Duration) bool {
	return a.core.ConsentExpired(uint64(expiry / time.Millisecond))
}
