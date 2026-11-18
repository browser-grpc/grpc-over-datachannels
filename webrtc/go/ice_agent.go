//go:build !dc_ice

package dcwebrtc

// ICE agent: the mirrored Go stack (default backend).
// Under the dc_ice tag, ice_agent_ffi.go supplies the
// same IceAgent API over the shared Rust core
// (crates/dc-ice-ffi).

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"net"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// IceAgent is the connectivity-check state machine.
type IceAgent struct {
	LocalUfrag  string
	LocalPwd    string
	RemoteUfrag string
	RemotePwd   string

	controlling      atomic.Bool
	tieBreaker       uint64
	LocalCandidates  []Candidate
	RemoteCandidates []Candidate
	outstanding      map[string]outstandingCheck
	valid            map[string]bool
	Nominated        *net.UDPAddr
	// nominatingSentAt paces nomination retransmission per
	// pair (see DueChecks).
	nominatingSentAt map[string]time.Time

	// lastConsent is when consent for the nominated pair was
	// last confirmed (nomination, or a Binding success for it).
	lastConsent time.Time

	// generation increments on every ICE restart (RFC 8445
	// §5.1); nominatedGen is the generation that produced the
	// current nomination. While they differ a restart is in
	// flight: checks run again, consent pauses, and the old
	// nominated pair keeps serving media until renomination.
	generation   int
	nominatedGen int

	// mu guards RemoteCandidates (trickle additions race the
	// connect loop and the read loop) and the maps it is used with.
	mu sync.Mutex
}

// NewIceAgent builds an agent; controlling selects the ICE role.
func NewIceAgent(controlling bool) *IceAgent {
	var tb [8]byte
	_, _ = rand.Read(tb[:])
	agent := &IceAgent{
		LocalUfrag:       randomUfrag(),
		LocalPwd:         randomPassword(),
		tieBreaker:       binary.BigEndian.Uint64(tb[:]),
		outstanding:      map[string]outstandingCheck{},
		valid:            map[string]bool{},
		nominatingSentAt: map[string]time.Time{},
	}
	agent.controlling.Store(controlling)
	return agent
}

// Controlling reports the (possibly repaired) ICE role.
func (a *IceAgent) Controlling() bool { return a.controlling.Load() }

// SetControlling sets the ICE role before checks begin.
func (a *IceAgent) SetControlling(controlling bool) { a.controlling.Store(controlling) }

// SetRemote installs the peer's credentials and candidates.
func (a *IceAgent) SetRemote(ufrag, pwd string, candidates []Candidate) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.RemoteUfrag = ufrag
	a.RemotePwd = pwd
	a.RemoteCandidates = candidates
	// New remote credentials invalidate prior check state
	// (initial connect: already empty).
	a.valid = map[string]bool{}
	a.outstanding = map[string]outstandingCheck{}
	a.nominatingSentAt = map[string]time.Time{}
}

// Restart begins an ICE restart (RFC 8445 §5.1): fresh local
// credentials, check state cleared, generation bumped. The
// nominated pair is retained until a pair from the new
// generation is nominated, so media keeps flowing meanwhile.
func (a *IceAgent) Restart() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.LocalUfrag = randomUfrag()
	a.LocalPwd = randomPassword()
	a.generation++
	a.valid = map[string]bool{}
	a.outstanding = map[string]outstandingCheck{}
	a.nominatingSentAt = map[string]time.Time{}
}

// Generation is the current ICE generation (0 at connect, +1
// per restart).
func (a *IceAgent) Generation() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.generation
}

// Renominated reports whether the nominated pair belongs to
// the current generation (i.e. no restart is in flight).
func (a *IceAgent) Renominated() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.Nominated != nil && a.nominatedGen == a.generation
}

// NominatedAddr is the currently nominated remote address.
func (a *IceAgent) NominatedAddr() *net.UDPAddr {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.Nominated
}

// AddRemoteCandidate trickles one remote candidate in after the
// remote description (RFC 8445 §4.1.1: candidates may arrive
// incrementally). Returns false when the candidate is already
// known (same address:port) so duplicate trickle is a no-op.
func (a *IceAgent) AddRemoteCandidate(c Candidate) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, existing := range a.RemoteCandidates {
		if existing.Key() == c.Key() {
			return false
		}
	}
	a.RemoteCandidates = append(a.RemoteCandidates, c)
	return true
}

