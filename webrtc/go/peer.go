// Full WebRTC peer: UDP socket + ICE (host candidates) + DTLS + SCTP.
// Mirrors webrtc/js/peer.js. Lifecycle: CreateOffer / HandleOffer
// (returns answer) / HandleAnswer, then Connect runs ICE checks,
// performs DTLS over the nominated pair, and returns a DcEndpoint.
package dcwebrtc

import (
	"encoding/hex"
	"errors"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

func defaultLocalIPs() []string {
	ips := []string{"127.0.0.1"}
	interfaces, err := net.Interfaces()
	if err != nil {
		return ips
	}
	for _, iface := range interfaces {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipNet.IP.To4()
			if ip == nil || ip.IsLoopback() {
				continue
			}
			text := ip.String()
			found := false
			for _, existing := range ips {
				if existing == text {
					found = true
				}
			}
			if !found {
				ips = append(ips, text)
			}
		}
	}
	return ips
}

// PeerOptions configures peer creation.
type PeerOptions struct {
	LocalIPs               []string
	RequirePeerCertificate bool
	// StunServers, when non-empty, are queried (in order) for
	// server-reflexive candidates before an offer/answer is made.
	StunServers []string
	// TurnServers, when non-empty, are tried (in order) for a TURN
	// allocation before an offer/answer is made; the first success
	// adds a relay candidate and relays the nominated pair's
	// traffic once connected.
	TurnServers []TurnServerConfig
	// ConsentInterval is how often a consent-freshness check is
	// sent on the nominated pair (RFC 7675); 0 selects the 5 s
	// default, a negative value disables consent checks.
	ConsentInterval time.Duration
	// ConsentExpiry is how long without a consent response
	// before consent is considered expired; 0 selects 30 s.
	ConsentExpiry time.Duration
	// OnRenominated, when set, is invoked once per completed
	// ICE restart (a pair from the new generation nominated).
	OnRenominated func()
	// OnConsentFailure, when set, is invoked exactly once if
	// consent for the nominated pair expires; the endpoint is
	// closed so sends fail instead of hitting a dead pair.
	OnConsentFailure func()
}

// packetConn is the datagram seam for one peer: a real UDP
// socket (default) or one endpoint of a PeerMux shared socket.
// TURN allocation requires a concrete socket and is
// unavailable on muxed peers.
type packetConn interface {
	ReadFromUDP(b []byte) (int, *net.UDPAddr, error)
	WriteToUDP(b []byte, addr *net.UDPAddr) (int, error)
	LocalAddr() net.Addr
	SetReadDeadline(t time.Time) error
	Close() error
}

// Peer is one WebRTC peer.
type Peer struct {
	socket      packetConn
	agent       *IceAgent
	certificate *Certificate
	remote      *SessionDescription
	dtlsRole    string
	dtlsQueue   chan []byte
	endpoint    *DcEndpoint
	options     PeerOptions
	srflx       srflxWaiters
	gathered    bool
	turn        *turnClient
	relayActive bool

	// onLocalCandidate, when set via SetOnLocalCandidate, receives
	// each local candidate line ("a=candidate:...") for trickle
	// signaling: existing candidates replay on registration, later
	// gatherings (srflx/TURN) fire as they are added.
	onLocalCandidate func(string)

	consentStop chan struct{}
	consentOnce sync.Once

	mu     sync.Mutex
	closed bool
	// restartGen is the ICE generation a restart check loop is
	// currently driving (0 = none; generations start at 1
	// after the first restart).
	restartGen int
}

// isIPv6Text reports whether text (an IP literal or host:port)
// names an IPv6 address.
func isIPv6Text(text string) bool {
	if ip := net.ParseIP(text); ip != nil {
		return ip.To4() == nil
	}
	host, _, err := net.SplitHostPort(text)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.To4() == nil
}

