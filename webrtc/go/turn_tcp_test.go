package dcwebrtc

// TURN over TCP/TLS (RFC 5766 section 4): the allocation runs
// over a dedicated stream connection while relayed traffic
// still reaches peers over UDP. The fake below is a compact
// stream counterpart of fakeTurnServer (turn_test.go): same
// 401 long-term-credential dance and permission enforcement,
// framed messages instead of datagrams (ChannelData padded to
// a 4-byte boundary).

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/md5"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"io"
	"math/big"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

type streamAlloc struct {
	conn        net.Conn
	writeMu     sync.Mutex
	relayed     *net.UDPAddr
	permissions map[string]bool
	channels    map[uint16]string // channel -> peer addr
	peerChan    map[string]uint16 // peer addr -> channel
}

func (a *streamAlloc) write(frame []byte, channelData bool) {
	if channelData {
		if pad := (4 - len(frame)%4) % 4; pad > 0 {
			padded := make([]byte, len(frame)+pad)
			copy(padded, frame)
			frame = padded
		}
	}
	a.writeMu.Lock()
	_, _ = a.conn.Write(frame)
	a.writeMu.Unlock()
}

type fakeStreamTurn struct {
	listener net.Listener
	realm    string
	nonce    string
	user     string
	pass     string

	mu         sync.Mutex
	nextPort   int
	byRelay    map[string]*streamAlloc
	permCount  int
	bindCount  int
	chanData   int
	refreshCnt int
}

func (f *fakeStreamTurn) key() []byte {
	sum := md5.Sum([]byte(f.user + ":" + f.realm + ":" + f.pass))
	return sum[:]
}

func (f *fakeStreamTurn) authorized(msg *StunMessage, raw []byte) bool {
	if string(msg.attr(StunAttrUsername)) != f.user {
		return false
	}
	return msg.CheckIntegrity(raw, f.key())
}

func (f *fakeStreamTurn) stats() (perms, binds, chanData int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.permCount, f.bindCount, f.chanData
}

func fakeStreamTurnWith(t *testing.T, listener net.Listener) (*fakeStreamTurn, string) {
	t.Helper()
	f := &fakeStreamTurn{
		listener: listener,
		realm:    "dc.test",
		nonce:    "nonce-42",
		user:     "dcuser",
		pass:     "dcpass",
		nextPort: 51100,
		byRelay:  map[string]*streamAlloc{},
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go f.serveConn(conn)
		}
	}()
	return f, listener.Addr().String()
}

func fakeTurnTCP(t *testing.T) (*fakeStreamTurn, string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return fakeStreamTurnWith(t, listener)
}

func fakeTurnTLS(t *testing.T) (*fakeStreamTurn, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "localhost"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		IsCA:         true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		MinVersion:   tls.VersionTLS12,
	})
	if err != nil {
		t.Fatal(err)
	}
	return fakeStreamTurnWith(t, listener)
}

func (f *fakeStreamTurn) serveConn(conn net.Conn) {
	defer conn.Close()
	alloc := &streamAlloc{
		conn:        conn,
		permissions: map[string]bool{},
		channels:    map[uint16]string{},
		peerChan:    map[string]uint16{},
	}
	reader := bufio.NewReader(conn)
	for {
		first, err := reader.Peek(1)
		if err != nil {
			return
		}
		if first[0] >= 0x40 && first[0] <= 0x7f {
			header := make([]byte, 4)
			if _, err := io.ReadFull(reader, header); err != nil {
				return
			}
			length := int(binary.BigEndian.Uint16(header[2:4]))
			total := 4 + length
			rest := make([]byte, total-4+(4-total%4)%4)
			if _, err := io.ReadFull(reader, rest); err != nil {
				return
			}
			channel := binary.BigEndian.Uint16(header[0:2])
			f.onChannelData(alloc, channel, rest[:length])
			continue
		}
		header := make([]byte, 20)
		if _, err := io.ReadFull(reader, header); err != nil {
			return
		}
		length := int(binary.BigEndian.Uint16(header[2:4]))
		body := make([]byte, length)
		if _, err := io.ReadFull(reader, body); err != nil {
			return
		}
		raw := append(header, body...)
		msg := DecodeStun(raw)
		if msg == nil {
			continue
		}
		switch msg.Type {
		case StunTypeAllocateRequest:
			f.onAllocate(alloc, msg, raw)
		case StunTypeRefreshRequest:
			if f.authorized(msg, raw) {
				f.mu.Lock()
				f.refreshCnt++
				f.mu.Unlock()
				resp := &StunMessage{Type: StunTypeRefreshSuccess, TransactionID: msg.TransactionID}
				resp.addAttr(StunAttrLifetime, []byte{0, 0, 2, 88}) // 600
				alloc.write(resp.Encode(f.key()), false)
			}
		case StunTypeCreatePermissionRequest:
			f.onCreatePermission(alloc, msg, raw)
		case StunTypeChannelBindRequest:
			f.onChannelBind(alloc, msg, raw)
		case StunTypeSendIndication:
			if peer, data := turnUnwrapData(msg); data != nil {
				f.deliver(alloc, peer, data)
			}
		}
	}
}