func (a *IceAgent) localPriority() uint32 {
	if len(a.LocalCandidates) > 0 {
		return a.LocalCandidates[0].Priority
	}
	return hostPriority(1)
}

// Check is one outbound connectivity check.
func (a *IceAgent) buildCheck(remote Candidate, nominate bool) Check {
	msg := newStunMessage(StunTypeBindingRequest)
	msg.addAttr(StunAttrUsername, []byte(a.RemoteUfrag+":"+a.LocalUfrag))
	prio := make([]byte, 4)
	binary.BigEndian.PutUint32(prio, a.localPriority())
	msg.addAttr(StunAttrPriority, prio)
	tb := make([]byte, 8)
	binary.BigEndian.PutUint64(tb, a.tieBreaker)
	roleAttr := uint16(StunAttrIceControlled)
	if a.controlling.Load() {
		roleAttr = StunAttrIceControlling
	}
	msg.addAttr(roleAttr, tb)
	if nominate && a.controlling.Load() {
		msg.addAttr(StunAttrUseCandidate, nil)
	}
	bytes := msg.Encode([]byte(a.RemotePwd))
	a.outstanding[hex.EncodeToString(msg.TransactionID[:])] = outstandingCheck{remote, nominate}
	return Check{Bytes: bytes, Remote: remote}
}

// nominationRetransmit paces re-sends of the nominating check
// for one pair until its Binding success arrives.
const nominationRetransmit = 250 * time.Millisecond

// DueChecks returns the checks to send now.
func (a *IceAgent) DueChecks() []Check {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.Nominated != nil && a.nominatedGen == a.generation {
		return nil
	}
	var out []Check
	for _, remote := range a.RemoteCandidates {
		out = append(out, a.buildCheck(remote, false))
	}
	if a.controlling.Load() {
		// Nominate the best valid pair, retransmitting the
		// nominating check until its success response lands
		// (RFC 8489 transactions are not fire-and-forget: a
		// single USE-CANDIDATE can be lost, or reach the peer
		// before its side of the pair has validated).
		if best := a.bestValidPair(); best != nil {
			key := best.Key()
			if last, ok := a.nominatingSentAt[key]; !ok || time.Since(last) >= nominationRetransmit {
				a.nominatingSentAt[key] = time.Now()
				out = append(out, a.buildCheck(*best, true))
			}
		}
	}
	return out
}

func (a *IceAgent) bestValidPair() *Candidate {
	var valid []Candidate
	for _, c := range a.RemoteCandidates {
		if a.valid[c.Key()] {
			valid = append(valid, c)
		}
	}
	if len(valid) == 0 {
		// Peer-reflexive fallback (mirrors the Rust agent): the
		// peer's checks revealed a reachable address that no
		// resolvable SDP candidate matches — e.g. an mDNS
		// candidate whose peer-reflexive rewrite never fires
		// because the browser stops checking once its own pair
		// validates. Nominate the learned address directly.
		for key := range a.valid {
			if addr, err := net.ResolveUDPAddr("udp", key); err == nil {
				c := HostCandidate(addr.IP.String(), addr.Port, "peer-reflexive")
				return &c
			}
		}
		return nil
	}
	sort.SliceStable(valid, func(i, j int) bool {
		return pairPriority(a.localPriority(), valid[j].Priority, a.controlling.Load()) >
			pairPriority(a.localPriority(), valid[i].Priority, a.controlling.Load())
	})
	return &valid[0]
}

func isIPv4(address string) bool {
	ip := net.ParseIP(address)
	return ip != nil && ip.To4() != nil
}

