// SDP (RFC 8866) session descriptions in the WebRTC data-channel
// profile: one application m-section with ICE credentials, DTLS
// fingerprint + setup, host candidates and the SCTP port.
package dcwebrtc

import (
	"fmt"
	"strings"
)

// SessionDescription is the parsed/generated SDP subset.
type SessionDescription struct {
	Ufrag       string
	Pwd         string
	Fingerprint string // uppercase colon-separated SHA-256 hex
	Setup       string // active | passive | actpass
	Candidates  []Candidate
	SctpPort    int
}

// Generate renders an SDP of the given type ("offer" or "answer").
func (d *SessionDescription) Generate(typ string) string {
	lines := []string{
		"v=0",
		"o=- 0 0 IN IP4 0.0.0.0",
		"s=-",
		"t=0 0",
		"a=group:BUNDLE 0",
		"m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
		"c=IN IP4 0.0.0.0",
		"a=mid:0",
		"a=ice-options:trickle",
		fmt.Sprintf("a=ice-ufrag:%s", d.Ufrag),
		fmt.Sprintf("a=ice-pwd:%s", d.Pwd),
		fmt.Sprintf("a=fingerprint:sha-256 %s", d.Fingerprint),
		fmt.Sprintf("a=setup:%s", d.Setup),
	}
	for _, c := range d.Candidates {
		lines = append(lines, c.ToSDP())
	}
	lines = append(lines, "a=end-of-candidates")
	sctpPort := d.SctpPort
	if sctpPort == 0 {
		sctpPort = 5000
	}
	lines = append(lines, fmt.Sprintf("a=sctp-port:%d", sctpPort))
	lines = append(lines, "a=max-message-size:262144")
	_ = typ
	return strings.Join(lines, "\r\n") + "\r\n"
}

// ParseSDP parses an SDP offer/answer into the subset.
func ParseSDP(text string) (*SessionDescription, error) {
	d := &SessionDescription{SctpPort: 5000}
	seenMedia := false
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, "\r")
		switch {
		case strings.HasPrefix(line, "m=application"):
			seenMedia = true
		case strings.HasPrefix(line, "a=ice-ufrag:"):
			d.Ufrag = strings.TrimPrefix(line, "a=ice-ufrag:")
		case strings.HasPrefix(line, "a=ice-pwd:"):
			d.Pwd = strings.TrimPrefix(line, "a=ice-pwd:")
		case strings.HasPrefix(line, "a=fingerprint:"):
			d.Fingerprint = strings.TrimSpace(strings.TrimPrefix(line, "a=fingerprint:sha-256"))
		case strings.HasPrefix(line, "a=setup:"):
			d.Setup = strings.TrimPrefix(line, "a=setup:")
		case strings.HasPrefix(line, "a=candidate:"):
			if c := CandidateFromSDP(strings.TrimPrefix(line, "a=")); c != nil {
				d.Candidates = append(d.Candidates, *c)
			}
		case strings.HasPrefix(line, "a=sctp-port:"):
			fmt.Sscanf(strings.TrimPrefix(line, "a=sctp-port:"), "%d", &d.SctpPort)
		}
	}
	if !seenMedia {
		return nil, fmt.Errorf("sdp: no application m-section")
	}
	if d.Ufrag == "" || d.Pwd == "" || d.Fingerprint == "" || d.Setup == "" {
		return nil, fmt.Errorf("sdp: missing ice/dtls fields")
	}
	return d, nil
}