func (f *fakeStreamTurn) onAllocate(alloc *streamAlloc, msg *StunMessage, raw []byte) {
	if msg.attr(StunAttrUsername) == nil || !f.authorized(msg, raw) {
		resp := &StunMessage{Type: StunTypeAllocateError, TransactionID: msg.TransactionID}
		resp.addAttr(StunAttrErrorCode, []byte{0, 0, 4, 1})
		resp.addAttr(StunAttrRealm, []byte(f.realm))
		resp.addAttr(StunAttrNonce, []byte(f.nonce))
		alloc.write(resp.Encode(nil), false)
		return
	}
	f.mu.Lock()
	f.nextPort++
	alloc.relayed = &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: f.nextPort}
	f.byRelay[alloc.relayed.String()] = alloc
	f.mu.Unlock()
	remote := alloc.conn.RemoteAddr().(*net.TCPAddr)
	mapped := &net.UDPAddr{IP: remote.IP, Port: remote.Port}
	resp := &StunMessage{Type: StunTypeAllocateSuccess, TransactionID: msg.TransactionID}
	resp.addAttr(StunAttrXorRelayedAddress, xorAddressValue(alloc.relayed, resp.TransactionID))
	resp.addAttr(StunAttrXorMappedAddress, xorAddressValue(mapped, resp.TransactionID))
	resp.addAttr(StunAttrLifetime, []byte{0, 0, 2, 88}) // 600
	alloc.write(resp.Encode(f.key()), false)
}

func (f *fakeStreamTurn) onCreatePermission(alloc *streamAlloc, msg *StunMessage, raw []byte) {
	if !f.authorized(msg, raw) {
		return
	}
	f.mu.Lock()
	for _, peer := range decodeAllXorPeers(msg) {
		alloc.permissions[peer.String()] = true
	}
	f.permCount++
	f.mu.Unlock()
	resp := &StunMessage{Type: StunTypeCreatePermissionSuccess, TransactionID: msg.TransactionID}
	alloc.write(resp.Encode(f.key()), false)
}

func decodeAllXorPeers(msg *StunMessage) []*net.UDPAddr {
	var out []*net.UDPAddr
	for _, attr := range msg.attrs {
		if attr.typ != StunAttrXorPeerAddress {
			continue
		}
		if addr := decodeXorAddress(attr.value, msg.TransactionID, true); addr != nil {
			out = append(out, addr)
		}
	}
	return out
}

func (f *fakeStreamTurn) onChannelBind(alloc *streamAlloc, msg *StunMessage, raw []byte) {
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
	alloc.channels[channel] = peer.String()
	alloc.peerChan[peer.String()] = channel
	alloc.permissions[peer.String()] = true // binding installs the permission
	f.bindCount++
	f.mu.Unlock()
	resp := &StunMessage{Type: StunTypeChannelBindSuccess, TransactionID: msg.TransactionID}
	alloc.write(resp.Encode(f.key()), false)
}