// NewPeer binds a UDP socket and builds host candidates.
func NewPeer(options PeerOptions) (*Peer, error) {
	ips := options.LocalIPs
	if ips == nil {
		ips = defaultLocalIPs()
	}
	// A dual-stack udp6 socket serves IPv6 candidates when any
	// local or STUN/TURN server address is IPv6 (IPv4 arrives
	// as mapped addresses, normalized by UDPAddr); otherwise
	// keep the plain udp4 socket.
	wantsV6 := false
	for _, text := range ips {
		wantsV6 = wantsV6 || isIPv6Text(text)
	}
	for _, text := range options.StunServers {
		wantsV6 = wantsV6 || isIPv6Text(text)
	}
	for _, cfg := range options.TurnServers {
		wantsV6 = wantsV6 || isIPv6Text(cfg.Address)
	}
	network, bind := "udp4", "0.0.0.0:0"
	if wantsV6 {
		// "udp" + [::] is dual-stack; "udp6" would set
		// IPV6_V6ONLY and IPv4 sends would be unreachable.
		network, bind = "udp", "[::]:0"
	}
	addr, err := net.ResolveUDPAddr(network, bind)
	if err != nil {
		return nil, err
	}
	socket, err := net.ListenUDP(network, addr)
	if err != nil {
		return nil, err
	}
	return newPeer(options, socket, ips)
}

// newPeer builds a peer on an existing datagram conn (a bound
// UDP socket, or a PeerMux endpoint) advertising `ips` at the
// conn's port.
func newPeer(options PeerOptions, socket packetConn, ips []string) (*Peer, error) {
	port := socket.LocalAddr().(*net.UDPAddr).Port
	agent := NewIceAgent(true)
	for i, ip := range ips {
		agent.LocalCandidates = append(agent.LocalCandidates,
			HostCandidate(ip, port, strconv.Itoa(i+1)))
	}
	cert, err := GenerateCertificate()
	if err != nil {
		return nil, err
	}
	peer := &Peer{
		socket: socket, agent: agent, certificate: cert,
		dtlsRole: "server", dtlsQueue: make(chan []byte, 64),
		options: options,
	}
	if options.RequirePeerCertificate {
		// default true semantics handled by caller passing config
	}
	go peer.readLoop()
	return peer, nil
}

func (p *Peer) readLoop() {
	buf := make([]byte, 65536)
	for {
		n, raddr, err := p.socket.ReadFromUDP(buf)
		if err != nil {
			return
		}
		msg := make([]byte, n)
		copy(msg, buf[:n])
		if n == 0 {
			continue
		}
		p.onPacket(msg, raddr)
	}
}

func (p *Peer) onPacket(msg []byte, src *net.UDPAddr) {
	// TURN demux: packets from the TURN server are allocation
	// control responses or relayed traffic (ChannelData frames or
	// Data indications), never agent STUN or DTLS directly.
	if p.turn != nil && src.Port == p.turn.server.Port && src.IP.Equal(p.turn.server.IP) {
		p.onTurnPacket(msg)
		return
	}
	p.onPacketFrom(msg, src)
}

// onTurnPacket handles one message from the TURN server (a UDP
// datagram, or one framed message off the TCP/TLS stream):
// relayed traffic is unwrapped and re-injected as if it arrived
// from the peer; control responses resolve request waiters.
func (p *Peer) onTurnPacket(msg []byte) {
	if p.turn == nil {
		return
	}
	if len(msg) >= 4 && msg[0] >= 0x40 && msg[0] <= 0x7f {
		if channel, data, ok := unwrapChannelData(msg); ok {
			if peer := p.turn.peerForChannel(channel); peer != nil {
				p.onPacketFrom(data, peer)
			}
		}
		return
	}
	if stun := DecodeStun(msg); stun != nil {
		if stun.Type == StunTypeDataIndication {
			if peer, data := turnUnwrapData(stun); data != nil {
				p.onPacketFrom(data, peer)
			}
			return
		}
		p.turn.resolve(stun)
	}
}

