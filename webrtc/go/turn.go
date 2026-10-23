// TURN (RFC 5766) relay support: an Allocate over the peer's own
// UDP socket yields a relayed candidate; once the peer connects,
// its traffic for the nominated pair is wrapped in Send/Data
// indications through the allocation. Long-term credentials
// (401 REALM/NONCE challenge, MD5 key) are the only auth mode.
// Permissions are created per remote candidate at connect time
// and a channel is bound per peer address, so pair traffic uses
// 4-byte ChannelData framing (Send/Data indications remain the
// fallback for unbound addresses, and are accepted inbound). A
// background refresher re-issues CreatePermission, ChannelBind,
// and Refresh until the peer closes.
package dcwebrtc

import (
	"bufio"
	"crypto/md5"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

// TurnServerConfig configures one TURN server (host:port) with
// long-term credentials. Transport selects the client<->server
// transport: "" or "udp" runs the allocation over the peer's own
// UDP socket; "tcp" and "tls" open a dedicated stream connection
// (RFC 5766 section 4; relayed traffic still reaches peers over
// UDP — REQUESTED-TRANSPORT stays 17). For "tls", ServerName
// overrides the TLS verification name (default: the host part of
// Address) and InsecureSkipVerify disables certificate
// verification (self-signed deployments/tests).
type TurnServerConfig struct {
	Address            string
	Username           string
	Password           string
	Transport          string
	ServerName         string
	InsecureSkipVerify bool
	// RequestIPv6Relay asks the server for an IPv6 relayed
	// address (REQUESTED-ADDRESS-FAMILY, RFC 8656). Some
	// servers (coturn with only an IPv6 relay address) reject
	// allocations that do not request it with error 440.
	RequestIPv6Relay bool
}

// turnClient is one live TURN allocation.
type turnClient struct {
	server  *net.UDPAddr
	relayed *net.UDPAddr
	mapped  *net.UDPAddr
	// conn is the dedicated TCP/TLS connection to the server
	// (nil for UDP transport, where the peer socket is used).
	// connMu serializes writes; a reader goroutine frames
	// inbound messages into the same demux as UDP packets.
	conn   net.Conn
	connMu sync.Mutex
	// Long-term credential state from the 401 challenge.
	username string
	realm    string
	nonce    string
	key      []byte // MD5(username:realm:password)
	// lifetime is the server-granted allocation lifetime.
	lifetime time.Duration

	mu      sync.Mutex
	waiters map[string]chan *StunMessage
	// peers are the addresses with relay permissions, re-issued
	// by the refresher.
	peers []*net.UDPAddr
	// Channel bindings (RFC 5766 §9): peer address <-> channel
	// number, guarded by mu.
	bindings map[string]uint16
	channels map[uint16]*net.UDPAddr
	nextChan uint16
	// stopRefresh closes when the refresher should exit.
	stopRefresh chan struct{}
	stopOnce    sync.Once
}

// refreshInterval is how often permissions and the allocation
// are refreshed: 80% of whichever expires first — permissions
// (300 s, RFC 5766 §8) or the allocation lifetime.
func (t *turnClient) refreshInterval() time.Duration {
	interval := t.lifetime * 4 / 5
	if interval <= 0 || interval > 240*time.Second {
		interval = 240 * time.Second
	}
	if interval < 250*time.Millisecond {
		interval = 250 * time.Millisecond
	}
	return interval
}

// stop ends the background refresher (idempotent).
func (t *turnClient) stop() {
	t.stopOnce.Do(func() {
		if t.stopRefresh != nil {
			close(t.stopRefresh)
		}
		if t.conn != nil {
			_ = t.conn.Close()
		}
	})
}

// stream reports whether this allocation runs over a dedicated
// TCP/TLS connection rather than the peer's UDP socket.
func (t *turnClient) stream() bool { return t.conn != nil }

// lifetimeOf extracts the LIFETIME attribute (default 600 s).
func lifetimeOf(msg *StunMessage) time.Duration {
	value := msg.attr(StunAttrLifetime)
	if len(value) < 4 {
		return 600 * time.Second
	}
	secs := binary.BigEndian.Uint32(value)
	if secs == 0 {
		return 600 * time.Second
	}
	return time.Duration(secs) * time.Second
}

func (t *turnClient) register(tid string) chan *StunMessage {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.waiters == nil {
		t.waiters = map[string]chan *StunMessage{}
	}
	ch := make(chan *StunMessage, 1)
	t.waiters[tid] = ch
	return ch
}

// resolve delivers a control response to its waiter; false when the
// message is not a TURN control response we're waiting for.
func (t *turnClient) resolve(msg *StunMessage) bool {
	tid := hex.EncodeToString(msg.TransactionID[:])
	t.mu.Lock()
	defer t.mu.Unlock()
	ch, ok := t.waiters[tid]
	if ok {
		delete(t.waiters, tid)
		ch <- msg
	}
	return ok
}

func (t *turnClient) cancel(tid string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.waiters, tid)
}

