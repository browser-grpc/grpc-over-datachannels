package dcwebrtc

import (
	"encoding/binary"
	"net"
	"testing"
)

// response builds a one-question/one-answer mDNS response for
// name with the given record type and rdata (answer name is a
// compression pointer to the question).
func mdnsResponse(name string, rtype uint16, rdata []byte) []byte {
	out := make([]byte, 12)
	binary.BigEndian.PutUint16(out[2:4], 0x8400) // response, authoritative
	binary.BigEndian.PutUint16(out[4:6], 1)      // QDCOUNT
	binary.BigEndian.PutUint16(out[6:8], 1)      // ANCOUNT
	out = append(out, encodeDNSName(name)...)
	out = append(out, 0, 1, 0, 1) // question: A, IN
	out = append(out, 0xc0, 0x0c) // answer name: pointer to question
	fixed := make([]byte, 10)
	binary.BigEndian.PutUint16(fixed[0:2], rtype)
	binary.BigEndian.PutUint16(fixed[2:4], 1) // IN
	binary.BigEndian.PutUint32(fixed[4:8], 120)
	binary.BigEndian.PutUint16(fixed[8:10], uint16(len(rdata)))
	out = append(out, fixed...)
	return append(out, rdata...)
}

func TestParseARecord(t *testing.T) {
	packet := mdnsResponse("abc-123.local", 1, []byte{192, 168, 1, 20})
	if got := ParseARecord(packet, "abc-123.local"); got != "192.168.1.20" {
		t.Fatalf("A record = %q, want 192.168.1.20", got)
	}
	if got := ParseARecord(packet, "other.local"); got != "" {
		t.Fatalf("wrong name parsed: %q", got)
	}
	if got := ParseAAAARecord(packet, "abc-123.local"); got != "" {
		t.Fatalf("A packet yielded AAAA: %q", got)
	}
}

func TestParseAAAARecord(t *testing.T) {
	rdata := net.ParseIP("fd00::1234").To16()
	packet := mdnsResponse("abc-123.local", 28, rdata)
	if got := ParseAAAARecord(packet, "abc-123.local"); got != "fd00::1234" {
		t.Fatalf("AAAA record = %q, want fd00::1234", got)
	}
	if got := ParseARecord(packet, "abc-123.local"); got != "" {
		t.Fatalf("AAAA packet yielded A: %q", got)
	}
	if got := ParseAAAARecord([]byte{1, 2, 3}, "abc-123.local"); got != "" {
		t.Fatalf("truncated packet parsed: %q", got)
	}
}

func TestQueryAsksBothFamilies(t *testing.T) {
	query := buildMDNSQuery(0, "abc-123.local")
	if got := binary.BigEndian.Uint16(query[4:6]); got != 2 {
		t.Fatalf("QDCOUNT = %d, want 2 (A and AAAA)", got)
	}
	// Both QTYPEs with the QU bit on the class.
	nameLen := len(encodeDNSName("abc-123.local"))
	first := 12 + nameLen
	if query[first+1] != 1 || query[first+2] != 0x80 {
		t.Fatalf("first question not A/QU: %v", query[first:first+4])
	}
	second := first + 4 + nameLen
	if query[second+1] != 28 || query[second+2] != 0x80 {
		t.Fatalf("second question not AAAA/QU: %v", query[second:second+4])
	}
}