func (p *Peer) onPacketFrom(msg []byte, src *net.UDPAddr) {
	if len(msg) == 0 {
		return
	}
	if msg[0] < 4 {
		// A Binding Success answering a srflx gathering request is
		// consumed here, not by the ICE agent.
		if stun := DecodeStun(msg); stun != nil && stun.Type == StunTypeBindingSuccess {
			tid := hex.EncodeToString(stun.TransactionID[:])
			if p.srflx.resolve(tid, decodeXorMappedAddress(stun)) {
				return
			}
		}
		responses, _ := p.agent.HandleStun(msg, src)
		for _, response := range responses {
			p.sendTo(response.Bytes, response.Remote)
		}
	} else if msg[0] >= 20 && msg[0] < 64 {
		select {
		case p.dtlsQueue <- msg:
		default:
		}
	}
}

func (p *Peer) sendTo(data []byte, remote *net.UDPAddr) {
	if p.turn != nil && p.relayActive {
		p.turnSendData(data, remote)
		return
	}
	_, _ = p.socket.WriteToUDP(data, remote)
}

func (p *Peer) localDescription(setup string) SessionDescription {
	return SessionDescription{
		Ufrag: p.agent.LocalUfrag, Pwd: p.agent.LocalPwd,
		Fingerprint: p.certificate.Fingerprint(), Setup: setup,
		Candidates: p.agent.LocalCandidates, SctpPort: SctpPort,
	}
}

// CreateOffer builds an offer SDP (actpass).
func (p *Peer) CreateOffer() string {
	p.gatherFromOptions()
	p.agent.SetControlling(true)
	p.dtlsRole = "server"
	d := p.localDescription("actpass")
	return d.Generate("offer")
}

// HandleOffer applies an offer and returns the answer SDP.
func (p *Peer) HandleOffer(offerSdp string) (string, error) {
	p.gatherFromOptions()
	remote, err := ParseSDP(offerSdp)
	if err != nil {
		return "", err
	}
	p.applyRemote(*remote)
	p.agent.SetControlling(false)
	p.dtlsRole = "client"
	d := p.localDescription("active")
	return d.Generate("answer"), nil
}

// HandleAnswer applies an answer SDP.
func (p *Peer) HandleAnswer(answerSdp string) error {
	remote, err := ParseSDP(answerSdp)
	if err != nil {
		return err
	}
	if remote.Setup == "active" {
		p.dtlsRole = "server"
	} else {
		p.dtlsRole = "client"
	}
	p.applyRemote(*remote)
	return nil
}

func (p *Peer) applyRemote(remote SessionDescription) {
	p.agent.SetRemote(remote.Ufrag, remote.Pwd, remote.Candidates)
	p.remote = &remote
}

// restartSetup is the SDP setup value that keeps the existing
// DTLS association across an ICE restart (the side that was
// the DTLS client stays "active", the server "passive").
func (p *Peer) restartSetup() string {
	if p.dtlsRole == "client" {
		return "active"
	}
	return "passive"
}

// CreateRestartOffer begins an ICE restart on a connected peer
// (RFC 8445 §5.1): fresh local credentials, same candidates
// and DTLS fingerprint. Hand the result to the remote's
// HandleRestartOffer and apply its answer with
// HandleRestartAnswer; media keeps flowing on the old pair
// until renomination, which fires Options.OnRenominated.
func (p *Peer) CreateRestartOffer() string {
	p.agent.Restart()
	d := p.localDescription(p.restartSetup())
	return d.Generate("offer")
}

// HandleRestartOffer applies a restart offer (fresh local
// credentials too) and returns the restart answer SDP.
func (p *Peer) HandleRestartOffer(offerSdp string) (string, error) {
	remote, err := ParseSDP(offerSdp)
	if err != nil {
		return "", err
	}
	p.agent.Restart()
	p.applyRemote(*remote)
	p.startRestartChecks()
	d := p.localDescription(p.restartSetup())
	return d.Generate("answer"), nil
}

// HandleRestartAnswer applies a restart answer SDP.
func (p *Peer) HandleRestartAnswer(answerSdp string) error {
	remote, err := ParseSDP(answerSdp)
	if err != nil {
		return err
	}
	p.applyRemote(*remote)
	p.startRestartChecks()
	return nil
}

