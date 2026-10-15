// Server-reflexive (srflx) candidate gathering: a plain STUN Binding
// request to a STUN server reveals the mapped address of the peer
// socket, which becomes an srflx candidate (RFC 8445 §5.1.2). The
// request rides the peer's own socket so the mapping is the one ICE
// checks will use; the read loop demultiplexes the response by
// transaction id before the ICE agent sees it.
package dcwebrtc

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"net"
	"strconv"
	"sync"
	"time"
)

// decodeXorMappedAddress extracts the address from an XOR-MAPPED-ADDRESS
// attribute value (IPv4), using the transaction id as the XOR key
// (the caller passes the full message for the key).
func decodeXorMappedAddress(msg *StunMessage) *net.UDPAddr {
	value := msg.attr(StunAttrXorMappedAddress)
	if value == nil {
		value = msg.attr(StunAttrMappedAddress)
		if value == nil {
			return nil
		}
		// Plain MAPPED-ADDRESS: no XOR.
		if len(value) < 8 || value[1] != 1 {
			return nil
		}
		port := int(binary.BigEndian.Uint16(value[2:4]))
		ip := net.IPv4(value[4], value[5], value[6], value[7])
		return &net.UDPAddr{IP: ip, Port: port}
	}
	if len(value) < 8 || value[1] != 1 {
		return nil
	}
	port := int(binary.BigEndian.Uint16(value[2:4])) ^ (StunMagic >> 16)
	xaddr := binary.BigEndian.Uint32(value[4:8])
	ipNum := xaddr ^ StunMagic
	ip := net.IPv4(byte(ipNum>>24), byte(ipNum>>16), byte(ipNum>>8), byte(ipNum))
	return &net.UDPAddr{IP: ip, Port: port}
}

// srflxWaiters tracks in-flight gathering requests by transaction id.
type srflxWaiters struct {
	mu      sync.Mutex
	waiters map[string]chan *net.UDPAddr
}

func (w *srflxWaiters) register(tid string) chan *net.UDPAddr {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.waiters == nil {
		w.waiters = map[string]chan *net.UDPAddr{}
	}
	ch := make(chan *net.UDPAddr, 1)
	w.waiters[tid] = ch
	return ch
}

func (w *srflxWaiters) resolve(tid string, addr *net.UDPAddr) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	ch, ok := w.waiters[tid]
	if ok {
		delete(w.waiters, tid)
		ch <- addr
	}
	return ok
}

func (w *srflxWaiters) cancel(tid string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	delete(w.waiters, tid)
}

// GatherSrflx queries one STUN server (host:port) and appends the
// resulting srflx candidate to the agent's local candidates. It is
// called automatically from CreateOffer/HandleOffer for every server
// in PeerOptions.StunServers, and may also be called directly.
// Unreachable servers are ignored (host candidates still apply).
func (p *Peer) GatherSrflx(server string, timeout time.Duration) error {
	serverAddr, err := net.ResolveUDPAddr("udp4", server)
	if err != nil {
		return err
	}
	msg := newStunMessage(StunTypeBindingRequest)
	tid := hex.EncodeToString(msg.TransactionID[:])
	ch := p.srflx.register(tid)
	defer p.srflx.cancel(tid)
	if _, err := p.socket.WriteToUDP(msg.Encode(nil), serverAddr); err != nil {
		return err
	}
	select {
	case mapped := <-ch:
		if mapped == nil {
			return errors.New("srflx: no mapped address in response")
		}
		base := Candidate{Address: p.socket.LocalAddr().(*net.UDPAddr).IP.String(),
			Port: p.socket.LocalAddr().(*net.UDPAddr).Port, Type: "host"}
		if len(p.agent.LocalCandidates) > 0 {
			base = p.agent.LocalCandidates[0]
		}
		cand := SrflxCandidate(mapped.IP.String(), mapped.Port, base,
			strconv.Itoa(len(p.agent.LocalCandidates)+1))
		for _, existing := range p.agent.LocalCandidates {
			if existing.Address == cand.Address && existing.Port == cand.Port {
				return nil // already have this address (e.g. host on a flat network)
			}
		}
		p.agent.LocalCandidates = append(p.agent.LocalCandidates, cand)
		p.emitLocalCandidate(cand)
		return nil
	case <-time.After(timeout):
		return errors.New("srflx: timed out waiting for STUN response")
	}
}

// gatherFromOptions gathers srflx (Binding) and relay (TURN
// Allocate) candidates for the configured servers, once per peer,
// before an offer/answer is produced.
func (p *Peer) gatherFromOptions() {
	if p.gathered {
		return
	}
	p.gathered = true
	for _, server := range p.options.StunServers {
		_ = p.GatherSrflx(server, 1200*time.Millisecond)
	}
	for _, server := range p.options.TurnServers {
		if err := p.AllocateTurn(server, 2*time.Second); err == nil {
			break // one relay candidate is enough
		}
	}
}
