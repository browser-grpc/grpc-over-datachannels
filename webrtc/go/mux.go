// Shared-socket multiplexing for signaled peers: many Peers
// over one bound UDP socket — the single-port server topology
// (Jitsi's 10000/udp, Pion's UDPMux). One reader goroutine
// owns the real socket and routes each datagram to one peer
// endpoint:
//
//   - STUN packets route by the ICE username's local ufrag
//     (registered when the peer is created).
//   - Everything else (DTLS) routes by source address, learned
//     from that peer's STUN traffic. A NAT rebinding can drop
//     a datagram until the pair's next consent check
//     re-teaches the route; DTLS/SCTP retransmission covers
//     the gap.
//   - A Binding Success carries no username, so it is offered
//     to every endpoint; each peer consumes only its own
//     (integrity-checked) transaction — the srflx waiter during
//     gathering, the ICE agent otherwise. Offering to all is
//     what makes a shared source (mux-to-mux) route
//     deterministically instead of by last-learned source.
//
// DTLS records route by connection id (RFC 9146) once the
// handshake's first flight (routed by its DcPairHint) lands,
// so two muxes can peer with each other over one shared
// source address. TURN traffic never touches the shared
// socket: a muxed peer's allocation rides a dedicated
// per-peer socket (see AllocateTurn).

package dcwebrtc

import (
	"encoding/binary"
	"errors"
	"net"
	"strings"
	"sync"
	"time"
)

// PeerMux is one shared UDP socket hosting many signaled peers.
type PeerMux struct {
	socket *net.UDPConn
	addr   *net.UDPAddr

	mu      sync.Mutex
	byUfrag map[string]*muxEndpoint
	bySrc   map[string]*muxEndpoint
	byCid   map[string]*muxEndpoint
	cidSeq  uint64
	done    chan struct{}
	once    sync.Once
}

type muxPacket struct {
	data []byte
	src  *net.UDPAddr
}

// muxEndpoint is one peer's view of the shared socket: sends
// go straight to the real socket; receives drain the inbox
// the mux reader fills.
type muxEndpoint struct {
	mux      *PeerMux
	inbox    chan muxPacket
	done     chan struct{}
	once     sync.Once
	deadline atomicTime
	ufrag    string
	cid      []byte
}

type atomicTime struct {
	mu  sync.Mutex
	t   time.Time
	set bool
}

func (a *atomicTime) store(t time.Time) {
	a.mu.Lock()
	a.t, a.set = t, true
	a.mu.Unlock()
}

func (a *atomicTime) load() (time.Time, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.t, a.set
}

// NewPeerMux binds the shared socket and starts its reader.
func NewPeerMux(addr *net.UDPAddr) (*PeerMux, error) {
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return nil, err
	}
	mux := &PeerMux{
		socket:  conn,
		addr:    conn.LocalAddr().(*net.UDPAddr),
		byUfrag: make(map[string]*muxEndpoint),
		bySrc:   make(map[string]*muxEndpoint),
		byCid:   make(map[string]*muxEndpoint),
		done:    make(chan struct{}),
	}
	go mux.readLoop()
	return mux, nil
}

// LocalAddr is the shared socket's bound address; every peer
// created here advertises this port in its host candidates.
func (m *PeerMux) LocalAddr() *net.UDPAddr { return m.addr }

// Close stops the reader and closes the shared socket.
func (m *PeerMux) Close() error {
	var err error
	m.once.Do(func() {
		close(m.done)
		err = m.socket.Close()
	})
	return err
}

// NewPeer creates a peer on the shared socket.
func (m *PeerMux) NewPeer(options PeerOptions) (*Peer, error) {
	endpoint := &muxEndpoint{
		mux:   m,
		inbox: make(chan muxPacket, 256),
		done:  make(chan struct{}),
	}
	ips := options.LocalIPs
	if ips == nil {
		ips = defaultLocalIPs()
	}
	peer, err := newPeer(options, endpoint, ips)
	if err != nil {
		return nil, err
	}
	// Allocate this endpoint's DTLS connection id (RFC 9146):
	// the shared port's bytes plus a counter — unique per
	// endpoint, fixed length so routing is an exact lookup.
	m.mu.Lock()
	m.cidSeq++
	cid := make([]byte, 10)
	binary.BigEndian.PutUint16(cid[0:2], uint16(m.addr.Port))
	binary.BigEndian.PutUint64(cid[2:10], m.cidSeq)
	endpoint.cid = cid
	m.byCid[string(cid)] = endpoint
	m.byUfrag[peer.agent.LocalUfrag] = endpoint
	m.mu.Unlock()
	endpoint.ufrag = peer.agent.LocalUfrag
	return peer, nil
}

