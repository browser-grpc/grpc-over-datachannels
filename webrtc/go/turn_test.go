package dcwebrtc

import (
	"crypto/md5"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Fake TURN server (test fixture): Allocate with the long-term
// credential 401 dance, CreatePermission, and Send/Data-indication
// relaying between allocations, plus direct delivery to relayed
// ports for non-TURN senders.
// ---------------------------------------------------------------------------

type fakeTurnAlloc struct {
	client      *net.UDPAddr
	relayed     *net.UDPAddr
	relayConn   *net.UDPConn
	permissions map[string]time.Time // peer addr -> permission expiry
	expiresAt   time.Time            // allocation expiry
	channels    map[uint16]string    // channel -> peer addr
	peerChan    map[string]uint16    // peer addr -> channel
}

type fakeTurnServer struct {
	conn     *net.UDPConn
	realm    string
	nonce    string
	user     string
	pass     string
	nextPort int
	// Configurable expiries (seconds) so refresh tests run fast.
	lifetimeSeconds   uint32
	permissionSeconds int

	mu           sync.Mutex
	byClient     map[string]*fakeTurnAlloc
	byRelay      map[string]*fakeTurnAlloc
	refreshCount int
	permReqCount int
	bindCount    int
	chanData     int
}

// ChannelStats returns (channel binds, channel-data messages relayed).
func (f *fakeTurnServer) ChannelStats() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.bindCount, f.chanData
}

// Stats returns (refresh requests, create-permission requests).
func (f *fakeTurnServer) Stats() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.refreshCount, f.permReqCount
}

func (f *fakeTurnServer) lifetimeAttr() []byte {
	return []byte{
		byte(f.lifetimeSeconds >> 24), byte(f.lifetimeSeconds >> 16),
		byte(f.lifetimeSeconds >> 8), byte(f.lifetimeSeconds),
	}
}

// liveLocked reports whether an allocation is unexpired (mu held).
func liveLocked(alloc *fakeTurnAlloc) bool {
	return alloc != nil && time.Now().Before(alloc.expiresAt)
}

// permOKLocked reports an unexpired permission for addr (mu held).
func permOKLocked(alloc *fakeTurnAlloc, addr string) bool {
	expiry, ok := alloc.permissions[addr]
	return ok && time.Now().Before(expiry)
}

func (f *fakeTurnServer) key() []byte {
	sum := md5.Sum([]byte(f.user + ":" + f.realm + ":" + f.pass))
	return sum[:]
}

func (f *fakeTurnServer) authorized(msg *StunMessage, raw []byte) bool {
	if string(msg.attr(StunAttrUsername)) != f.user {
		return false
	}
	return msg.CheckIntegrity(raw, f.key())
}

func fakeTurn(t *testing.T) (*fakeTurnServer, string) {
	return fakeTurnWith(t, 600, 300)
}

// fakeTurnWith starts a fake whose allocations live
// lifetimeSeconds and whose permissions live permissionSeconds,
// both enforced, so client refresh behavior is observable.
func fakeTurnWith(t *testing.T, lifetimeSeconds uint32, permissionSeconds int) (*fakeTurnServer, string) {
	t.Helper()
	addr, err := net.ResolveUDPAddr("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.ListenUDP("udp4", addr)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeTurnServer{
		conn:              conn,
		realm:             "dc.test",
		nonce:             "nonce-42",
		user:              "dcuser",
		pass:              "dcpass",
		nextPort:          50100,
		byClient:          map[string]*fakeTurnAlloc{},
		byRelay:           map[string]*fakeTurnAlloc{},
		lifetimeSeconds:   lifetimeSeconds,
		permissionSeconds: permissionSeconds,
	}
	t.Cleanup(func() { conn.Close() })
	go f.serve()
	return f, conn.LocalAddr().String()
}

func (f *fakeTurnServer) serve() {
	buf := make([]byte, 65536)
	for {
		n, src, err := f.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		raw := append([]byte{}, buf[:n]...)
		if len(raw) >= 4 && raw[0] >= 0x40 && raw[0] <= 0x7f {
			f.onChannelData(raw, src)
			continue
		}
		msg := DecodeStun(raw)
		if msg == nil {
			continue
		}
		switch msg.Type {
		case StunTypeAllocateRequest:
			f.onAllocate(msg, raw, src)
		case StunTypeRefreshRequest:
			f.onRefresh(msg, raw, src)
		case StunTypeChannelBindRequest:
			f.onChannelBind(msg, raw, src)
		case StunTypeCreatePermissionRequest:
			f.onCreatePermission(msg, raw, src)
		case StunTypeSendIndication:
			f.onSend(msg, src)
		}
	}
}

