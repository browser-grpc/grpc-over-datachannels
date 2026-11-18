// ICE (RFC 8445) agent — mirroring webrtc/js/ice.js: connectivity
// checks with short-term credentials, tie-breaker role-conflict
// repair, nomination. Remote candidates may arrive inline in SDP
// or trickled afterwards (AddRemoteCandidate).
package dcwebrtc

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

// Candidate is one ICE candidate (host or server-reflexive).
type Candidate struct {
	Foundation string
	Component  int
	Priority   uint32
	Address    string
	Port       int
	// Type is "host" or "srflx"; RAddr/RPort give the base (host)
	// candidate a srflx candidate was gathered from.
	Type  string
	RAddr string
	RPort int
}

// candidatePriority computes the RFC 8445 priority:
// (2^24)*typePreference + (2^8)*localPreference + (256-component).
func candidatePriority(typePreference, component uint32) uint32 {
	return (typePreference << 24) + (65535 << 8) + (256 - component)
}

// canonicalIP renders IP literals in canonical form (dotted
// IPv4 incl. mapped, compressed IPv6); hostnames pass through.
func canonicalIP(address string) string {
	if ip := net.ParseIP(address); ip != nil {
		return ip.String()
	}
	return address
}

// HostCandidate builds a host candidate for address:port.
func HostCandidate(address string, port int, foundation string) Candidate {
	return Candidate{
		Foundation: foundation,
		Component:  1,
		Priority:   hostPriority(1),
		Address:    canonicalIP(address),
		Port:       port,
		Type:       "host",
	}
}

// SrflxCandidate builds a server-reflexive candidate learned from a
// STUN server: address:port is the mapped address, base the host
// candidate it was gathered from (same socket).
func SrflxCandidate(address string, port int, base Candidate, foundation string) Candidate {
	return Candidate{
		Foundation: foundation,
		Component:  1,
		Priority:   candidatePriority(100, 1),
		Address:    address,
		Port:       port,
		Type:       "srflx",
		RAddr:      base.Address,
		RPort:      base.Port,
	}
}

// Key identifies a candidate pair endpoint.
func (c Candidate) Key() string { return net.JoinHostPort(c.Address, strconv.Itoa(c.Port)) }

// ToSDP renders the candidate attribute.
func (c Candidate) ToSDP() string {
	typ := c.Type
	if typ == "" {
		typ = "host"
	}
	// Related address comes before "generation 0": some parsers
	// (Firefox's nICEr) stop scanning extensions at unknown
	// attributes and then reject srflx/relay candidates whose
	// raddr they never saw. Browsers emit this order too.
	out := fmt.Sprintf("a=candidate:%s %d udp %d %s %d typ %s",
		c.Foundation, c.Component, c.Priority, c.Address, c.Port, typ)
	if typ == "srflx" || typ == "relay" {
		out += fmt.Sprintf(" raddr %s rport %d", c.RAddr, c.RPort)
	}
	out += " generation 0"
	return out
}

// CandidateFromSDP parses a candidate attribute, nil when malformed.
func CandidateFromSDP(value string) *Candidate {
	parts := strings.Fields(value)
	if len(parts) < 8 || parts[6] != "typ" {
		return nil
	}
	component, err1 := strconv.Atoi(parts[1])
	priority, err2 := strconv.ParseUint(parts[3], 10, 32)
	port, err3 := strconv.Atoi(parts[5])
	if err1 != nil || err2 != nil || err3 != nil {
		return nil
	}
	cand := &Candidate{
		Foundation: strings.TrimPrefix(parts[0], "candidate:"),
		Component:  component,
		Priority:   uint32(priority),
		Address:    canonicalIP(parts[4]),
		Port:       port,
		Type:       parts[7],
	}
	for i := 8; i+1 < len(parts); i += 2 {
		switch parts[i] {
		case "raddr":
			cand.RAddr = canonicalIP(parts[i+1])
		case "rport":
			cand.RPort, _ = strconv.Atoi(parts[i+1])
		}
	}
	return cand
}

type outstandingCheck struct {
	remote   Candidate
	nominate bool
}

// Check is one connectivity-check packet to send to Remote.
type Check struct {
	Bytes  []byte
	Remote Candidate
}

// StunResponse is a packet to send back to Remote.
type StunResponse struct {
	Bytes  []byte
	Remote *net.UDPAddr
}

// IceEvent reports agent state changes (pair-valid, nominated).
type IceEvent struct {
	Type   string
	Remote *net.UDPAddr
}