// startRestartChecks drives connectivity checks for the
// current ICE generation until renomination (or peer close /
// timeout), mirroring the connect loop. TURN permissions are
// refreshed first so candidates new in the restart SDP are
// relayable. Only one loop runs per generation.
func (p *Peer) startRestartChecks() {
	p.resolveRemoteCandidates()
	if p.turn != nil {
		p.turnCreatePermissions(2 * time.Second)
		p.turn.mu.Lock()
		peers := append([]*net.UDPAddr(nil), p.turn.peers...)
		p.turn.mu.Unlock()
		if len(peers) > 0 {
			p.turnBindChannels(peers, 2*time.Second)
		}
	}
	generation := p.agent.Generation()
	p.mu.Lock()
	if p.restartGen == generation {
		p.mu.Unlock()
		return
	}
	p.restartGen = generation
	p.mu.Unlock()
	go func() {
		deadline := time.Now().Add(15 * time.Second)
		lastResolve := time.Now()
		for time.Now().Before(deadline) {
			p.maybeResolveRemote(&lastResolve)
			if p.agent.Renominated() && p.agent.Generation() == generation {
				if p.options.OnRenominated != nil {
					p.options.OnRenominated()
				}
				return
			}
			p.mu.Lock()
			closed := p.closed
			stale := p.restartGen != generation
			p.mu.Unlock()
			if closed || stale {
				return
			}
			for _, check := range p.agent.DueChecks() {
				if addr, err := net.ResolveUDPAddr("udp",
					net.JoinHostPort(check.Remote.Address, strconv.Itoa(check.Remote.Port))); err == nil {
					p.sendTo(check.Bytes, addr)
				}
			}
			time.Sleep(50 * time.Millisecond)
		}
	}()
}

// resolveRemoteCandidates resolves mDNS ".local" candidate
// addresses to IPs in place (browsers advertise those).
// Resolution waits on the network, so it runs without the agent
// lock held: inbound checks must keep flowing meanwhile.
func (p *Peer) resolveRemoteCandidates() {
	p.agent.mu.Lock()
	names := make([]string, 0)
	for _, c := range p.agent.RemoteCandidates {
		if net.ParseIP(c.Address) == nil {
			names = append(names, c.Address)
		}
	}
	p.agent.mu.Unlock()
	if len(names) == 0 {
		return
	}
	resolved := make(map[string]string, len(names))
	for _, name := range names {
		if ip := ResolveMDNS(name, 2*time.Second); ip != "" {
			resolved[name] = ip
		}
	}
	if len(resolved) == 0 {
		return
	}
	p.agent.mu.Lock()
	defer p.agent.mu.Unlock()
	for i := range p.agent.RemoteCandidates {
		c := &p.agent.RemoteCandidates[i]
		if ip, ok := resolved[c.Address]; ok {
			c.Address = ip
		}
	}
}

// hasUnresolvedRemote reports whether any remote candidate still
// carries a non-IP (mDNS) address.
func (p *Peer) hasUnresolvedRemote() bool {
	p.agent.mu.Lock()
	defer p.agent.mu.Unlock()
	for _, c := range p.agent.RemoteCandidates {
		if net.ParseIP(c.Address) == nil {
			return true
		}
	}
	return false
}

// maybeResolveRemote retries mDNS resolution at most once a
// second while checks are in flight: a browser's mDNS responder
// can miss the initial window under load, and an unresolved
// ".local" candidate would otherwise silently never be checked.
func (p *Peer) maybeResolveRemote(last *time.Time) {
	if time.Since(*last) < time.Second || !p.hasUnresolvedRemote() {
		return
	}
	*last = time.Now()
	p.resolveRemoteCandidates()
}