func (f *fakeTurnServer) onAllocate(msg *StunMessage, raw []byte, src *net.UDPAddr) {
	if msg.attr(StunAttrUsername) == nil {
		resp := &StunMessage{Type: StunTypeAllocateError, TransactionID: msg.TransactionID}
		resp.addAttr(StunAttrErrorCode, []byte{0, 0, 4, 1})
		resp.addAttr(StunAttrRealm, []byte(f.realm))
		resp.addAttr(StunAttrNonce, []byte(f.nonce))
		_, _ = f.conn.WriteToUDP(resp.Encode(nil), src)
		return
	}
	if !f.authorized(msg, raw) {
		resp := &StunMessage{Type: StunTypeAllocateError, TransactionID: msg.TransactionID}
		resp.addAttr(StunAttrErrorCode, []byte{0, 0, 4, 1})
		resp.addAttr(StunAttrRealm, []byte(f.realm))
		resp.addAttr(StunAttrNonce, []byte(f.nonce))
		_, _ = f.conn.WriteToUDP(resp.Encode(nil), src)
		return
	}
	alloc := &fakeTurnAlloc{
		client:      src,
		permissions: map[string]time.Time{},
		expiresAt:   time.Now().Add(time.Duration(f.lifetimeSeconds) * time.Second),
		channels:    map[uint16]string{},
		peerChan:    map[string]uint16{},
	}
	f.mu.Lock()
	f.byClient[src.String()] = alloc
	f.mu.Unlock()
	// Ephemeral relay port: fixed ports collide when several
	// fake servers live in one test process.
	relayed := f.listenRelay(alloc)
	if relayed == nil {
		return
	}
	f.mu.Lock()
	f.byRelay[relayed.String()] = alloc
	f.mu.Unlock()

	resp := &StunMessage{Type: StunTypeAllocateSuccess, TransactionID: msg.TransactionID}
	resp.addAttr(StunAttrXorRelayedAddress, xorAddressValue(relayed, resp.TransactionID))
	resp.addAttr(StunAttrXorMappedAddress, xorAddressValue(src, resp.TransactionID))
	resp.addAttr(StunAttrLifetime, f.lifetimeAttr())
	_, _ = f.conn.WriteToUDP(resp.Encode(f.key()), src)
}

func (f *fakeTurnServer) onRefresh(msg *StunMessage, raw []byte, src *net.UDPAddr) {
	f.mu.Lock()
	alloc := f.byClient[src.String()]
	f.mu.Unlock()
	if !f.authorized(msg, raw) {
		return
	}
	f.mu.Lock()
	if !liveLocked(alloc) {
		f.mu.Unlock()
		resp := &StunMessage{Type: StunTypeRefreshError, TransactionID: msg.TransactionID}
		resp.addAttr(StunAttrErrorCode, []byte{0, 0, 4, 37}) // 437 Allocation Mismatch
		_, _ = f.conn.WriteToUDP(resp.Encode(f.key()), src)
		return
	}
	alloc.expiresAt = time.Now().Add(time.Duration(f.lifetimeSeconds) * time.Second)
	f.refreshCount++
	f.mu.Unlock()
	resp := &StunMessage{Type: StunTypeRefreshSuccess, TransactionID: msg.TransactionID}
	resp.addAttr(StunAttrLifetime, f.lifetimeAttr())
	_, _ = f.conn.WriteToUDP(resp.Encode(f.key()), src)
}

// listenRelay forwards direct UDP arrivals at the relayed port to
// the allocation owner as Data indications (the peer needs a
// permission for the sender, as on the Send path).
func (f *fakeTurnServer) onChannelBind(msg *StunMessage, raw []byte, src *net.UDPAddr) {
	if !f.authorized(msg, raw) {
		return
	}
	chanValue := msg.attr(StunAttrChannelNumber)
	peer := decodeXorAddressAttr(msg, StunAttrXorPeerAddress)
	if len(chanValue) < 2 || peer == nil {
		return
	}
	channel := uint16(chanValue[0])<<8 | uint16(chanValue[1])
	f.mu.Lock()
	alloc := f.byClient[src.String()]
	if !liveLocked(alloc) {
		f.mu.Unlock()
		return
	}
	// A binding also installs the permission (RFC 5766 §9).
	alloc.channels[channel] = peer.String()
	alloc.peerChan[peer.String()] = channel
	alloc.permissions[peer.String()] =
		time.Now().Add(time.Duration(f.permissionSeconds) * time.Second)
	if relayCopy := f.byRelay[alloc.relayed.String()]; relayCopy != nil {
		relayCopy.channels[channel] = peer.String()
		relayCopy.peerChan[peer.String()] = channel
		relayCopy.permissions[peer.String()] = alloc.permissions[peer.String()]
	}
	f.bindCount++
	f.mu.Unlock()
	resp := &StunMessage{Type: StunTypeChannelBindSuccess, TransactionID: msg.TransactionID}
	_, _ = f.conn.WriteToUDP(resp.Encode(f.key()), src)
}

