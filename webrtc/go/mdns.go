// Minimal mDNS (RFC 6762) A-record resolution: browsers hide host
// IPs behind "<uuid>.local" ICE candidates, and a native peer must
// resolve them to reach the browser. One multicast query to
// 224.0.0.251:5353, first matching answer wins. Mirrors mdns.js.
package dcwebrtc

import (
	"encoding/binary"
	"fmt"
	"net"
	"strings"
	"time"
)

func encodeDNSName(name string) []byte {
	var out []byte
	for _, label := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		out = append(out, byte(len(label)))
		out = append(out, label...)
	}
	return append(out, 0)
}

func buildMDNSQuery(id uint16, name string) []byte {
	out := make([]byte, 12)
	binary.BigEndian.PutUint16(out[0:2], id)
	binary.BigEndian.PutUint16(out[4:6], 1) // QDCOUNT
	out = append(out, encodeDNSName(name)...)
	return append(out, 0, 1, 0, 1) // A, IN
}

func readDNSName(buf []byte, offset int) (string, int) {
	var labels []string
	pos, jumpedTo := offset, -1
	for guard := 0; guard < 32; guard++ {
		if pos >= len(buf) {
			return "", pos
		}
		length := int(buf[pos])
		if length == 0 {
			next := jumpedTo
			if next < 0 {
				next = pos + 1
			}
			return strings.Join(labels, "."), next
		}
		if length&0xc0 == 0xc0 {
			if pos+1 >= len(buf) {
				return "", pos
			}
			target := (length&0x3f)<<8 | int(buf[pos+1])
			if jumpedTo < 0 {
				jumpedTo = pos + 2
			}
			pos = target
			continue
		}
		if pos+1+length > len(buf) {
			return "", pos
		}
		labels = append(labels, string(buf[pos+1:pos+1+length]))
		pos += 1 + length
	}
	return "", pos
}

// ParseARecord extracts an A record for name from a DNS packet.
func ParseARecord(packet []byte, name string) string {
	if len(packet) < 12 {
		return ""
	}
	qd := int(binary.BigEndian.Uint16(packet[4:6]))
	an := int(binary.BigEndian.Uint16(packet[6:8]))
	pos := 12
	for i := 0; i < qd; i++ {
		_, next := readDNSName(packet, pos)
		if next <= pos {
			return ""
		}
		pos = next + 4
	}
	wanted := strings.ToLower(strings.TrimSuffix(name, "."))
	for i := 0; i < an; i++ {
		rname, next := readDNSName(packet, pos)
		if rname == "" {
			return ""
		}
		pos = next
		if pos+10 > len(packet) {
			return ""
		}
		rtype := binary.BigEndian.Uint16(packet[pos : pos+2])
		rdlen := int(binary.BigEndian.Uint16(packet[pos+8 : pos+10]))
		if pos+10+rdlen > len(packet) {
			return ""
		}
		rdata := packet[pos+10 : pos+10+rdlen]
		if rtype == 1 && rdlen == 4 && strings.ToLower(rname) == wanted {
			return fmt.Sprintf("%d.%d.%d.%d", rdata[0], rdata[1], rdata[2], rdata[3])
		}
		pos += 10 + rdlen
	}
	return ""
}

// ResolveMDNS resolves a ".local" name to an IPv4 string ("" on miss).
func ResolveMDNS(name string, timeout time.Duration) string {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: 0})
	if err != nil {
		return ""
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))
	query := buildMDNSQuery(0x4d44, name)
	target := &net.UDPAddr{IP: net.ParseIP("224.0.0.251"), Port: 5353}
	if _, err := conn.WriteToUDP(query, target); err != nil {
		return ""
	}
	buf := make([]byte, 4096)
	resent := false
	for {
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			if !resent {
				resent = true
				_ = conn.SetDeadline(time.Now().Add(timeout / 2))
				_, _ = conn.WriteToUDP(query, target)
				continue
			}
			return ""
		}
		if ip := ParseARecord(buf[:n], name); ip != "" {
			return ip
		}
	}
}
