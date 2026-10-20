// libp2p-style WebRTC-Direct: signaling-free client->server
// connections over DTLS + SCTP datachannels.
//
// The listener owns a UDP socket and a self-signed certificate.
// Its identity is the certificate hash ("certhash": multibase
// base64url of the sha2-256 multihash of the cert DER), as in
// libp2p multiaddrs:
//   /ip4/203.0.113.7/udp/4001/webrtc-direct/certhash/f...
//
// The dialer needs only the address and certhash: it starts a
// DTLS handshake directly over UDP (no ICE, no SDP exchange --
// roles are fixed: dialer is DTLS client, listener is DTLS
// server), pinned to the certhash. DirectDialTurn is the
// symmetric-NAT path: all DTLS datagrams ride a TURN allocation,
// so the dialer never exchanges a direct packet with the
// listener.
package dcwebrtc

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// certhash (multibase base64url of multihash sha2-256 of cert DER)
// ---------------------------------------------------------------------------

// CerthashOfCert returns the certhash string for a certificate
// (multibase 'f' + base64url(0x12 0x20 || sha256(cert DER))).
func CerthashOfCert(cert *Certificate) string {
	digest := sha256.Sum256(cert.DER)
	mh := append([]byte{0x12, 0x20}, digest[:]...)
	return "f" + base64.RawURLEncoding.EncodeToString(mh)
}

// ParseCerthash parses a certhash into the 32-byte sha256 digest
// it pins.
func ParseCerthash(s string) ([]byte, error) {
	if !strings.HasPrefix(s, "f") {
		return nil, errors.New("bad certhash")
	}
	mh, err := base64.RawURLEncoding.DecodeString(s[1:])
	if err != nil || len(mh) != 34 || mh[0] != 0x12 || mh[1] != 0x20 {
		return nil, errors.New("bad certhash")
	}
	return mh[2:], nil
}

// FingerprintOfDigest formats a sha256 digest as an SDP-style
// colon-hex fingerprint (what DtlsConfig expects).
func FingerprintOfDigest(digest []byte) string {
	parts := make([]string, len(digest))
	for i, b := range digest {
		parts[i] = fmt.Sprintf("%02X", b)
	}
	return strings.Join(parts, ":")
}

func certhashOfDigest(digest []byte) string {
	mh := append([]byte{0x12, 0x20}, digest...)
	return "f" + base64.RawURLEncoding.EncodeToString(mh)
}

// ---------------------------------------------------------------------------
// multiaddr (the /webrtc-direct subset)
// ---------------------------------------------------------------------------

// ParseDirectMultiaddr parses
// /ip4/<a>/udp/<port>/webrtc-direct/certhash/<hash> (or ip6)
// into the socket address and pinned digest.
func ParseDirectMultiaddr(s string) (*net.UDPAddr, []byte, error) {
	parts := strings.FieldsFunc(s, func(r rune) bool { return r == '/' })
	if len(parts) != 7 || parts[2] != "udp" || parts[4] != "webrtc-direct" || parts[5] != "certhash" {
		return nil, nil, errors.New("bad direct multiaddr")
	}
	if parts[0] != "ip4" && parts[0] != "ip6" {
		return nil, nil, errors.New("bad direct multiaddr")
	}
	port, err := strconv.Atoi(parts[3])
	if err != nil || port < 0 || port > 65535 {
		return nil, nil, errors.New("bad direct multiaddr")
	}
	ip := net.ParseIP(parts[1])
	if ip == nil {
		return nil, nil, errors.New("bad direct multiaddr")
	}
	digest, err := ParseCerthash(parts[6])
	if err != nil {
		return nil, nil, err
	}
	return &net.UDPAddr{IP: ip, Port: port}, digest, nil
}

// DirectMultiaddr builds the direct multiaddr for an address +
// certhash.
func DirectMultiaddr(addr *net.UDPAddr, certhash string) string {
	family := "ip4"
	if addr.IP.To4() == nil {
		family = "ip6"
	}
	return fmt.Sprintf("/%s/%s/udp/%d/webrtc-direct/certhash/%s", family, addr.IP.String(), addr.Port, certhash)
}

// ---------------------------------------------------------------------------
// listener + dialer
// ---------------------------------------------------------------------------

// directServerIO learns its peer from the first packet (the
// listener accepts whoever handshakes first, like libp2p).
type directServerIO struct {
	conn *net.UDPConn
	mu   sync.Mutex
	peer *net.UDPAddr
}

func (d *directServerIO) Send(buf []byte) error {
	d.mu.Lock()
	peer := d.peer
	d.mu.Unlock()
	if peer == nil {
		return errors.New("direct: peer not learned yet")
	}
	_, err := d.conn.WriteToUDP(buf, peer)
	return err
}

func (d *directServerIO) Recv(timeoutMs int) []byte {
	_ = d.conn.SetReadDeadline(time.Now().Add(time.Duration(timeoutMs) * time.Millisecond))
	buf := make([]byte, 65536)
	n, addr, err := d.conn.ReadFromUDP(buf)
	if err != nil {
		return nil
	}
	d.mu.Lock()
	d.peer = addr
	d.mu.Unlock()
	return buf[:n]
}

// DirectListener is a WebRTC-Direct listener: one UDP socket,
// one certificate, one Accept per connection.
type DirectListener struct {
	conn *net.UDPConn
	cert *Certificate
}