// RelayCandidate builds a typ relay candidate (type preference 0,
// RFC 8445 §5.1.1: relayed candidates are the last resort).
func RelayCandidate(address string, port int, base Candidate, foundation string) Candidate {
	return Candidate{
		Foundation: foundation,
		Component:  1,
		Priority:   candidatePriority(0, 1),
		Address:    address,
		Port:       port,
		Type:       "relay",
		RAddr:      base.Address,
		RPort:      base.Port,
	}
}

// xorAddressValue encodes an XOR-{PEER,RELAYED,MAPPED}-ADDRESS
// attribute value for a message carrying tid (the IPv6 XOR
// mask includes the transaction ID).
func xorAddressValue(addr *net.UDPAddr, tid [12]byte) []byte {
	return xorAddress(addr, tid)
}

// decodeXorAddressAttr decodes an XOR-encoded address attribute
// of a message (either family).
func decodeXorAddressAttr(msg *StunMessage, attr uint16) *net.UDPAddr {
	return decodeXorAddress(msg.attr(attr), msg.TransactionID, true)
}

// turnWrite sends one TURN message to the server: over the
// dedicated stream connection for TCP/TLS allocations
// (ChannelData frames padded to a 4-byte boundary, RFC 5766
// section 4), else as a UDP datagram on the TURN transport
// socket (the peer socket, or a muxed peer's dedicated one).
func (p *Peer) turnWrite(client *turnClient, frame []byte, channelData bool) error {
	if client.stream() {
		if channelData {
			if pad := (4 - len(frame)%4) % 4; pad > 0 {
				padded := make([]byte, len(frame)+pad)
				copy(padded, frame)
				frame = padded
			}
		}
		client.connMu.Lock()
		defer client.connMu.Unlock()
		_, err := client.conn.Write(frame)
		return err
	}
	if p.turnSocket != nil {
		_, err := p.turnSocket.WriteToUDP(frame, client.server)
		return err
	}
	_, err := p.socket.WriteToUDP(frame, client.server)
	return err
}

// turnReadLoop drains a muxed peer's dedicated TURN socket:
// every datagram on it is from the TURN server by
// construction, so each feeds the same demux as UDP packets
// on an ordinary peer's socket. Exits when the socket closes
// (peer teardown or a failed allocation).
func (p *Peer) turnReadLoop() {
	buf := make([]byte, 65536)
	for {
		n, _, err := p.turnSocket.ReadFromUDP(buf)
		if err != nil {
			return
		}
		if n == 0 {
			continue
		}
		msg := make([]byte, n)
		copy(msg, buf[:n])
		p.onTurnPacket(msg)
	}
}

