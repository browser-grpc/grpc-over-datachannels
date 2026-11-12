// Minimal mDNS (RFC 6762) A/AAAA resolution: browsers hide host
// IPs behind "<uuid>.local" ICE candidates, and a native peer must
// resolve them to reach the browser. One multicast query to
// 224.0.0.251:5353, first matching answer wins. Mirrors mdns.js.
package dcwebrtc

import (
	"encoding/binary"
	"fmt"
	"net"
	"strings"
	"sync"
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
	binary.BigEndian.PutUint16(out[4:6], 2) // QDCOUNT: A and AAAA
	// IN|QU: the QU bit (RFC 6762 section 5.4) asks for a
	// unicast response to our ephemeral port; without it some
	// responders answer by multicast to :5353 only (we listen
	// there too; see ResolveMDNS).
	out = append(out, encodeDNSName(name)...)
	out = append(out, 0, 1, 0x80, 1) // A
	out = append(out, encodeDNSName(name)...)
	out = append(out, 0, 28, 0x80, 1) // AAAA
	return out
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

// parseRecord extracts the rdata of the first answer for name
// with the given type and length, or nil.
func parseRecord(packet []byte, name string, wantType uint16, wantLen int) []byte {
	if len(packet) < 12 {
		return nil
	}
	qd := int(binary.BigEndian.Uint16(packet[4:6]))
	an := int(binary.BigEndian.Uint16(packet[6:8]))
	pos := 12
	for i := 0; i < qd; i++ {
		_, next := readDNSName(packet, pos)
		if next <= pos {
			return nil
		}
		pos = next + 4
	}
	wanted := strings.ToLower(strings.TrimSuffix(name, "."))
	for i := 0; i < an; i++ {
		rname, next := readDNSName(packet, pos)
		if rname == "" {
			return nil
		}
		pos = next
		if pos+10 > len(packet) {
			return nil
		}
		rtype := binary.BigEndian.Uint16(packet[pos : pos+2])
		rdlen := int(binary.BigEndian.Uint16(packet[pos+8 : pos+10]))
		if pos+10+rdlen > len(packet) {
			return nil
		}
		rdata := packet[pos+10 : pos+10+rdlen]
		if rtype == wantType && rdlen == wantLen && strings.ToLower(rname) == wanted {
			return rdata
		}
		pos += 10 + rdlen
	}
	return nil
}

// ParseARecord extracts an A record for name from a DNS packet.
func ParseARecord(packet []byte, name string) string {
	rdata := parseRecord(packet, name, 1, 4)
	if rdata == nil {
		return ""
	}
	return fmt.Sprintf("%d.%d.%d.%d", rdata[0], rdata[1], rdata[2], rdata[3])
}

// ParseAAAARecord extracts an AAAA record for name from a DNS packet.
func ParseAAAARecord(packet []byte, name string) string {
	rdata := parseRecord(packet, name, 28, 16)
	if rdata == nil {
		return ""
	}
	return net.IP(rdata).String()
}

// One shared resolver for the whole process: concurrent
// resolutions (a signaling server accepting many browsers at
// once, each with its own ".local" candidate) share the query
// socket and the :5353 group sockets instead of binding a set
// per peer. Waiters demux by queried name; the shared sockets
// stay open for the life of the process.
type mdnsSharedResolver struct {
	query   *net.UDPConn
	group   *net.UDPAddr
	mu      sync.Mutex
	waiters map[string][]chan string
}

var sharedMDNS struct {
	sync.Mutex
	resolver *mdnsSharedResolver
}

func getSharedMDNS() *mdnsSharedResolver {
	sharedMDNS.Lock()
	defer sharedMDNS.Unlock()
	if sharedMDNS.resolver != nil {
		return sharedMDNS.resolver
	}
	query, err := net.ListenUDP("udp4", &net.UDPAddr{Port: 0})
	if err != nil {
		return nil
	}
	group := &net.UDPAddr{IP: net.ParseIP("224.0.0.251"), Port: 5353}
	resolver := &mdnsSharedResolver{
		query:   query,
		group:   group,
		waiters: make(map[string][]chan string),
	}
	sockets := []*net.UDPConn{query}
	if ifaces, err := net.Interfaces(); err == nil {
		for i := range ifaces {
			iface := &ifaces[i]
			if iface.Flags&net.FlagMulticast == 0 || iface.Flags&net.FlagUp == 0 {
				continue
			}
			if conn, err := net.ListenMulticastUDP("udp4", iface, group); err == nil {
				sockets = append(sockets, conn)
			}
		}
	}
	for _, conn := range sockets {
		go resolver.readLoop(conn)
	}
	sharedMDNS.resolver = resolver
	return resolver
}

func (r *mdnsSharedResolver) readLoop(conn *net.UDPConn) {
	buf := make([]byte, 4096)
	for {
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		packet := append([]byte(nil), buf[:n]...)
		r.mu.Lock()
		names := make([]string, 0, len(r.waiters))
		for name := range r.waiters {
			names = append(names, name)
		}
		r.mu.Unlock()
		for _, name := range names {
			ip := ParseARecord(packet, name)
			if ip == "" {
				ip = ParseAAAARecord(packet, name)
			}
			if ip == "" {
				continue
			}
			r.mu.Lock()
			waiters := r.waiters[name]
			delete(r.waiters, name)
			r.mu.Unlock()
			for _, ch := range waiters {
				select {
				case ch <- ip:
				default:
				}
			}
		}
	}
}

func (r *mdnsSharedResolver) sendQuery(name string) {
	_, _ = r.query.WriteToUDP(buildMDNSQuery(0, name), r.group)
}

// ResolveMDNS resolves a ".local" name to an IP string ("" on miss).
// Responders may answer unicast to the query socket (the query asks
// with the QU bit) or multicast to the group address — Chromium does
// the latter — so the shared resolver listens on both.
func ResolveMDNS(name string, timeout time.Duration) string {
	resolver := getSharedMDNS()
	if resolver == nil {
		return ""
	}
	found := make(chan string, 1)
	resolver.mu.Lock()
	resolver.waiters[name] = append(resolver.waiters[name], found)
	resolver.mu.Unlock()
	defer func() {
		resolver.mu.Lock()
		waiters := resolver.waiters[name]
		for i, ch := range waiters {
			if ch == found {
				resolver.waiters[name] = append(waiters[:i], waiters[i+1:]...)
				break
			}
		}
		if len(resolver.waiters[name]) == 0 {
			delete(resolver.waiters, name)
		}
		resolver.mu.Unlock()
	}()
	resolver.sendQuery(name)
	resend := time.After(timeout / 2)
	deadline := time.After(timeout)
	for {
		select {
		case ip := <-found:
			return ip
		case <-resend:
			resolver.sendQuery(name)
			resend = time.After(timeout)
		case <-deadline:
			return ""
		}
	}
}