func (m *PeerMux) readLoop() {
	buf := make([]byte, 65536)
	for {
		select {
		case <-m.done:
			return
		default:
		}
		_ = m.socket.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		n, src, err := m.socket.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-m.done:
				return
			default:
				continue
			}
		}
		if n == 0 {
			continue
		}
		msg := make([]byte, n)
		copy(msg, buf[:n])
		m.deliver(msg, src)
	}
}

func (m *PeerMux) deliver(msg []byte, src *net.UDPAddr) {
	if len(msg) > 0 && msg[0] < 4 {
		// STUN: route by username ufrag, else by learned
		// source, else (Binding Success only) offer to all
		// endpoints for srflx resolution.
		if stun := DecodeStun(msg); stun != nil {
			if username := stun.attr(StunAttrUsername); username != nil {
				local := strings.SplitN(string(username), ":", 2)[0]
				m.mu.Lock()
				ep := m.byUfrag[local]
				if ep != nil {
					m.bySrc[src.String()] = ep
				}
				m.mu.Unlock()
				if ep != nil {
					ep.enqueue(msg, src)
					return
				}
			}
			// A Binding Success carries no username. Offer it
			// to every endpoint: each agent consumes only its
			// own (integrity-checked) transaction, and a
			// shared source (mux-to-mux) makes the learned
			// source ambiguous.
			if stun.Type == StunTypeBindingSuccess {
				m.mu.Lock()
				endpoints := make([]*muxEndpoint, 0, len(m.byUfrag))
				for _, ep := range m.byUfrag {
					endpoints = append(endpoints, ep)
				}
				m.mu.Unlock()
				for _, ep := range endpoints {
					ep.enqueue(msg, src)
				}
				return
			}
			m.mu.Lock()
			ep := m.bySrc[src.String()]
			m.mu.Unlock()
			if ep != nil {
				ep.enqueue(msg, src)
				return
			}
			return
		}
		return
	}
	// DTLS: an epoch-0 ClientHello routes by its DcPairHint;
	// everything else routes by connection id (source-
	// independent, so mux-to-mux and NAT rebinding keep
	// working); the learned source is the fallback.
	if ep := m.endpointByHint(msg); ep != nil {
		ep.enqueue(msg, src)
		return
	}
	if ep := m.endpointByCid(msg); ep != nil {
		ep.enqueue(msg, src)
		return
	}
	m.mu.Lock()
	ep := m.bySrc[src.String()]
	m.mu.Unlock()
	if ep != nil {
		ep.enqueue(msg, src)
	}
}