func (f *fakeStreamTurn) onChannelData(sender *streamAlloc, channel uint16, data []byte) {
	f.mu.Lock()
	peerKey, ok := sender.channels[channel]
	f.mu.Unlock()
	if !ok {
		return
	}
	peer, err := net.ResolveUDPAddr("udp", peerKey)
	if err != nil {
		return
	}
	if f.deliver(sender, peer, data) {
		f.mu.Lock()
		f.chanData++
		f.mu.Unlock()
	}
}

// deliver relays data to the allocation owning destRelayed when
// the destination holds a permission for the sender's relayed
// address: ChannelData when it bound a channel, else a Data
// indication. Returns whether the payload was forwarded.
func (f *fakeStreamTurn) deliver(sender *streamAlloc, destRelayed *net.UDPAddr, data []byte) bool {
	f.mu.Lock()
	dest := f.byRelay[destRelayed.String()]
	allowed := dest != nil && sender.relayed != nil && dest.permissions[sender.relayed.String()]
	var channel uint16
	var hasChannel bool
	if allowed {
		channel, hasChannel = dest.peerChan[sender.relayed.String()]
	}
	f.mu.Unlock()
	if !allowed {
		return false
	}
	if hasChannel {
		dest.write(wrapChannelData(channel, data), true)
	} else {
		ind := newStunMessage(StunTypeDataIndication)
		ind.addAttr(StunAttrXorPeerAddress, xorAddressValue(sender.relayed, ind.TransactionID))
		ind.addAttr(StunAttrData, data)
		dest.write(ind.Encode(nil), false)
	}
	return true
}

func streamRelayConnect(t *testing.T, fake *fakeStreamTurn, serverAddr string, cfgFn func(*TurnServerConfig)) {
	t.Helper()
	newRelayPeer := func() *Peer {
		cfg := TurnServerConfig{Address: serverAddr, Username: "dcuser", Password: "dcpass"}
		cfgFn(&cfg)
		peer, err := NewPeer(PeerOptions{
			RequirePeerCertificate: false,
			LocalIPs:               []string{"10.11.12.13"},
			TurnServers:            []TurnServerConfig{cfg},
		})
		if err != nil {
			t.Fatal(err)
		}
		return peer
	}
	offerer := newRelayPeer()
	defer offerer.Close()
	answerer := newRelayPeer()
	defer answerer.Close()

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
	done := make(chan string, 1)
	resA.ep.SetOnChannel(func(ch *DataChannel) {
		ch.OnMessage(func(data []byte, isText bool) { done <- string(data) })
	})
	out := resB.ep.OpenChannel(DefaultChannelParams("echo"))
	out.Send([]byte("via-stream-relay"))
	select {
	case text := <-done:
		if text != "via-stream-relay" {
			t.Fatalf("got %q", text)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for message over stream TURN relay")
	}
	perms, binds, chanData := fake.stats()
	if perms < 2 || binds < 2 {
		t.Fatalf("permissions=%d binds=%d, want both >= 2", perms, binds)
	}
	if chanData == 0 {
		t.Fatal("no ChannelData relayed over the stream")
	}
}

func TestTurnTCPRelayConnect(t *testing.T) {
	fake, addr := fakeTurnTCP(t)
	streamRelayConnect(t, fake, addr, func(cfg *TurnServerConfig) {
		cfg.Transport = "tcp"
	})
}

func TestTurnTLSRelayConnect(t *testing.T) {
	fake, addr := fakeTurnTLS(t)
	streamRelayConnect(t, fake, addr, func(cfg *TurnServerConfig) {
		cfg.Transport = "tls"
		cfg.InsecureSkipVerify = true
	})
}

func TestTurnTCPBadPasswordFails(t *testing.T) {
	_, addr := fakeTurnTCP(t)
	peer, err := NewPeer(PeerOptions{
		RequirePeerCertificate: false,
		LocalIPs:               []string{"127.0.0.1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	err = peer.AllocateTurn(TurnServerConfig{
		Address: addr, Username: "dcuser", Password: "wrong", Transport: "tcp",
	}, 2*time.Second)
	if err == nil {
		t.Fatal("allocate with bad password succeeded")
	}
	if peer.turn != nil {
		t.Fatal("failed allocate left a dead TURN client installed")
	}
}