// AddRemoteCandidate trickles one remote candidate in after the
// remote description was applied (RFC 8445 trickle ICE). Accepts
// a full SDP line ("a=candidate:..."), the bare candidate value
// ("candidate:...", as browsers hand to addIceCandidate), an
// end-of-candidates line, or an empty string; the latter two are
// accepted no-ops. Returns true when a new candidate was added
// (duplicates and malformed lines return false). Safe to call
// while Connect is running; mDNS ".local" addresses are resolved
// here, as Connect does for SDP-carried candidates.
func (p *Peer) AddRemoteCandidate(line string) bool {
	line = strings.TrimSpace(line)
	if line == "" || strings.Contains(line, "end-of-candidates") {
		return false
	}
	cand := CandidateFromSDP(strings.TrimPrefix(line, "a="))
	if cand == nil {
		return false
	}
	if net.ParseIP(cand.Address) == nil {
		if ip := ResolveMDNS(cand.Address, 2*time.Second); ip != "" {
			cand.Address = ip
		}
	}
	if !p.agent.AddRemoteCandidate(*cand) {
		return false
	}
	// A candidate trickled in after Connect's snapshot also
	// needs a TURN permission (and channel binding), or the
	// relay silently drops its traffic. Valid any time an
	// allocation exists.
	if ip := net.ParseIP(cand.Address); ip != nil && p.turn != nil {
		go p.turnAddPeer(&net.UDPAddr{IP: ip, Port: cand.Port}, 2*time.Second)
	}
	return true
}

// SetOnLocalCandidate registers the trickle callback for local
// candidates and immediately replays the candidates gathered so
// far; candidates gathered later (srflx/TURN at offer/answer
// time) fire as they are added.
func (p *Peer) SetOnLocalCandidate(cb func(string)) {
	p.mu.Lock()
	p.onLocalCandidate = cb
	candidates := append([]Candidate(nil), p.agent.LocalCandidates...)
	p.mu.Unlock()
	if cb != nil {
		for _, c := range candidates {
			cb(c.ToSDP())
		}
	}
}

// emitLocalCandidate fires the trickle callback for one newly
// gathered local candidate, if registered.
func (p *Peer) emitLocalCandidate(c Candidate) {
	p.mu.Lock()
	cb := p.onLocalCandidate
	p.mu.Unlock()
	if cb != nil {
		cb(c.ToSDP())
	}
}

// LocalCandidateLines returns the local candidates as SDP lines
// ("a=candidate:...") for trickle signaling.
func (p *Peer) LocalCandidateLines() []string {
	lines := make([]string, 0, len(p.agent.LocalCandidates))
	for _, c := range p.agent.LocalCandidates {
		lines = append(lines, c.ToSDP())
	}
	return lines
}

type peerIO struct {
	peer       *Peer
	selected   *net.UDPAddr
	connectGen int
}

func (io *peerIO) Send(buf []byte) error {
	// The destination is pinned to the pair nominated at
	// connect (later same-generation nominations, e.g. a
	// browser re-nominating another pair, must not drift it);
	// an ICE restart's renomination is the one switch point.
	dest := io.selected
	if io.peer.agent.Renominated() && io.peer.agent.Generation() != io.connectGen {
		if nominated := io.peer.agent.NominatedAddr(); nominated != nil {
			io.selected = nominated
			io.connectGen = io.peer.agent.Generation()
			dest = nominated
		}
	}
	io.peer.sendTo(buf, dest)
	return nil
}

func (io *peerIO) Recv(timeoutMs int) []byte {
	if timeoutMs <= 0 {
		select {
		case msg := <-io.peer.dtlsQueue:
			return msg
		default:
			return nil
		}
	}
	select {
	case msg := <-io.peer.dtlsQueue:
		return msg
	case <-time.After(time.Duration(timeoutMs) * time.Millisecond):
		return nil
	}
}

// Connect runs ICE nomination and the DTLS handshake.
func (p *Peer) Connect() (*DcEndpoint, error) {
	return p.ConnectWithOptions(true)
}