// endpointByHint routes a first-flight ClientHello by its
// DcPairHint extension (the remote peer's ICE ufrag, which
// the byUfrag table already keys).
func (m *PeerMux) endpointByHint(msg []byte) *muxEndpoint {
	hint, ok := pairHintFromClientHello(msg)
	if !ok {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.byUfrag[hint]
}

// endpointByCid routes a DTLS record by the connection id
// after its header (offset 11: type, version, epoch, seq).
func (m *PeerMux) endpointByCid(msg []byte) *muxEndpoint {
	if len(msg) < 21 {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.byCid[string(msg[11:21])]
}

// pairHintFromClientHello extracts the DcPairHint extension
// from an epoch-0 ClientHello record (unfragmented, as our
// stacks emit it).
func pairHintFromClientHello(msg []byte) (string, bool) {
	r := &byteReader{buf: msg}
	ct, err := r.u8()
	if err != nil || ct != DtlsContentHandshake {
		return "", false
	}
	for i := 0; i < 4; i++ { // version(2) + epoch(2)
		if _, err := r.u8(); err != nil {
			return "", false
		}
	}
	if _, err := r.take(6); err != nil { // sequence
		return "", false
	}
	if _, err := r.u16(); err != nil { // length
		return "", false
	}
	mt, err := r.u8()
	if err != nil || mt != DtlsHandshakeClientHello {
		return "", false
	}
	if _, err := r.u24(); err != nil { // handshake length
		return "", false
	}
	if _, err := r.take(2); err != nil { // message sequence
		return "", false
	}
	if _, err := r.take(3); err != nil { // fragment offset
		return "", false
	}
	if _, err := r.u24(); err != nil { // fragment length
		return "", false
	}
	if _, err := r.take(34); err != nil { // version + random
		return "", false
	}
	if _, err := r.vec8(); err != nil { // session id
		return "", false
	}
	if _, err := r.vec8(); err != nil { // cookie
		return "", false
	}
	if _, err := r.vec16(); err != nil { // cipher suites
		return "", false
	}
	if _, err := r.vec8(); err != nil { // compression
		return "", false
	}
	exts, err := r.vec16()
	if err != nil {
		return "", false
	}
	er := &byteReader{buf: exts}
	for !er.done() {
		ty, err := er.u16()
		if err != nil {
			return "", false
		}
		data, err := er.vec16()
		if err != nil {
			return "", false
		}
		if ty == DtlsExtDcPairHint {
			return string(data), true
		}
	}
	return "", false
}

func (m *PeerMux) unregister(ep *muxEndpoint) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if ep.cid != nil && m.byCid[string(ep.cid)] == ep {
		delete(m.byCid, string(ep.cid))
	}
	if ep.ufrag != "" {
		if m.byUfrag[ep.ufrag] == ep {
			delete(m.byUfrag, ep.ufrag)
		}
	}
	for src, other := range m.bySrc {
		if other == ep {
			delete(m.bySrc, src)
		}
	}
}

// --- muxEndpoint: packetConn for one peer ---

func (e *muxEndpoint) enqueue(data []byte, src *net.UDPAddr) {
	select {
	case e.inbox <- muxPacket{data: data, src: src}:
	default:
		// A stalled peer must not wedge the shared reader.
	}
}

func (e *muxEndpoint) ReadFromUDP(b []byte) (int, *net.UDPAddr, error) {
	for {
		var timer *time.Timer
		var timeout <-chan time.Time
		if deadline, ok := e.deadline.load(); ok {
			d := time.Until(deadline)
			if d <= 0 {
				return 0, nil, &net.OpError{Op: "read", Net: "udp", Err: errTimeout{}}
			}
			timer = time.NewTimer(d)
			timeout = timer.C
		}
		select {
		case pkt := <-e.inbox:
			if timer != nil {
				timer.Stop()
			}
			// Oversized datagrams truncate, like a real socket.
			return copy(b, pkt.data), pkt.src, nil
		case <-timeout:
			return 0, nil, &net.OpError{Op: "read", Net: "udp", Err: errTimeout{}}
		case <-e.done:
			return 0, nil, errors.New("mux endpoint closed")
		case <-e.mux.done:
			return 0, nil, errors.New("mux closed")
		}
	}
}

type errTimeout struct{}

func (errTimeout) Error() string   { return "i/o timeout" }
func (errTimeout) Timeout() bool   { return true }
func (errTimeout) Temporary() bool { return true }

func (e *muxEndpoint) WriteToUDP(b []byte, addr *net.UDPAddr) (int, error) {
	return e.mux.socket.WriteToUDP(b, addr)
}

func (e *muxEndpoint) LocalAddr() net.Addr { return e.mux.addr }

// LocalCID is this endpoint's allocated DTLS connection id
// (RFC 9146); the peer announces it so records it receives
// carry it and route here without a learned source.
func (e *muxEndpoint) LocalCID() []byte { return e.cid }

func (e *muxEndpoint) SetReadDeadline(t time.Time) error {
	e.deadline.store(t)
	return nil
}

func (e *muxEndpoint) Close() error {
	e.once.Do(func() {
		close(e.done)
		e.mux.unregister(e)
	})
	return nil
}
