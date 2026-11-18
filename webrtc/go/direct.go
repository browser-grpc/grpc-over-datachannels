// libp2p-style WebRTC-Direct: signaling-free client->server
// connections over DTLS + SCTP datachannels.
//
// The listener owns a UDP socket and a self-signed certificate.
// Its identity is the certificate hash ("certhash": multibase
// base64url of the sha2-256 multihash of the cert DER), as in
// libp2p multiaddrs:
//
//	/ip4/203.0.113.7/udp/4001/webrtc-direct/certhash/f...
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

// directServerIO is the DTLS packet IO for one claimed peer
// of a DirectListener: sends go straight to the peer, receives
// come from the listener demux route for that peer.
type directServerIO struct {
	conn  *net.UDPConn
	peer  *net.UDPAddr
	inbox chan []byte
}

func (d *directServerIO) Send(buf []byte) error {
	_, err := d.conn.WriteToUDP(buf, d.peer)
	return err
}

func (d *directServerIO) Recv(timeoutMs int) []byte {
	select {
	case msg := <-d.inbox:
		return msg
	case <-time.After(time.Duration(timeoutMs) * time.Millisecond):
		return nil
	}
}

// DirectListener is a WebRTC-Direct listener: one UDP socket,
// one certificate, one Accept per connection.
type DirectListener struct {
	conn *net.UDPConn
	cert *Certificate

	// One socket, many peers: a single read goroutine routes
	// datagrams by sender to the endpoint that claimed that
	// peer; unclaimed peers queue until an Accept claims them.
	// Without this, concurrent dialers would steal each
	// other's handshake packets.
	mu           sync.Mutex
	claimMu      sync.Mutex
	routes       map[string]chan []byte
	pending      map[string][][]byte
	pendingPeers map[string]*net.UDPAddr
	pendingOrder []string
	pendingReady chan struct{}
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
	// Large SCTP bursts overflow default kernel buffers;
	// drops then cost an RTO round. Best-effort hint.
	_ = conn.SetReadBuffer(4 * 1024 * 1024)
	_ = conn.SetWriteBuffer(4 * 1024 * 1024)
	if cert == nil {
		cert, err = GenerateCertificate()
		if err != nil {
			_ = conn.Close()
			return nil, err
		}
	}
	l := &DirectListener{
		conn:         conn,
		cert:         cert,
		routes:       make(map[string]chan []byte),
		pending:      make(map[string][][]byte),
		pendingPeers: make(map[string]*net.UDPAddr),
		pendingReady: make(chan struct{}, 1),
	}
	go l.readLoop()
	return l, nil
}

// readLoop routes every inbound datagram by sender address.
func (l *DirectListener) readLoop() {
	buf := make([]byte, 65536)
	for {
		n, addr, err := l.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		if n == 0 {
			continue
		}
		msg := append([]byte(nil), buf[:n]...)
		key := addr.String()
		l.mu.Lock()
		if route, ok := l.routes[key]; ok {
			select {
			case route <- msg:
				l.mu.Unlock()
				continue
			default:
			}
		}
		if _, ok := l.pending[key]; !ok {
			l.pendingPeers[key] = addr
			l.pendingOrder = append(l.pendingOrder, key)
			select {
			case l.pendingReady <- struct{}{}:
			default:
			}
		}
		l.pending[key] = append(l.pending[key], msg)
		l.mu.Unlock()
	}
}

// claim registers the next unclaimed peer and returns its IO,
// seeded with datagrams that arrived before the claim.
// Serialized so two concurrent Accepts never claim one peer.
func (l *DirectListener) claim() *directServerIO {
	l.claimMu.Lock()
	defer l.claimMu.Unlock()
	for {
		l.mu.Lock()
		if len(l.pendingOrder) > 0 {
			key := l.pendingOrder[0]
			l.pendingOrder = l.pendingOrder[1:]
			queued := l.pending[key]
			peer := l.pendingPeers[key]
			delete(l.pending, key)
			delete(l.pendingPeers, key)
			inbox := make(chan []byte, 256)
			for _, msg := range queued {
				inbox <- msg
			}
			l.routes[key] = inbox
			l.mu.Unlock()
			return &directServerIO{conn: l.conn, peer: peer, inbox: inbox}
		}
		l.mu.Unlock()
		<-l.pendingReady
	}
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
	io := l.claim()
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
	_ = conn.SetReadBuffer(4 * 1024 * 1024)
	_ = conn.SetWriteBuffer(4 * 1024 * 1024)
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
	localIP := "127.0.0.1"
	if remote.IP.To4() == nil || isIPv6Text(turnCfg.Address) {
		// Dual-stack socket so the v6 TURN server is reachable.
		localIP = "::1"
	}
	peer, err := NewPeer(PeerOptions{LocalIPs: []string{localIP}})
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
	// turnAddPeer (not the bare For/Bind helpers): it remembers
	// remote in turn.peers, so the Peer's background refresher
	// keeps the permission and channel binding alive past the
	// allocation's first lifetime.
	peer.turnAddPeer(remote, timeout)
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