// turnStreamReadLoop frames inbound TCP/TLS stream bytes into
// TURN messages (STUN by header length, ChannelData by its
// length field plus 4-byte-boundary padding) and feeds each
// into the same demux as UDP packets from the server.
func (p *Peer) turnStreamReadLoop(client *turnClient) {
	reader := bufio.NewReader(client.conn)
	for {
		first, err := reader.Peek(1)
		if err != nil {
			return
		}
		var msg []byte
		if first[0] >= 0x40 && first[0] <= 0x7f {
			header := make([]byte, 4)
			if _, err := io.ReadFull(reader, header); err != nil {
				return
			}
			length := int(binary.BigEndian.Uint16(header[2:4]))
			total := 4 + length
			padded := total + (4-total%4)%4
			rest := make([]byte, padded-4)
			if _, err := io.ReadFull(reader, rest); err != nil {
				return
			}
			msg = append(header, rest[:length]...)
		} else {
			header := make([]byte, 20)
			if _, err := io.ReadFull(reader, header); err != nil {
				return
			}
			length := int(binary.BigEndian.Uint16(header[2:4]))
			body := make([]byte, length)
			if _, err := io.ReadFull(reader, body); err != nil {
				return
			}
			msg = append(header, body...)
		}
		p.onTurnPacket(msg)
	}
}

// dialTurnStream opens the TCP or TLS connection for a stream
// TURN allocation.
func dialTurnStream(cfg TurnServerConfig, timeout time.Duration) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: timeout}
	switch strings.ToLower(cfg.Transport) {
	case "tcp":
		return dialer.Dial("tcp", cfg.Address)
	case "tls":
		serverName := cfg.ServerName
		if serverName == "" {
			host, _, err := net.SplitHostPort(cfg.Address)
			if err != nil {
				return nil, err
			}
			serverName = host
		}
		return tls.DialWithDialer(dialer, "tcp", cfg.Address, &tls.Config{
			ServerName:         serverName,
			InsecureSkipVerify: cfg.InsecureSkipVerify, //nolint:gosec // opt-in per config
			MinVersion:         tls.VersionTLS12,
		})
	default:
		return nil, fmt.Errorf("turn: unsupported transport %q", cfg.Transport)
	}
}

// turnRequest sends one TURN control message (over the peer
// socket, or the stream connection for TCP/TLS) and waits for
// its response (matched by transaction id). key is the
// MESSAGE-INTEGRITY key (nil for the first, unauthenticated
// attempt).
func (p *Peer) turnRequest(client *turnClient, msg *StunMessage, key []byte, timeout time.Duration) (*StunMessage, error) {
	tid := hex.EncodeToString(msg.TransactionID[:])
	ch := client.register(tid)
	defer client.cancel(tid)
	if err := p.turnWrite(client, msg.Encode(key), false); err != nil {
		return nil, err
	}
	select {
	case resp := <-ch:
		return resp, nil
	case <-time.After(timeout):
		return nil, errors.New("turn: timed out waiting for response")
	}
}

func turnErrorCode(msg *StunMessage) int {
	value := msg.attr(StunAttrErrorCode)
	if len(value) < 4 {
		return 0
	}
	return int(value[2])*100 + int(value[3])
}

