// Rendezvous listener: a fixed, pre-published WebRTC endpoint
// browsers can connect to with no signaling exchange at all.
//
// The listener owns one UDP socket, one fixed ICE ufrag/pwd
// pair, and one fixed DTLS certificate. Those four values plus
// the public host/port form a rendezvous descriptor, published
// beforehand (hardcoded, DNS, an HTTPS file — host's choice).
// A browser synthesizes this endpoint's SDP locally from the
// descriptor (see the generated rendezvousChannel), answers it
// in-page, and starts ICE as the controlling agent (the
// descriptor says ICE-lite). Nothing is ever transmitted out
// of band after publication.
//
// Server side of each dial: the first STUN Binding request
// carries the dialer's ufrag in its USERNAME. The listener
// spawns a Peer for it with the fixed credentials/certificate,
// synthesizes the dialer's offer from the packet's source
// address (its ICE pwd and DTLS fingerprint are unknown; the
// peer requires neither), and feeds the packet in. The dialer
// nominates (USE-CANDIDATE), DTLS runs with this side as
// server presenting the fixed cert, and the "grpc" channel is
// delivered to OnChannel like any other peer's.

package dcwebrtc

import (
	"errors"
	"net"
	"strings"
	"sync"
	"time"
)

// RendezvousDescriptor is the publishable description of a
// RendezvousListener: the same shape the generated browser
// rendezvousChannel consumes.
type RendezvousDescriptor struct {
	Host        string `json:"host"`
	Port        int    `json:"port"`
	IceUfrag    string `json:"iceUfrag"`
	IcePwd      string `json:"icePwd"`
	Fingerprint string `json:"fingerprint"`
	Setup       string `json:"setup"`
}

// RendezvousOptions configures ListenRendezvous. Fix IceUfrag,
// IcePwd, and Certificate and the published descriptor stays
// stable across restarts; ephemeral values rotate per process.
type RendezvousOptions struct {
	LocalIPs    []string
	IceUfrag    string
	IcePwd      string
	Certificate *Certificate
	// ConsentInterval/ConsentExpiry configure RFC 7675
	// consent freshness on each session peer (0 = defaults:
	// 5 s / 30 s; negative interval disables).
	ConsentInterval time.Duration
	ConsentExpiry   time.Duration
	// OnChannel receives each session's inbound DataChannel
	// (with its Peer, e.g. to close it when the channel ends).
	OnChannel func(channel *DataChannel, peer *Peer)
	// OnError, when set, receives background connect failures.
	OnError func(error)
}

type rendezvousSession struct {
	remoteUfrag string
	peer        *Peer
	endpoint    *rendezvousEndpoint
}

// RendezvousListener is one fixed rendezvous endpoint: a
// single UDP socket demuxing sessions by dialer ufrag.
type RendezvousListener struct {
	socket *net.UDPConn
	addr   *net.UDPAddr

	options     RendezvousOptions
	iceUfrag    string
	icePwd      string
	certificate *Certificate

	mu         sync.Mutex
	byRemote   map[string]*rendezvousSession
	bySrc      map[string]*rendezvousSession
	done       chan struct{}
	closeOnce  sync.Once
}

// ListenRendezvous binds the listener socket and starts
// accepting rendezvous dials.
func ListenRendezvous(addr *net.UDPAddr, options RendezvousOptions) (*RendezvousListener, error) {
	if addr == nil {
		addr = &net.UDPAddr{IP: net.IPv4zero, Port: 0}
	}
	socket, err := net.ListenUDP("udp", addr)
	if err != nil {
		return nil, err
	}
	cert := options.Certificate
	if cert == nil {
		cert, err = GenerateCertificate()
		if err != nil {
			socket.Close()
			return nil, err
		}
	}
	ufrag := options.IceUfrag
	if ufrag == "" {
		ufrag = randomUfrag()
	}
	pwd := options.IcePwd
	if pwd == "" {
		pwd = randomPassword()
	}
	listener := &RendezvousListener{
		socket:      socket,
		addr:        socket.LocalAddr().(*net.UDPAddr),
		options:     options,
		iceUfrag:    ufrag,
		icePwd:      pwd,
		certificate: cert,
		byRemote:    make(map[string]*rendezvousSession),
		bySrc:       make(map[string]*rendezvousSession),
		done:        make(chan struct{}),
	}
	go listener.readLoop()
	return listener, nil
}

// LocalAddr is the listener socket's bound address.
func (l *RendezvousListener) LocalAddr() *net.UDPAddr { return l.addr }

// Descriptor returns the publishable descriptor for host (the
// public IP browsers should dial).
func (l *RendezvousListener) Descriptor(host string) RendezvousDescriptor {
	return RendezvousDescriptor{
		Host:        host,
		Port:        l.addr.Port,
		IceUfrag:    l.iceUfrag,
		IcePwd:      l.icePwd,
		Fingerprint: l.certificate.Fingerprint(),
		Setup:       "passive",
	}
}

// Close stops the listener and every live session peer.
func (l *RendezvousListener) Close() error {
	var err error
	l.closeOnce.Do(func() {
		close(l.done)
		l.mu.Lock()
		sessions := make([]*rendezvousSession, 0, len(l.byRemote))
		for _, session := range l.byRemote {
			sessions = append(sessions, session)
		}
		l.byRemote = make(map[string]*rendezvousSession)
		l.bySrc = make(map[string]*rendezvousSession)
		l.mu.Unlock()
		for _, session := range sessions {
			if session.peer != nil {
				session.peer.Close()
			}
		}
		err = l.socket.Close()
	})
	return err
}

