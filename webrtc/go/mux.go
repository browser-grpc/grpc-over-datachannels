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
//   - A Binding Success with an unknown ufrag (an srflx
//     gathering response: no username to route by) is offered
//     to every endpoint; each peer's srflx waiter consumes
//     only its own transaction id.
//
// Like every single-port mux, this assumes each remote
// connection presents a distinct source address — the normal
// Internet case. Two muxes peering with each other would
// present one shared source for several pairs, which DTLS
// cannot demux without connection IDs (RFC 9146, not
// implemented); run at most one mux per server<->client
// relationship. TURN is unavailable on muxed peers.

package dcwebrtc

import (
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
	m.mu.Lock()
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
			m.mu.Lock()
			ep := m.bySrc[src.String()]
			m.mu.Unlock()
			if ep != nil {
				ep.enqueue(msg, src)
				return
			}
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
			}
			return
		}
		return
	}
	m.mu.Lock()
	ep := m.bySrc[src.String()]
	m.mu.Unlock()
	if ep != nil {
		ep.enqueue(msg, src)
	}
}

func (m *PeerMux) unregister(ep *muxEndpoint) {
	m.mu.Lock()
	defer m.mu.Unlock()
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