// AllocateTurn runs the TURN Allocate handshake (with the 401
// long-term-credential dance when the server demands it) and
// appends the relayed candidate. Called automatically from
// gatherFromOptions for the first reachable TurnServers entry.
func (p *Peer) AllocateTurn(cfg TurnServerConfig, timeout time.Duration) (err error) {
	serverAddr, err := net.ResolveUDPAddr("udp", cfg.Address)
	if err != nil {
		return err
	}
	client := &turnClient{server: serverAddr, username: cfg.Username}
	if transport := strings.ToLower(cfg.Transport); transport == "tcp" || transport == "tls" {
		conn, dialErr := dialTurnStream(cfg, timeout)
		if dialErr != nil {
			return dialErr
		}
		client.conn = conn
	} else if transport != "" && transport != "udp" {
		return fmt.Errorf("turn: unsupported transport %q", cfg.Transport)
	}
	// Publish before the first request: the read loop demultiplexes
	// TURN control responses (and later Data indications) by sender
	// matching p.turn; the stream reader does the same for TCP/TLS.
	p.turn = client
	if client.stream() {
		go p.turnStreamReadLoop(client)
	}
	// Muxed peer (the socket is a mux endpoint, not a concrete
	// conn): the TURN leg gets a dedicated socket — an
	// allocation pins a concrete 5-tuple, which the shared
	// mux socket cannot provide. TURN-server packets arrive
	// on it and feed the same demux as stream framing.
	if _, ok := p.socket.(*net.UDPConn); !ok && !client.stream() {
		bind := &net.UDPAddr{Port: 0}
		if serverAddr.IP != nil && serverAddr.IP.To4() == nil {
			bind.IP = net.IPv6zero
		}
		conn, listenErr := net.ListenUDP("udp", bind)
		if listenErr != nil {
			return listenErr
		}
		p.turnSocket = conn
		go p.turnReadLoop()
	}
	// On failure, unpublish and tear down so a later config (or
	// plain host candidates) is tried clean.
	defer func() {
		if err != nil {
			if p.turn == client {
				p.turn = nil
			}
			client.stop()
			if p.turnSocket != nil {
				p.turnSocket.Close()
				p.turnSocket = nil
			}
		}
	}()

	build := func(auth bool) *StunMessage {
		msg := newStunMessage(StunTypeAllocateRequest)
		msg.addAttr(StunAttrRequestedTransport, []byte{17, 0, 0, 0})
		if cfg.RequestIPv6Relay {
			// REQUESTED-ADDRESS-FAMILY: family 2 (IPv6).
			msg.addAttr(StunAttrRequestedAddressFamily, []byte{2, 0, 0, 0})
		}
		if auth {
			msg.addAttr(StunAttrUsername, []byte(cfg.Username))
			msg.addAttr(StunAttrRealm, []byte(client.realm))
			msg.addAttr(StunAttrNonce, []byte(client.nonce))
		}
		return msg
	}

	resp, err := p.turnRequest(client, build(false), nil, timeout)
	if err != nil {
		return err
	}
	if resp.Type == StunTypeAllocateError && turnErrorCode(resp) == 401 {
		client.realm = string(resp.attr(StunAttrRealm))
		client.nonce = string(resp.attr(StunAttrNonce))
		sum := md5.Sum([]byte(cfg.Username + ":" + client.realm + ":" + cfg.Password))
		client.key = sum[:]
		resp, err = p.turnRequest(client, build(true), client.key, timeout)
		if err != nil {
			return err
		}
	}
	if resp.Type != StunTypeAllocateSuccess {
		return fmt.Errorf("turn: allocate failed (type %#x, code %d)", resp.Type, turnErrorCode(resp))
	}
	client.relayed = decodeXorAddressAttr(resp, StunAttrXorRelayedAddress)
	client.mapped = decodeXorAddressAttr(resp, StunAttrXorMappedAddress)
	if client.relayed == nil {
		return errors.New("turn: allocate success without XOR-RELAYED-ADDRESS")
	}
	client.lifetime = lifetimeOf(resp)
	p.startTurnRefresher(client)

	base := Candidate{Address: p.socket.LocalAddr().(*net.UDPAddr).IP.String(),
		Port: p.socket.LocalAddr().(*net.UDPAddr).Port, Type: "host"}
	if len(p.agent.LocalCandidates) > 0 {
		base = p.agent.LocalCandidates[0]
	}
	cand := RelayCandidate(client.relayed.IP.String(), client.relayed.Port, base,
		strconv.Itoa(len(p.agent.LocalCandidates)+1))
	for _, existing := range p.agent.LocalCandidates {
		if existing.Address == cand.Address && existing.Port == cand.Port {
			return nil
		}
	}
	p.agent.LocalCandidates = append(p.agent.LocalCandidates, cand)
	p.emitLocalCandidate(cand)
	return nil
}