// NewDirectListener binds a Direct listener at addr ("host:port";
// port 0 picks a free port).
func NewDirectListener(addr string, cert *Certificate) (*DirectListener, error) {
	udpAddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		return nil, err
	}
	if cert == nil {
		cert, err = GenerateCertificate()
		if err != nil {
			_ = conn.Close()
			return nil, err
		}
	}
	return &DirectListener{conn: conn, cert: cert}, nil
}

// Addr returns the bound local address.
func (l *DirectListener) Addr() *net.UDPAddr {
	return l.conn.LocalAddr().(*net.UDPAddr)
}

// Certhash returns this listener's certhash (its libp2p pin).
func (l *DirectListener) Certhash() string { return CerthashOfCert(l.cert) }

// Multiaddr returns the multiaddr dialers use to reach this
// listener.
func (l *DirectListener) Multiaddr() string { return DirectMultiaddr(l.Addr(), l.Certhash()) }

// Accept accepts one direct connection (blocking DTLS accept)
// and returns its datachannel endpoint.
func (l *DirectListener) Accept() (*DcEndpoint, error) {
	io := &directServerIO{conn: l.conn}
	dtls, err := DtlsAccept(io, DtlsConfig{Certificate: l.cert})
	if err != nil {
		return nil, err
	}
	return NewDcEndpoint(dtls, "server"), nil
}

// Close closes the listener socket.
func (l *DirectListener) Close() error { return l.conn.Close() }

func directClientConfig(cert *Certificate, digest []byte) DtlsConfig {
	return DtlsConfig{
		Certificate:             cert,
		ExpectedPeerFingerprint: FingerprintOfDigest(digest),
		RequirePeerCertificate:  true,
	}
}

func orGenerate(cert *Certificate) (*Certificate, error) {
	if cert != nil {
		return cert, nil
	}
	return GenerateCertificate()
}

// DirectDial dials a Direct listener at remote, pinning its
// certificate to certhash.
func DirectDial(remote *net.UDPAddr, certhash string, cert *Certificate) (*DcEndpoint, error) {
	digest, err := ParseCerthash(certhash)
	if err != nil {
		return nil, err
	}
	cert, err = orGenerate(cert)
	if err != nil {
		return nil, err
	}
	conn, err := net.DialUDP("udp", nil, remote)
	if err != nil {
		return nil, err
	}
	dtls, err := DtlsConnect(UDPPacketIO(conn), directClientConfig(cert, digest))
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	return NewDcEndpoint(dtls, "client"), nil
}

// DirectDialMultiaddr dials by multiaddr:
// /ip4/.../udp/.../webrtc-direct/certhash/f...
func DirectDialMultiaddr(multiaddr string, cert *Certificate) (*DcEndpoint, error) {
	remote, digest, err := ParseDirectMultiaddr(multiaddr)
	if err != nil {
		return nil, err
	}
	return DirectDial(remote, certhashOfDigest(digest), cert)
}

// peerPacketIO carries DTLS over a Peer's socket: sends are
// wrapped by the TURN allocation when relayActive, receives come
// from the peer's DTLS queue (its read loop already unwrapped
// relayed traffic and consumed TURN control).
type peerPacketIO struct {
	peer   *Peer
	remote *net.UDPAddr
}

func (p *peerPacketIO) Send(buf []byte) error {
	p.peer.sendTo(buf, p.remote)
	return nil
}

func (p *peerPacketIO) Recv(timeoutMs int) []byte {
	select {
	case msg := <-p.peer.dtlsQueue:
		return msg
	case <-time.After(time.Duration(timeoutMs) * time.Millisecond):
		return nil
	}
}

// DirectDialTurn dials a Direct listener through a TURN
// allocation -- the path for a dialer behind a symmetric NAT
// (or any NAT where direct UDP to the listener fails). The
// allocation, permission, and channel binding for remote are
// set up before the DTLS handshake; the Peer's background
// refresher keeps them alive.
func DirectDialTurn(remote *net.UDPAddr, certhash string, cert *Certificate, turnCfg TurnServerConfig) (*DcEndpoint, error) {
	digest, err := ParseCerthash(certhash)
	if err != nil {
		return nil, err
	}
	cert, err = orGenerate(cert)
	if err != nil {
		return nil, err
	}
	peer, err := NewPeer(PeerOptions{LocalIPs: []string{"127.0.0.1"}})
	if err != nil {
		return nil, err
	}
	timeout := 5 * time.Second
	if err := peer.AllocateTurn(turnCfg, timeout); err != nil {
		peer.Close()
		return nil, err
	}
	if peer.turn == nil || peer.turn.relayed == nil {
		peer.Close()
		return nil, errors.New("turn: no relayed address")
	}
	peer.turnCreatePermissionsFor([]*net.UDPAddr{remote}, timeout)
	peer.turnBindChannels([]*net.UDPAddr{remote}, timeout)
	peer.relayActive = true
	dtls, err := DtlsConnect(&peerPacketIO{peer: peer, remote: remote}, directClientConfig(cert, digest))
	if err != nil {
		peer.Close()
		return nil, err
	}
	return NewDcEndpoint(dtls, "client"), nil
}

// DirectDialTurnMultiaddr dials by multiaddr through a TURN
// allocation (see DirectDialTurn).
func DirectDialTurnMultiaddr(multiaddr string, cert *Certificate, turnCfg TurnServerConfig) (*DcEndpoint, error) {
	remote, digest, err := ParseDirectMultiaddr(multiaddr)
	if err != nil {
		return nil, err
	}
	return DirectDialTurn(remote, certhashOfDigest(digest), cert, turnCfg)
}