// ConnectWithOptions runs ICE + DTLS; requirePeerCert enforces a
// peer certificate (browsers always present one).
func (p *Peer) ConnectWithOptions(requirePeerCert bool) (*DcEndpoint, error) {
	if p.remote == nil {
		return nil, errors.New("no remote description")
	}
	p.resolveRemoteCandidates()
	if p.turn != nil {
		// Relay the session: permissions (and channels) for
		// every remote candidate first, then all pair traffic
		// goes through the allocation (wrapped by sendTo).
		p.turnCreatePermissions(2 * time.Second)
		p.turn.mu.Lock()
		peers := append([]*net.UDPAddr(nil), p.turn.peers...)
		p.turn.mu.Unlock()
		if len(peers) > 0 {
			p.turnBindChannels(peers, 2*time.Second)
		}
		p.relayActive = true
	}
	deadline := time.Now().Add(15 * time.Second)
	lastResolve := time.Now()
	var selected *net.UDPAddr
	for selected == nil {
		if time.Now().After(deadline) {
			return nil, errors.New("ICE nomination timed out")
		}
		p.maybeResolveRemote(&lastResolve)
		for _, check := range p.agent.DueChecks() {
			if addr, err := net.ResolveUDPAddr("udp",
				net.JoinHostPort(check.Remote.Address, strconv.Itoa(check.Remote.Port))); err == nil {
				p.sendTo(check.Bytes, addr)
			}
		}
		p.agent.mu.Lock()
		selected = p.agent.Nominated
		p.agent.mu.Unlock()
		if selected == nil {
			time.Sleep(50 * time.Millisecond)
		}
	}
	emitStackEvent("ice.nominated", selected.String())
	io := &peerIO{peer: p, selected: selected, connectGen: p.agent.Generation()}
	config := DtlsConfig{
		Certificate:             p.certificate,
		ExpectedPeerFingerprint: p.remote.Fingerprint,
		RequirePeerCertificate:  requirePeerCert,
	}
	var dtls *DtlsConnection
	var err error
	if p.dtlsRole == "client" {
		dtls, err = DtlsConnect(io, config)
	} else {
		dtls, err = DtlsAccept(io, config)
	}
	if err != nil {
		return nil, err
	}
	emitStackEvent("dtls.handshake", "full")
	p.endpoint = NewDcEndpoint(dtls, p.dtlsRole)
	emitStackEvent("endpoint.ready", p.dtlsRole)
	p.startConsentLoop()
	return p.endpoint, nil
}

// startConsentLoop periodically re-checks the nominated pair
// (RFC 7675 consent freshness). On expiry it closes the
// endpoint and fires OnConsentFailure once.
func (p *Peer) startConsentLoop() {
	interval := p.options.ConsentInterval
	if interval < 0 {
		return
	}
	if interval == 0 {
		interval = 5 * time.Second
	}
	expiry := p.options.ConsentExpiry
	if expiry <= 0 {
		expiry = 30 * time.Second
	}
	p.consentStop = make(chan struct{})
	// The DTLS handshake just proved the pair; start the
	// consent clock from here, not from nomination.
	p.agent.TouchConsent()
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-p.consentStop:
				return
			case <-ticker.C:
			}
			if check, ok := p.agent.ConsentCheck(); ok {
				if addr, err := net.ResolveUDPAddr("udp",
					net.JoinHostPort(check.Remote.Address, strconv.Itoa(check.Remote.Port))); err == nil {
					p.sendTo(check.Bytes, addr)
				}
			}
			if p.agent.ConsentExpired(expiry) {
				if p.options.OnConsentFailure != nil {
					p.options.OnConsentFailure()
				}
				if p.endpoint != nil {
					p.endpoint.Close()
				}
				return
			}
		}
	}()
}

// ConsentExpired reports whether consent freshness has lapsed
// for the nominated pair (false before nomination).
func (p *Peer) ConsentExpired() bool {
	expiry := p.options.ConsentExpiry
	if expiry <= 0 {
		expiry = 30 * time.Second
	}
	return p.agent.ConsentExpired(expiry)
}

// LocalCandidates exposes the agent's candidates (tests).
func (p *Peer) LocalCandidates() []Candidate { return p.agent.LocalCandidates }

// Close tears down the endpoint and socket.
func (p *Peer) Close() {
	p.mu.Lock()
	p.closed = true
	p.mu.Unlock()
	p.consentOnce.Do(func() {
		if p.consentStop != nil {
			close(p.consentStop)
		}
	})
	if p.turn != nil {
		p.turn.stop()
	}
	if p.endpoint != nil {
		p.endpoint.Close()
	}
	_ = p.socket.Close()
}