// turnCreatePermissions installs relay permissions for the peer's
// remote candidates so the server will forward our relayed traffic
// (and deliver the peer's). Best-effort: failures surface later as
// missing connectivity, like an unreachable candidate. The
// permissioned addresses are remembered for the refresher.
func (p *Peer) turnCreatePermissions(timeout time.Duration) {
	if p.turn == nil {
		return
	}
	var addrs []*net.UDPAddr
	seen := map[string]bool{}
	p.agent.mu.Lock()
	remoteCandidates := append([]Candidate(nil), p.agent.RemoteCandidates...)
	p.agent.mu.Unlock()
	for _, cand := range remoteCandidates {
		ip := net.ParseIP(cand.Address)
		if ip == nil {
			continue // mDNS name: cannot permission an unresolved address
		}
		key := cand.Address + ":" + strconv.Itoa(cand.Port)
		if seen[key] {
			continue
		}
		seen[key] = true
		addrs = append(addrs, &net.UDPAddr{IP: ip, Port: cand.Port})
	}
	if len(addrs) == 0 {
		return
	}
	// Merge (never replace): candidates trickled in earlier may
	// already have added peers the refresher must keep alive.
	p.turn.mu.Lock()
	for _, addr := range addrs {
		found := false
		for _, existing := range p.turn.peers {
			if existing.String() == addr.String() {
				found = true
				break
			}
		}
		if !found {
			p.turn.peers = append(p.turn.peers, addr)
		}
	}
	p.turn.mu.Unlock()
	p.turnCreatePermissionsFor(addrs, timeout)
}

// turnAddPeer installs a permission and channel binding for one
// peer address trickled in after the connect-time snapshot, and
// remembers it for the refresher. Best-effort and idempotent.
func (p *Peer) turnAddPeer(addr *net.UDPAddr, timeout time.Duration) {
	if p.turn == nil || addr == nil {
		return
	}
	p.turn.mu.Lock()
	for _, existing := range p.turn.peers {
		if existing.String() == addr.String() {
			p.turn.mu.Unlock()
			return
		}
	}
	p.turn.peers = append(p.turn.peers, addr)
	p.turn.mu.Unlock()
	p.turnCreatePermissionsFor([]*net.UDPAddr{addr}, timeout)
	p.turnBindChannels([]*net.UDPAddr{addr}, timeout)
}

// turnCreatePermissionsFor sends one CreatePermission request for
// the given peer addresses.
func (p *Peer) turnCreatePermissionsFor(addrs []*net.UDPAddr, timeout time.Duration) {
	msg := newStunMessage(StunTypeCreatePermissionRequest)
	for _, addr := range addrs {
		msg.addAttr(StunAttrXorPeerAddress, xorAddressValue(addr, msg.TransactionID))
	}
	msg.addAttr(StunAttrUsername, []byte(p.turn.username))
	msg.addAttr(StunAttrRealm, []byte(p.turn.realm))
	msg.addAttr(StunAttrNonce, []byte(p.turn.nonce))
	_, _ = p.turnRequest(p.turn, msg, p.turn.key, timeout)
}

// turnBindChannels binds one channel per peer address (RFC 5766
// §9; a binding also installs the permission). Best-effort: on
// failure the peer simply keeps using Send indications.
func (p *Peer) turnBindChannels(addrs []*net.UDPAddr, timeout time.Duration) {
	for _, addr := range addrs {
		p.turn.mu.Lock()
		if p.turn.bindings == nil {
			p.turn.bindings = map[string]uint16{}
			p.turn.channels = map[uint16]*net.UDPAddr{}
			p.turn.nextChan = 0x4000
		}
		channel, known := p.turn.bindings[addr.String()]
		if !known {
			channel = p.turn.nextChan
			p.turn.nextChan++
		}
		p.turn.mu.Unlock()

		msg := newStunMessage(StunTypeChannelBindRequest)
		chanAttr := make([]byte, 4)
		binary.BigEndian.PutUint16(chanAttr, channel)
		msg.addAttr(StunAttrChannelNumber, chanAttr)
		msg.addAttr(StunAttrXorPeerAddress, xorAddressValue(addr, msg.TransactionID))
		msg.addAttr(StunAttrUsername, []byte(p.turn.username))
		msg.addAttr(StunAttrRealm, []byte(p.turn.realm))
		msg.addAttr(StunAttrNonce, []byte(p.turn.nonce))
		resp, err := p.turnRequest(p.turn, msg, p.turn.key, timeout)
		if err != nil || resp.Type != StunTypeChannelBindSuccess {
			continue
		}
		p.turn.mu.Lock()
		p.turn.bindings[addr.String()] = channel
		p.turn.channels[channel] = addr
		p.turn.mu.Unlock()
	}
}