// deliverLocked sends payload to dest's client, as ChannelData
// when dest bound a channel to the sender address, else as a
// Data indication. Caller holds f.mu and has checked permission.
func (f *fakeTurnServer) deliver(dest *fakeTurnAlloc, senderAddr *net.UDPAddr, data []byte) {
	if channel, ok := dest.peerChan[senderAddr.String()]; ok {
		_, _ = f.conn.WriteToUDP(wrapChannelData(channel, data), dest.client)
		return
	}
	ind := newStunMessage(StunTypeDataIndication)
	ind.addAttr(StunAttrXorPeerAddress, xorAddressValue(senderAddr, ind.TransactionID))
	ind.addAttr(StunAttrData, data)
	_, _ = f.conn.WriteToUDP(ind.Encode(nil), dest.client)
}

func (f *fakeTurnServer) onChannelData(raw []byte, src *net.UDPAddr) {
	channel, data, ok := unwrapChannelData(raw)
	if !ok {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	sender := f.byClient[src.String()]
	if !liveLocked(sender) {
		return
	}
	peerKey, bound := sender.channels[channel]
	if !bound {
		return
	}
	dest := f.byRelay[peerKey]
	if dest == nil {
		// Direct (non-TURN) peer: deliver from the relay socket.
		if liveLocked(sender) && sender.relayConn != nil {
			if peer, err := net.ResolveUDPAddr("udp", peerKey); err == nil {
				_, _ = sender.relayConn.WriteToUDP(data, peer)
			}
		}
		return
	}
	if !liveLocked(dest) || !permOKLocked(dest, sender.relayed.String()) {
		return
	}
	f.chanData++
	f.deliver(dest, sender.relayed, data)
}

func (f *fakeTurnServer) listenRelay(alloc *fakeTurnAlloc) *net.UDPAddr {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		return nil
	}
	alloc.relayed = conn.LocalAddr().(*net.UDPAddr)
	alloc.relayConn = conn
	go func() {
		defer conn.Close()
		buf := make([]byte, 65536)
		for {
			n, src, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			data := append([]byte{}, buf[:n]...)
			f.mu.Lock()
			if liveLocked(alloc) && permOKLocked(alloc, src.String()) {
				f.deliver(alloc, src, data)
			}
			f.mu.Unlock()
		}
	}()
	return alloc.relayed
}

func (f *fakeTurnServer) onCreatePermission(msg *StunMessage, raw []byte, src *net.UDPAddr) {
	f.mu.Lock()
	alloc := f.byClient[src.String()]
	f.mu.Unlock()
	if alloc == nil || !f.authorized(msg, raw) {
		return
	}
	f.mu.Lock()
	f.permReqCount++
	expiry := time.Now().Add(time.Duration(f.permissionSeconds) * time.Second)
	for _, a := range msg.attrs {
		if a.typ != StunAttrXorPeerAddress {
			continue
		}
		probe := &StunMessage{Type: msg.Type, TransactionID: msg.TransactionID}
		probe.addAttr(StunAttrXorPeerAddress, a.value)
		if peer := decodeXorAddressAttr(probe, StunAttrXorPeerAddress); peer != nil {
			alloc.permissions[peer.String()] = expiry
		}
	}
	f.mu.Unlock()
	resp := &StunMessage{Type: StunTypeCreatePermissionSuccess, TransactionID: msg.TransactionID}
	_, _ = f.conn.WriteToUDP(resp.Encode(f.key()), src)
}