func (l *RendezvousListener) dropSession(session *rendezvousSession) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.byRemote[session.remoteUfrag] == session {
		delete(l.byRemote, session.remoteUfrag)
	}
	for src, other := range l.bySrc {
		if other == session {
			delete(l.bySrc, src)
		}
	}
}

func (l *RendezvousListener) readLoop() {
	buf := make([]byte, 65536)
	for {
		select {
		case <-l.done:
			return
		default:
		}
		_ = l.socket.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		n, src, err := l.socket.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-l.done:
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
		l.route(msg, src)
	}
}

func synthesizedRendezvousOffer(src *net.UDPAddr, remoteUfrag string) string {
	desc := SessionDescription{
		Ufrag:       remoteUfrag,
		Pwd:         "rendezvousUnknownPwd0000",
		Fingerprint: "00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00",
		Setup:       "actpass",
		Candidates:  []Candidate{HostCandidate(src.IP.String(), src.Port, "1")},
	}
	return desc.Generate("offer")
}

func (l *RendezvousListener) spawnSession(src *net.UDPAddr, remoteUfrag string, first []byte) *rendezvousSession {
	session := &rendezvousSession{remoteUfrag: remoteUfrag}
	endpoint := &rendezvousEndpoint{
		listener: l,
		session:  session,
		inbox:    make(chan muxPacket, 256),
		done:     make(chan struct{}),
	}
	session.endpoint = endpoint
	ips := l.options.LocalIPs
	if ips == nil {
		ips = defaultLocalIPs()
	}
	peer, err := newPeer(PeerOptions{
		LocalIPs:        l.options.LocalIPs,
		IceUfrag:        l.iceUfrag,
		IcePwd:          l.icePwd,
		Certificate:     l.certificate,
		ConsentInterval: l.options.ConsentInterval,
		ConsentExpiry:   l.options.ConsentExpiry,
	}, endpoint, ips)
	if err != nil {
		l.reportError(err)
		return session
	}
	session.peer = peer
	l.mu.Lock()
	l.byRemote[remoteUfrag] = session
	l.bySrc[src.String()] = session
	l.mu.Unlock()
	if _, err := peer.HandleRendezvousOffer(synthesizedRendezvousOffer(src, remoteUfrag)); err != nil {
		l.dropSession(session)
		l.reportError(err)
		return session
	}
	endpoint.enqueue(first, src)
	go func() {
		dcEndpoint, err := peer.ConnectWithOptions(false)
		if err != nil {
			l.dropSession(session)
			l.reportError(err)
			return
		}
		dcEndpoint.SetOnChannel(func(channel *DataChannel) {
			if l.options.OnChannel != nil {
				l.options.OnChannel(channel, peer)
			}
		})
	}()
	return session
}

func (l *RendezvousListener) reportError(err error) {
	if l.options.OnError != nil {
		l.options.OnError(err)
	}
}

func (l *RendezvousListener) route(msg []byte, src *net.UDPAddr) {
	if len(msg) > 0 && msg[0] < 4 {
		if stun := DecodeStun(msg); stun != nil {
			if username := stun.attr(StunAttrUsername); username != nil {
				parts := strings.SplitN(string(username), ":", 2)
				if len(parts) == 2 && parts[0] == l.iceUfrag && parts[1] != "" {
					remote := parts[1]
					l.mu.Lock()
					session := l.byRemote[remote]
					if session != nil {
						l.bySrc[src.String()] = session
					}
					l.mu.Unlock()
					if session == nil {
						session = l.spawnSession(src, remote, msg)
						return
					}
					if session.endpoint != nil {
						session.endpoint.enqueue(msg, src)
					}
					return
				}
				return
			}
		}
		l.mu.Lock()
		session := l.bySrc[src.String()]
		l.mu.Unlock()
		if session != nil && session.endpoint != nil {
			session.endpoint.enqueue(msg, src)
		}
		return
	}
	l.mu.Lock()
	session := l.bySrc[src.String()]
	l.mu.Unlock()
	if session != nil && session.endpoint != nil {
		session.endpoint.enqueue(msg, src)
	}
}

// --- rendezvousEndpoint: packetConn for one session ---

type rendezvousEndpoint struct {
	listener *RendezvousListener
	session  *rendezvousSession
	inbox    chan muxPacket
	done     chan struct{}
	once     sync.Once
	deadline atomicTime
}

func (e *rendezvousEndpoint) enqueue(data []byte, src *net.UDPAddr) {
	select {
	case e.inbox <- muxPacket{data: data, src: src}:
	default:
		// A stalled session must not wedge the shared reader.
	}
}

func (e *rendezvousEndpoint) ReadFromUDP(b []byte) (int, *net.UDPAddr, error) {
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
			return copy(b, pkt.data), pkt.src, nil
		case <-timeout:
			return 0, nil, &net.OpError{Op: "read", Net: "udp", Err: errTimeout{}}
		case <-e.done:
			return 0, nil, errors.New("rendezvous endpoint closed")
		case <-e.listener.done:
			return 0, nil, errors.New("rendezvous listener closed")
		}
	}
}

func (e *rendezvousEndpoint) WriteToUDP(b []byte, addr *net.UDPAddr) (int, error) {
	return e.listener.socket.WriteToUDP(b, addr)
}

func (e *rendezvousEndpoint) LocalAddr() net.Addr { return e.listener.addr }

func (e *rendezvousEndpoint) SetReadDeadline(t time.Time) error {
	e.deadline.store(t)
	return nil
}

func (e *rendezvousEndpoint) Close() error {
	e.once.Do(func() {
		close(e.done)
		e.listener.dropSession(e.session)
	})
	return nil
}