// channelFor returns the bound channel for a peer address.
func (t *turnClient) channelFor(peer *net.UDPAddr) (uint16, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	channel, ok := t.bindings[peer.String()]
	return channel, ok
}

// peerForChannel returns the peer address bound to a channel.
func (t *turnClient) peerForChannel(channel uint16) *net.UDPAddr {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.channels[channel]
}

// wrapChannelData frames one datagram as ChannelData (RFC 5766
// §11): channel number, length, payload (no padding over UDP).
func wrapChannelData(channel uint16, data []byte) []byte {
	out := make([]byte, 4+len(data))
	binary.BigEndian.PutUint16(out[0:2], channel)
	binary.BigEndian.PutUint16(out[2:4], uint16(len(data)))
	copy(out[4:], data)
	return out
}

// unwrapChannelData parses a ChannelData message, tolerating
// trailing padding beyond the length field.
func unwrapChannelData(msg []byte) (uint16, []byte, bool) {
	if len(msg) < 4 {
		return 0, nil, false
	}
	length := int(binary.BigEndian.Uint16(msg[2:4]))
	if 4+length > len(msg) {
		return 0, nil, false
	}
	return binary.BigEndian.Uint16(msg[0:2]), msg[4 : 4+length], true
}

// turnRefreshAllocation extends the allocation (RFC 5766 §7),
// requesting the default 600 s and adopting the granted lifetime.
func (p *Peer) turnRefreshAllocation(timeout time.Duration) {
	msg := newStunMessage(StunTypeRefreshRequest)
	lifetime := make([]byte, 4)
	binary.BigEndian.PutUint32(lifetime, 600)
	msg.addAttr(StunAttrLifetime, lifetime)
	msg.addAttr(StunAttrUsername, []byte(p.turn.username))
	msg.addAttr(StunAttrRealm, []byte(p.turn.realm))
	msg.addAttr(StunAttrNonce, []byte(p.turn.nonce))
	resp, err := p.turnRequest(p.turn, msg, p.turn.key, timeout)
	if err != nil || resp.Type != StunTypeRefreshSuccess {
		return // best-effort: the next tick retries until expiry
	}
	p.turn.lifetime = lifetimeOf(resp)
}

// startTurnRefresher launches the background permission/allocation
// refresher for a fresh allocation; Peer.Close stops it.
func (p *Peer) startTurnRefresher(client *turnClient) {
	client.stopRefresh = make(chan struct{})
	go func() {
		for {
			select {
			case <-client.stopRefresh:
				return
			case <-time.After(client.refreshInterval()):
			}
			client.mu.Lock()
			peers := append([]*net.UDPAddr(nil), client.peers...)
			client.mu.Unlock()
			if len(peers) > 0 {
				p.turnCreatePermissionsFor(peers, 2*time.Second)
				p.turnBindChannels(peers, 2*time.Second)
			}
			p.turnRefreshAllocation(2 * time.Second)
		}
	}()
}

// turnSendData sends one datagram to the peer through the
// allocation: ChannelData framing when a channel is bound for
// the peer, a Send indication otherwise.
func (p *Peer) turnSendData(data []byte, peer *net.UDPAddr) {
	if channel, ok := p.turn.channelFor(peer); ok {
		_ = p.turnWrite(p.turn, wrapChannelData(channel, data), true)
		return
	}
	msg := newStunMessage(StunTypeSendIndication)
	msg.addAttr(StunAttrXorPeerAddress, xorAddressValue(peer, msg.TransactionID))
	msg.addAttr(StunAttrData, data)
	_ = p.turnWrite(p.turn, msg.Encode(nil), false)
}

// turnUnwrapData extracts (peer, payload) from a Data indication.
func turnUnwrapData(msg *StunMessage) (*net.UDPAddr, []byte) {
	peer := decodeXorAddressAttr(msg, StunAttrXorPeerAddress)
	data := msg.attr(StunAttrData)
	if peer == nil || data == nil {
		return nil, nil
	}
	return peer, data
}