func (f *fakeTurnServer) onSend(msg *StunMessage, src *net.UDPAddr) {
	peer := decodeXorAddressAttr(msg, StunAttrXorPeerAddress)
	data := msg.attr(StunAttrData)
	if peer == nil || data == nil {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	sender := f.byClient[src.String()]
	dest := f.byRelay[peer.String()]
	if dest == nil {
		// Direct (non-TURN) peer: deliver from the relay socket.
		if liveLocked(sender) && sender.relayConn != nil {
			_, _ = sender.relayConn.WriteToUDP(data, peer)
		}
		return
	}
	if !liveLocked(sender) || !liveLocked(dest) ||
		!permOKLocked(dest, sender.relayed.String()) {
		return
	}
	f.deliver(dest, sender.relayed, data)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestAllocateTurnGathersRelayCandidate(t *testing.T) {
	_, serverAddr := fakeTurn(t)
	peer, err := NewPeer(PeerOptions{
		RequirePeerCertificate: false,
		LocalIPs:               []string{"127.0.0.1"},
		TurnServers:            []TurnServerConfig{{Address: serverAddr, Username: "dcuser", Password: "dcpass"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := peer.AllocateTurn(peer.options.TurnServers[0], 2*time.Second); err != nil {
		t.Fatal(err)
	}
	var relay *Candidate
	for i := range peer.agent.LocalCandidates {
		if peer.agent.LocalCandidates[i].Type == "relay" {
			relay = &peer.agent.LocalCandidates[i]
		}
	}
	if relay == nil {
		t.Fatalf("no relay candidate in %v", peer.agent.LocalCandidates)
	}
	if relay.Priority>>24 != 0 {
		t.Fatalf("relay priority type bits = %d, want 0", relay.Priority>>24)
	}
	sdp := relay.ToSDP()
	if !strings.Contains(sdp, "typ relay") || !strings.Contains(sdp, "raddr 127.0.0.1") {
		t.Fatalf("relay SDP = %q", sdp)
	}
	parsed := CandidateFromSDP(strings.TrimPrefix(sdp, "a="))
	if parsed == nil || parsed.Type != "relay" {
		t.Fatalf("parsed = %+v", parsed)
	}
	fmt.Println("relay candidate:", sdp)
}

func TestAllocateTurnBadPasswordFails(t *testing.T) {
	_, serverAddr := fakeTurn(t)
	peer, err := NewPeer(PeerOptions{
		RequirePeerCertificate: false,
		LocalIPs:               []string{"127.0.0.1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg := TurnServerConfig{Address: serverAddr, Username: "dcuser", Password: "wrong"}
	if err := peer.AllocateTurn(cfg, 2*time.Second); err == nil {
		t.Fatal("allocate with a bad password succeeded")
	}
	for _, cand := range peer.agent.LocalCandidates {
		if cand.Type == "relay" {
			t.Fatal("relay candidate gathered despite failed allocate")
		}
	}
}

func TestTurnRelayOfferAnswerConnect(t *testing.T) {
	_, serverAddr := fakeTurn(t)
	newRelayPeer := func() *Peer {
		// The advertised host address is deliberately unreachable,
		// so a successful connection can only have flowed through
		// the TURN relay.
		peer, err := NewPeer(PeerOptions{
			RequirePeerCertificate: false,
			LocalIPs:               []string{"10.11.12.13"},
			TurnServers:            []TurnServerConfig{{Address: serverAddr, Username: "dcuser", Password: "dcpass"}},
		})
		if err != nil {
			t.Fatal(err)
		}
		return peer
	}
	offerer := newRelayPeer()
	answerer := newRelayPeer()

	offer := offerer.CreateOffer()
	if !strings.Contains(offer, "typ relay") {
		t.Fatalf("offer has no relay candidate:\n%s", offer)
	}
	answer, err := answerer.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(answer, "typ relay") {
		t.Fatalf("answer has no relay candidate:\n%s", answer)
	}
	if err := offerer.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}
	type connResult struct {
		ep  *DcEndpoint
		err error
	}
	connA := make(chan connResult, 1)
	connB := make(chan connResult, 1)
	go func() {
		ep, err := offerer.ConnectWithOptions(true)
		connA <- connResult{ep, err}
	}()
	go func() {
		ep, err := answerer.ConnectWithOptions(false)
		connB <- connResult{ep, err}
	}()
	resA := <-connA
	if resA.err != nil {
		t.Fatal(resA.err)
	}
	resB := <-connB
	if resB.err != nil {
		t.Fatal(resB.err)
	}
	epA, epB := resA.ep, resB.ep
	done := make(chan string, 1)
	epA.SetOnChannel(func(ch *DataChannel) {
		ch.OnMessage(func(data []byte, isText bool) {
			done <- string(data)
		})
	})
	out := epB.OpenChannel(DefaultChannelParams("echo"))
	out.Send([]byte("via-relay"))
	select {
	case text := <-done:
		if text != "via-relay" {
			t.Fatalf("got %q", text)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for message over TURN-relayed peers")
	}
}

// Candidates trickled in after Connect's snapshot must still
// get TURN permissions and channel bindings. The only reachable
// candidate on each side is the relay candidate, withheld from
// the SDP and trickled in while Connect is running; the fake
// enforces permissions, so the message only flows if trickle
// created them.
func TestTurnRelayWithTrickledRelayCandidates(t *testing.T) {
	fake, serverAddr := fakeTurn(t)
	newRelayPeer := func() *Peer {
		peer, err := NewPeer(PeerOptions{
			RequirePeerCertificate: false,
			LocalIPs:               []string{"10.11.12.13"},
			TurnServers:            []TurnServerConfig{{Address: serverAddr, Username: "dcuser", Password: "dcpass"}},
		})
		if err != nil {
			t.Fatal(err)
		}
		return peer
	}
	relayLine := func(sdp string) string {
		for _, line := range strings.Split(sdp, "\r\n") {
			if strings.Contains(line, "typ relay") {
				return line
			}
		}
		return ""
	}
	stripRelay := func(sdp string) string {
		var keep []string
		for _, line := range strings.Split(sdp, "\r\n") {
			if !strings.Contains(line, "typ relay") {
				keep = append(keep, line)
			}
		}
		return strings.Join(keep, "\r\n")
	}
	offerer := newRelayPeer()
	defer offerer.Close()
	answerer := newRelayPeer()
	defer answerer.Close()

	offer := offerer.CreateOffer()
	offerRelay := relayLine(offer)
	if offerRelay == "" {
		t.Fatalf("offer has no relay candidate:\n%s", offer)
	}
	answer, err := answerer.HandleOffer(stripRelay(offer))
	if err != nil {
		t.Fatal(err)
	}
	answerRelay := relayLine(answer)
	if answerRelay == "" {
		t.Fatalf("answer has no relay candidate:\n%s", answer)
	}
	if err := offerer.HandleAnswer(stripRelay(answer)); err != nil {
		t.Fatal(err)
	}
	type connResult struct {
		ep  *DcEndpoint
		err error
	}
	connA := make(chan connResult, 1)
	connB := make(chan connResult, 1)
	go func() {
		ep, err := offerer.ConnectWithOptions(true)
		connA <- connResult{ep, err}
	}()
	go func() {
		ep, err := answerer.ConnectWithOptions(false)
		connB <- connResult{ep, err}
	}()
	// Trickle only after Connect has snapshotted the
	// SDP-carried candidates.
	time.Sleep(250 * time.Millisecond)
	if !answerer.AddRemoteCandidate(offerRelay) {
		t.Fatal("answerer rejected trickled relay candidate")
	}
	if !offerer.AddRemoteCandidate(answerRelay) {
		t.Fatal("offerer rejected trickled relay candidate")
	}
	resA := <-connA
	if resA.err != nil {
		t.Fatal(resA.err)
	}
	resB := <-connB
	if resB.err != nil {
		t.Fatal(resB.err)
	}
	epA, epB := resA.ep, resB.ep
	done := make(chan string, 1)
	epA.SetOnChannel(func(ch *DataChannel) {
		ch.OnMessage(func(data []byte, isText bool) {
			done <- string(data)
		})
	})
	out := epB.OpenChannel(DefaultChannelParams("echo"))
	out.Send([]byte("trickled-relay"))
	select {
	case text := <-done:
		if text != "trickled-relay" {
			t.Fatalf("got %q", text)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for message over trickled TURN relay")
	}
	fake.mu.Lock()
	perms, binds := fake.permReqCount, fake.bindCount
	fake.mu.Unlock()
	if perms < 2 || binds < 2 {
		t.Fatalf("permissions=%d binds=%d, want both >= 2", perms, binds)
	}
}

// With a 3 s allocation/permission lifetime enforced by the fake,
// the relayed channel must still work after 5 s — only possible
// if both peers refresh their allocations and permissions.
func TestTurnRefreshKeepsRelayAlive(t *testing.T) {
	fake, serverAddr := fakeTurnWith(t, 3, 3)
	newRelayPeer := func() *Peer {
		peer, err := NewPeer(PeerOptions{
			RequirePeerCertificate: false,
			LocalIPs:               []string{"10.11.12.13"},
			TurnServers:            []TurnServerConfig{{Address: serverAddr, Username: "dcuser", Password: "dcpass"}},
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(peer.Close)
		return peer
	}
	offerer := newRelayPeer()
	answerer := newRelayPeer()

	offer := offerer.CreateOffer()
	answer, err := answerer.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if err := offerer.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}
	if offerer.turn == nil || offerer.turn.lifetime != 3*time.Second {
		t.Fatalf("offerer lifetime = %v, want 3s", offerer.turn.lifetime)
	}
	type connResult struct {
		ep  *DcEndpoint
		err error
	}
	connA := make(chan connResult, 1)
	connB := make(chan connResult, 1)
	go func() {
		ep, err := offerer.ConnectWithOptions(true)
		connA <- connResult{ep, err}
	}()
	go func() {
		ep, err := answerer.ConnectWithOptions(false)
		connB <- connResult{ep, err}
	}()
	resA := <-connA
	if resA.err != nil {
		t.Fatal(resA.err)
	}
	resB := <-connB
	if resB.err != nil {
		t.Fatal(resB.err)
	}
	epA, epB := resA.ep, resB.ep

	done := make(chan string, 2)
	epA.SetOnChannel(func(ch *DataChannel) {
		ch.OnMessage(func(data []byte, isText bool) {
			done <- string(data)
		})
	})
	out := epB.OpenChannel(DefaultChannelParams("echo"))
	out.Send([]byte("before-expiry"))
	select {
	case text := <-done:
		if text != "before-expiry" {
			t.Fatalf("got %q", text)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for the first relayed message")
	}

	// Both allocations and all permissions would have expired by
	// now without refresh.
	time.Sleep(5 * time.Second)
	out.Send([]byte("after-expiry"))
	select {
	case text := <-done:
		if text != "after-expiry" {
			t.Fatalf("got %q", text)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("relayed message after the original expiry never arrived (refresh broken)")
	}
	refreshes, perms := fake.Stats()
	if refreshes < 2 {
		t.Fatalf("refresh requests = %d, want >= 2 (one per peer)", refreshes)
	}
	if perms < 4 {
		t.Fatalf("create-permission requests = %d, want >= 4 (initial + refresh per peer)", perms)
	}
}

// After a relay-only connect, both peers must have bound
// channels and the fake must have relayed ChannelData frames
// (ICE checks and data ride them once bound).
func TestTurnChannelBindCarriesTraffic(t *testing.T) {
	fake, serverAddr := fakeTurn(t)
	newRelayPeer := func() *Peer {
		peer, err := NewPeer(PeerOptions{
			RequirePeerCertificate: false,
			LocalIPs:               []string{"10.11.12.13"},
			TurnServers:            []TurnServerConfig{{Address: serverAddr, Username: "dcuser", Password: "dcpass"}},
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(peer.Close)
		return peer
	}
	offerer := newRelayPeer()
	answerer := newRelayPeer()
	offer := offerer.CreateOffer()
	answer, err := answerer.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if err := offerer.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}
	type connResult struct {
		ep  *DcEndpoint
		err error
	}
	connA := make(chan connResult, 1)
	connB := make(chan connResult, 1)
	go func() {
		ep, err := offerer.ConnectWithOptions(true)
		connA <- connResult{ep, err}
	}()
	go func() {
		ep, err := answerer.ConnectWithOptions(false)
		connB <- connResult{ep, err}
	}()
	resA, resB := <-connA, <-connB
	if resA.err != nil {
		t.Fatal(resA.err)
	}
	if resB.err != nil {
		t.Fatal(resB.err)
	}
	epA, epB := resA.ep, resB.ep
	done := make(chan string, 1)
	epA.SetOnChannel(func(ch *DataChannel) {
		ch.OnMessage(func(data []byte, isText bool) { done <- string(data) })
	})
	out := epB.OpenChannel(DefaultChannelParams("echo"))
	out.Send([]byte("via-channel"))
	select {
	case text := <-done:
		if text != "via-channel" {
			t.Fatalf("got %q", text)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for channel-relayed message")
	}
	binds, chanData := fake.ChannelStats()
	if binds < 2 {
		t.Fatalf("channel binds = %d, want >= 2 (one per peer)", binds)
	}
	if chanData == 0 {
		t.Fatal("no ChannelData frames relayed; traffic fell back to indications")
	}
}