// HandleStun processes one STUN packet from src.
func (a *IceAgent) HandleStun(raw []byte, src *net.UDPAddr) ([]StunResponse, []IceEvent) {
	a.mu.Lock()
	defer a.mu.Unlock()
	var responses []StunResponse
	var events []IceEvent
	msg := DecodeStun(raw)
	if msg == nil {
		return responses, events
	}
	switch msg.Type {
	case StunTypeBindingRequest:
		username := msg.attr(StunAttrUsername)
		if username == nil {
			return responses, events
		}
		targetUfrag := strings.SplitN(string(username), ":", 2)[0]
		if targetUfrag != a.LocalUfrag {
			return responses, events
		}
		if !msg.CheckIntegrity(raw, []byte(a.LocalPwd)) {
			responses = append(responses, StunResponse{bindingError(msg, 401, "Unauthorized"), src})
			return responses, events
		}
		if a.controlling.Load() {
			if tb := msg.attr(StunAttrIceControlling); tb != nil && len(tb) == 8 {
				if binary.BigEndian.Uint64(tb) >= a.tieBreaker {
					a.controlling.Store(false)
				} else {
					responses = append(responses, StunResponse{bindingError(msg, 487, "Role Conflict"), src})
					return responses, events
				}
			}
		} else {
			if tb := msg.attr(StunAttrIceControlled); tb != nil && len(tb) == 8 {
				if a.tieBreaker >= binary.BigEndian.Uint64(tb) {
					a.controlling.Store(true)
				} else {
					responses = append(responses, StunResponse{bindingError(msg, 487, "Role Conflict"), src})
					return responses, events
				}
			}
		}
		responses = append(responses, StunResponse{bindingSuccess(msg, src, []byte(a.LocalPwd)), src})
		// Peer-reflexive learning (see ice.js): an integrity-valid
		// check from the same port reveals the real IP behind an
		// unresolvable mDNS candidate.
		for i := range a.RemoteCandidates {
			c := &a.RemoteCandidates[i]
			if c.Port == src.Port && !isIPv4(c.Address) {
				c.Address = src.IP.String()
			}
		}
		key := src.String()
		if !a.valid[key] {
			a.valid[key] = true
			events = append(events, IceEvent{"pair-valid", src})
		}
		if !a.controlling.Load() && msg.attr(StunAttrUseCandidate) != nil {
			a.Nominated = src
			a.nominatedGen = a.generation
			a.lastConsent = time.Now()
			events = append(events, IceEvent{"nominated", src})
		}
		// An integrity-valid Binding request from the nominated
		// pair is itself consent evidence (RFC 7675): peers that
		// only ever send checks — ICE-lite dialers whose password
		// we never learn, e.g. rendezvous browsers — keep the
		// pair fresh without any Binding success reaching us.
		if a.Nominated != nil && a.Nominated.String() == src.String() {
			a.lastConsent = time.Now()
		}
	case StunTypeBindingSuccess:
		if !msg.CheckIntegrity(raw, []byte(a.RemotePwd)) {
			return responses, events
		}
		tid := hex.EncodeToString(msg.TransactionID[:])
		entry, ok := a.outstanding[tid]
		if !ok {
			return responses, events
		}
		delete(a.outstanding, tid)
		if !a.valid[entry.remote.Key()] {
			a.valid[entry.remote.Key()] = true
			events = append(events, IceEvent{"pair-valid",
				&net.UDPAddr{IP: net.ParseIP(entry.remote.Address), Port: entry.remote.Port}})
		}
		if a.Nominated != nil && entry.remote.Key() == a.Nominated.String() {
			a.lastConsent = time.Now()
		}
		if entry.nominate {
			a.Nominated = &net.UDPAddr{IP: net.ParseIP(entry.remote.Address), Port: entry.remote.Port}
			a.nominatedGen = a.generation
			a.lastConsent = time.Now()
			events = append(events, IceEvent{"nominated", a.Nominated})
		}
	}
	return responses, events
}

// ConsentCheck builds one consent-freshness Binding request for
// the nominated pair (RFC 8445 §10 / RFC 7675), or false before
// nomination.
func (a *IceAgent) ConsentCheck() (Check, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.Nominated == nil || a.nominatedGen != a.generation {
		// No pair yet, or an ICE restart is in flight: consent
		// pauses until renomination.
		return Check{}, false
	}
	for _, cand := range a.RemoteCandidates {
		if cand.Key() == a.Nominated.String() {
			return a.buildCheck(cand, false), true
		}
	}
	cand := HostCandidate(a.Nominated.IP.String(), a.Nominated.Port, "peer-reflexive")
	return a.buildCheck(cand, false), true
}

// TouchConsent marks consent as freshly confirmed (e.g. the
// DTLS handshake just completed over this pair).
func (a *IceAgent) TouchConsent() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.Nominated != nil {
		a.lastConsent = time.Now()
	}
}

// ConsentExpired reports whether consent for the nominated pair
// has lapsed: no Binding success for it within expiry.
func (a *IceAgent) ConsentExpired(expiry time.Duration) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.Nominated == nil || a.lastConsent.IsZero() || a.nominatedGen != a.generation {
		return false
	}
	return time.Since(a.lastConsent) > expiry
}
