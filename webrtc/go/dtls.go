// DTLS 1.2 (RFC 6347) client and server — stdlib only.
// ECDHE-ECDSA with AES-128-GCM-SHA256, extended master secret,
// use_srtp negotiation, certificates pinned by SDP fingerprint.
// Mirrors webrtc/js/dtls.js flight for flight.
package dcwebrtc

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"errors"
	"fmt"
	"math/big"
	"net"
	"strings"
	"sync"
	"time"
)

var dtlsVersion = []byte{0xfe, 0xfd}

const dtlsSuite = 0xc02b
const groupSecp256r1 = 23

func sha256Sum(parts ...[]byte) []byte {
	h := sha256.New()
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

func hmacSha256(key []byte, parts ...[]byte) []byte {
	h := hmac.New(sha256.New, key)
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

// prf is the TLS 1.2 PRF with SHA-256.
func prf(secret []byte, label string, seed []byte, outLen int) []byte {
	fullSeed := append([]byte(label), seed...)
	var out []byte
	a := hmacSha256(secret, fullSeed)
	for len(out) < outLen {
		out = append(out, hmacSha256(secret, a, fullSeed)...)
		a = hmacSha256(secret, a)
	}
	return out[:outLen]
}

// PacketIO transports DTLS records over a packet medium.
type PacketIO interface {
	Send([]byte) error
	Recv(timeoutMs int) []byte // nil on timeout
}

// udpPacketIO adapts a connected UDP socket.
type udpPacketIO struct {
	conn  *net.UDPConn
	queue chan []byte
}

// UDPPacketIO builds a PacketIO over a connected UDP socket.
func UDPPacketIO(conn *net.UDPConn) PacketIO {
	io := &udpPacketIO{conn: conn, queue: make(chan []byte, 64)}
	go func() {
		buf := make([]byte, 65536)
		for {
			n, err := conn.Read(buf)
			if err != nil {
				return
			}
			cp := make([]byte, n)
			copy(cp, buf[:n])
			io.queue <- cp
		}
	}()
	return io
}

func (u *udpPacketIO) Send(buf []byte) error {
	_, err := u.conn.Write(buf)
	return err
}

func (u *udpPacketIO) Recv(timeoutMs int) []byte {
	if timeoutMs <= 0 {
		select {
		case msg := <-u.queue:
			return msg
		default:
			return nil
		}
	}
	select {
	case msg := <-u.queue:
		return msg
	case <-time.After(time.Duration(timeoutMs) * time.Millisecond):
		return nil
	}
}

// Certificate is a self-signed ECDSA P-256 certificate + key.
type Certificate struct {
	DER        []byte
	PrivateKey *ecdsa.PrivateKey
}

// GenerateCertificate creates a self-signed P-256 certificate.
func GenerateCertificate() (*Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "dc-webrtc"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	return &Certificate{DER: der, PrivateKey: key}, nil
}

// Fingerprint returns the SDP fingerprint (SHA-256, colon hex).
func (c *Certificate) Fingerprint() string {
	return FingerprintOfDER(c.DER)
}

// FingerprintOfDER formats a certificate fingerprint for SDP.
func FingerprintOfDER(der []byte) string {
	sum := sha256.Sum256(der)
	parts := make([]string, len(sum))
	for i, b := range sum {
		parts[i] = fmt.Sprintf("%02X", b)
	}
	return strings.Join(parts, ":")
}

type byteReader struct {
	buf []byte
	pos int
}

func (r *byteReader) u8() (byte, error) {
	if r.pos >= len(r.buf) {
		return 0, errors.New("short read")
	}
	v := r.buf[r.pos]
	r.pos++
	return v, nil
}

func (r *byteReader) u16() (uint16, error) {
	hi, err := r.u8()
	if err != nil {
		return 0, err
	}
	lo, err := r.u8()
	return uint16(hi)<<8 | uint16(lo), err
}

func (r *byteReader) u24() (int, error) {
	a, err := r.u8()
	if err != nil {
		return 0, err
	}
	b, err := r.u8()
	if err != nil {
		return 0, err
	}
	c, err := r.u8()
	return int(a)<<16 | int(b)<<8 | int(c), err
}

func (r *byteReader) take(n int) ([]byte, error) {
	if r.pos+n > len(r.buf) {
		return nil, errors.New("short read")
	}
	out := r.buf[r.pos : r.pos+n]
	r.pos += n
	return out, nil
}

func (r *byteReader) vec8() ([]byte, error) {
	n, err := r.u8()
	if err != nil {
		return nil, err
	}
	return r.take(int(n))
}

func (r *byteReader) vec16() ([]byte, error) {
	n, err := r.u16()
	if err != nil {
		return nil, err
	}
	return r.take(int(n))
}

func (r *byteReader) vec24() ([]byte, error) {
	n, err := r.u24()
	if err != nil {
		return nil, err
	}
	return r.take(n)
}

func (r *byteReader) done() bool { return r.pos >= len(r.buf) }

func u24be(v int) []byte {
	return []byte{byte(v >> 16), byte(v >> 8), byte(v)}
}

func handshakeMessage(msgType byte, seq int, body []byte) []byte {
	out := []byte{msgType}
	out = append(out, u24be(len(body))...)
	out = append(out, byte(seq>>8), byte(seq))
	out = append(out, u24be(0)...)
	out = append(out, u24be(len(body))...)
	return append(out, body...)
}

func certListBody(der []byte) []byte {
	entry := append(u24be(len(der)), der...)
	return append(u24be(len(entry)), entry...)
}

func parseFirstCert(body []byte) ([]byte, error) {
	r := &byteReader{buf: body}
	list, err := r.vec24()
	if err != nil {
		return nil, err
	}
	inner := &byteReader{buf: list}
	return inner.vec24()
}

type hsFragment struct {
	total int
	buf   []byte
	have  []bool
}

type hsMessage struct {
	typ  byte
	raw  []byte
	body []byte
}

type handshakeState struct {
	sendSeq     int
	expectSeq   int
	fragments   map[string]*hsFragment
	ready       map[int]hsMessage
	byteBuf     []byte
	transcript  [][]byte
	ccsReceived bool
	pending     [][]byte
}

func newHandshakeState() *handshakeState {
	return &handshakeState{
		fragments: map[string]*hsFragment{},
		ready:     map[int]hsMessage{},
	}
}

func (h *handshakeState) feed(data []byte) {
	h.byteBuf = append(h.byteBuf, data...)
	for {
		if len(h.byteBuf) < 12 {
			return
		}
		msgType := h.byteBuf[0]
		total := int(h.byteBuf[1])<<16 | int(h.byteBuf[2])<<8 | int(h.byteBuf[3])
		seq := int(binary.BigEndian.Uint16(h.byteBuf[4:6]))
		offset := int(h.byteBuf[6])<<16 | int(h.byteBuf[7])<<8 | int(h.byteBuf[8])
		fragLen := int(h.byteBuf[9])<<16 | int(h.byteBuf[10])<<8 | int(h.byteBuf[11])
		if len(h.byteBuf) < 12+fragLen {
			return
		}
		frag := h.byteBuf[12 : 12+fragLen]
		h.byteBuf = h.byteBuf[12+fragLen:]
		key := fmt.Sprintf("%d:%d", msgType, seq)
		entry, ok := h.fragments[key]
		if !ok {
			entry = &hsFragment{total: total, buf: make([]byte, total), have: make([]bool, total)}
			h.fragments[key] = entry
		}
		copy(entry.buf[offset:], frag)
		for i := offset; i < offset+len(frag) && i < len(entry.have); i++ {
			entry.have[i] = true
		}
		complete := true
		for _, have := range entry.have {
			if !have {
				complete = false
				break
			}
		}
		if complete {
			delete(h.fragments, key)
			body := make([]byte, len(entry.buf))
			copy(body, entry.buf)
			h.ready[seq] = hsMessage{typ: msgType, raw: handshakeMessage(msgType, seq, body), body: body}
		}
	}
}

func (h *handshakeState) next() *hsMessage {
	msg, ok := h.ready[h.expectSeq]
	if !ok {
		return nil
	}
	delete(h.ready, h.expectSeq)
	h.expectSeq++
	return &msg
}

func (h *handshakeState) hash() []byte {
	hh := sha256.New()
	for _, raw := range h.transcript {
		hh.Write(raw)
	}
	return hh.Sum(nil)
}

func (h *handshakeState) bytes() []byte {
	var out []byte
	for _, raw := range h.transcript {
		out = append(out, raw...)
	}
	return out
}

type recordKeys struct {
	key  []byte
	salt []byte
	gcm  cipher.AEAD
}

func newRecordKeys(key, salt []byte) (*recordKeys, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &recordKeys{key: key, salt: salt, gcm: gcm}, nil
}

// errKeysPending reports that a datagram's tail holds epoch-1
// records but the record keys do not exist yet.
var errKeysPending = errors.New("epoch-1 records await handshake keys")

type dtlsRecord struct {
	contentType byte
	epoch       int
	sequence    uint64
	body        []byte
}

// DtlsConnection is an established (or establishing) DTLS association.
type DtlsConnection struct {
	// sendMu serializes sendRecord: sequence numbers and the
	// AEAD nonce are per-connection state, but SendApp runs on
	// the pump goroutine and application goroutines alike.
	sendMu       sync.Mutex
	io           PacketIO
	role         string
	writeKeys    *recordKeys
	readKeys     *recordKeys
	writeSeq     uint64
	epoch0Seq    uint64
	masterSecret []byte
	clientRandom []byte
	serverRandom []byte
	peerCertDER  []byte
	srtpProfile  int // -1 when none
	readHighest  int64
	readWindow   uint64
}

// DtlsConfig configures a handshake.
type DtlsConfig struct {
	Certificate             *Certificate
	ExpectedPeerFingerprint string
	RequirePeerCertificate  bool
}

// PeerFingerprint returns the peer certificate's SDP fingerprint.
func (c *DtlsConnection) PeerFingerprint() string {
	if c.peerCertDER == nil {
		return ""
	}
	return FingerprintOfDER(c.peerCertDER)
}

// SrtpProfile returns the negotiated SRTP profile (-1 when none).
func (c *DtlsConnection) SrtpProfile() int { return c.srtpProfile }

// ExportKeyingMaterial runs the TLS exporter for label.
func (c *DtlsConnection) ExportKeyingMaterial(label string, context []byte, length int) []byte {
	seed := append(append(append([]byte{}, c.clientRandom...), c.serverRandom...), context...)
	return prf(c.masterSecret, label, seed, length)
}

func seq48(seq uint64) []byte {
	out := make([]byte, 6)
	for i := 5; i >= 0; i-- {
		out[i] = byte(seq)
		seq >>= 8
	}
	return out
}

func (c *DtlsConnection) sendRecord(contentType byte, epoch int, body []byte) ([]byte, error) {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	var packet []byte
	if epoch == 0 {
		seq := c.epoch0Seq
		c.epoch0Seq++
		packet = append(packet, contentType)
		packet = append(packet, dtlsVersion...)
		packet = append(packet, 0, 0)
		packet = append(packet, seq48(seq)...)
		packet = append(packet, byte(len(body)>>8), byte(len(body)))
		packet = append(packet, body...)
	} else {
		seq := c.writeSeq
		c.writeSeq++
		explicit := append([]byte{0, 1}, seq48(seq)...)
		nonce := append(append([]byte{}, c.writeKeys.salt...), explicit...)
		aad := append(append([]byte{}, explicit...), contentType)
		aad = append(aad, dtlsVersion...)
		aad = append(aad, byte(len(body)>>8), byte(len(body)))
		sealed := c.writeKeys.gcm.Seal(nil, nonce, body, aad)
		packet = append(packet, contentType)
		packet = append(packet, dtlsVersion...)
		packet = append(packet, 0, 1)
		packet = append(packet, seq48(seq)...)
		total := 8 + len(sealed)
		packet = append(packet, byte(total>>8), byte(total))
		packet = append(packet, explicit...)
		packet = append(packet, sealed...)
	}
	if err := c.io.Send(packet); err != nil {
		return nil, err
	}
	return packet, nil
}

func (c *DtlsConnection) parseRecords(packet []byte) ([]dtlsRecord, error) {
	var records []dtlsRecord
	offset := 0
	for offset < len(packet) {
		r := &byteReader{buf: packet[offset:]}
		contentType, err := r.u8()
		if err != nil {
			return records, err
		}
		if _, err := r.u8(); err != nil {
			return records, err
		}
		if _, err := r.u8(); err != nil {
			return records, err
		}
		epoch, err := r.u16()
		if err != nil {
			return records, err
		}
		seqBytes, err := r.take(6)
		if err != nil {
			return records, err
		}
		var sequence uint64
		for _, b := range seqBytes {
			sequence = sequence<<8 | uint64(b)
		}
		length, err := r.u16()
		if err != nil {
			return records, err
		}
		body, err := r.take(int(length))
		if err != nil {
			return records, err
		}
		offset += r.pos
		if epoch == 0 {
			cp := make([]byte, len(body))
			copy(cp, body)
			records = append(records, dtlsRecord{contentType, 0, sequence, cp})
			continue
		}
		if c.readKeys == nil {
			// A coalesced flight may place an epoch-1 record (the
			// Finished) in the same datagram as the epoch-0 records
			// that establish the keys. Return what parsed so far and
			// let the caller defer the rest of the datagram.
			return records, errKeysPending
		}
		if len(body) < 24 {
			return records, errors.New("short epoch-1 record")
		}
		explicit := body[:8]
		sealed := body[8:]
		nonce := append(append([]byte{}, c.readKeys.salt...), explicit...)
		// AAD: record header epoch||sequence, not the explicit nonce.
		headerSeq := append([]byte{byte(epoch >> 8), byte(epoch)}, seq48(sequence)...)
		aad := append(append([]byte{}, headerSeq...), contentType)
		aad = append(aad, dtlsVersion...)
		aad = append(aad, byte((len(sealed)-16)>>8), byte(len(sealed)-16))
		plaintext, err := c.readKeys.gcm.Open(nil, nonce, sealed, aad)
		if err != nil {
			return records, errors.New("record authentication failed")
		}
		seqI := int64(sequence)
		if c.readHighest < 0 {
			c.readHighest = seqI
			c.readWindow = 1
		} else if seqI > c.readHighest {
			shift := seqI - c.readHighest
			if shift >= 64 {
				c.readWindow = 1
			} else {
				c.readWindow = (c.readWindow << uint(shift)) | 1
			}
			c.readHighest = seqI
		} else {
			diff := c.readHighest - seqI
			if diff >= 64 || (c.readWindow>>uint(diff))&1 == 1 {
				return records, errors.New("replayed record")
			}
			c.readWindow |= 1 << uint(diff)
		}
		records = append(records, dtlsRecord{contentType, int(epoch), sequence, plaintext})
	}
	return records, nil
}

func (c *DtlsConnection) sendHs(hs *handshakeState, msgType byte, body []byte, epoch int) ([]byte, error) {
	raw := handshakeMessage(msgType, hs.sendSeq, body)
	hs.sendSeq++
	packet, err := c.sendRecord(DtlsContentHandshake, epoch, raw)
	if err != nil {
		return nil, err
	}
	hs.transcript = append(hs.transcript, raw)
	return packet, nil
}

func (c *DtlsConnection) pumpUntilMessage(hs *handshakeState, flight [][]byte) (*hsMessage, error) {
	retries := 0
	for {
		if msg := hs.next(); msg != nil {
			return msg, nil
		}
		progressed := false
		for i := 0; i < len(hs.pending); {
			records, err := c.parseRecords(hs.pending[i])
			if err == nil {
				hs.pending = append(hs.pending[:i], hs.pending[i+1:]...)
				progressed = true
			} else {
				// Deferred (or undecodable): keep the datagram for a
				// later pass; the reassembly layer dedupes records
				// that get fed twice.
				i++
			}
			for _, record := range records {
				if record.contentType == DtlsContentHandshake {
					hs.feed(record.body)
				} else if record.contentType == DtlsContentChangeCipherSpec {
					hs.ccsReceived = true
				}
			}
		}
		if progressed {
			continue
		}
		packet := c.io.Recv(1000)
		if packet == nil {
			retries++
			if retries > 6 {
				return nil, errors.New("handshake timed out")
			}
			for _, p := range flight {
				_ = c.io.Send(p)
			}
			continue
		}
		records, err := c.parseRecords(packet)
		parseErr := err
		for _, record := range records {
			switch record.contentType {
			case DtlsContentHandshake:
				hs.feed(record.body)
			case DtlsContentChangeCipherSpec:
				hs.ccsReceived = true
			case DtlsContentAlert:
				return nil, errors.New("fatal alert from peer during handshake")
			}
		}
		if parseErr != nil {
			if errors.Is(parseErr, errKeysPending) || c.readKeys == nil {
				hs.pending = append(hs.pending, packet)
				continue
			}
			return nil, parseErr
		}
	}
}

func (c *DtlsConnection) deriveKeys(master []byte) error {
	block := prf(master, "key expansion", append(append([]byte{}, c.serverRandom...), c.clientRandom...), 40)
	clientKeys, err := newRecordKeys(block[0:16], block[32:36])
	if err != nil {
		return err
	}
	serverKeys, err := newRecordKeys(block[16:32], block[36:40])
	if err != nil {
		return err
	}
	if c.role == "client" {
		c.writeKeys, c.readKeys = clientKeys, serverKeys
	} else {
		c.writeKeys, c.readKeys = serverKeys, clientKeys
	}
	return nil
}

func (c *DtlsConnection) checkFingerprint(expected string) error {
	if expected == "" {
		return nil
	}
	actual := c.PeerFingerprint()
	if actual == "" || !strings.EqualFold(actual, expected) {
		return errors.New("peer certificate fingerprint mismatch")
	}
	return nil
}

// SendApp sends one application-data record.
func (c *DtlsConnection) SendApp(data []byte) error {
	_, err := c.sendRecord(DtlsContentApplicationData, 1, data)
	return err
}

// RecvAppTimeout returns one application payload, nil on timeout.
func (c *DtlsConnection) RecvAppTimeout(timeoutMs int) ([]byte, error) {
	deadline := time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)
	for {
		remaining := int(time.Until(deadline) / time.Millisecond)
		if remaining <= 0 {
			return nil, nil
		}
		packet := c.io.Recv(remaining)
		if packet == nil {
			return nil, nil
		}
		records, err := c.parseRecords(packet)
		if err != nil {
			return nil, err
		}
		for _, record := range records {
			if record.contentType == DtlsContentApplicationData {
				return record.body, nil
			}
			if record.contentType == DtlsContentAlert {
				return nil, errors.New("alert from peer")
			}
		}
	}
}

func clientHelloBody(random []byte, cookie []byte) []byte {
	var exts []byte
	exts = append(exts, 0, 10, 0, 4, 0, 2, 0, groupSecp256r1)
	exts = append(exts, 0, 11, 0, 2, 1, 0)
	exts = append(exts, 0, 13, 0, 10, 0, 8, 0x04, 0x03, 0x05, 0x03, 0x04, 0x01, 0x08, 0x04)
	srtpData := []byte{0, 6, 0, 7, 0, 1, 0, 2, 0}
	exts = append(exts, 0, 14, 0, byte(len(srtpData)))
	exts = append(exts, srtpData...)
	exts = append(exts, 0, 23, 0, 0)
	body := append([]byte{}, dtlsVersion...)
	body = append(body, random...)
	body = append(body, 0)
	body = append(body, byte(len(cookie)))
	body = append(body, cookie...)
	body = append(body, 0, 2, 0xc0, 0x2b)
	body = append(body, 1, 0)
	body = append(body, byte(len(exts)>>8), byte(len(exts)))
	return append(body, exts...)
}

type serverHelloInfo struct {
	serverRandom []byte
	ems          bool
	srtpProfile  int
}

func parseServerHello(body []byte) (*serverHelloInfo, error) {
	r := &byteReader{buf: body}
	if _, err := r.u8(); err != nil {
		return nil, err
	}
	if _, err := r.u8(); err != nil {
		return nil, err
	}
	serverRandom, err := r.take(32)
	if err != nil {
		return nil, err
	}
	if _, err := r.vec8(); err != nil {
		return nil, err
	}
	suite, err := r.u16()
	if err != nil {
		return nil, err
	}
	if suite != dtlsSuite {
		return nil, errors.New("server picked an unsupported cipher suite")
	}
	if _, err := r.u8(); err != nil {
		return nil, err
	}
	info := &serverHelloInfo{serverRandom: serverRandom, srtpProfile: -1}
	if !r.done() {
		exts, err := r.vec16()
		if err != nil {
			return nil, err
		}
		er := &byteReader{buf: exts}
		for !er.done() {
			ty, err := er.u16()
			if err != nil {
				return nil, err
			}
			data, err := er.vec16()
			if err != nil {
				return nil, err
			}
			if ty == 23 {
				info.ems = true
			} else if ty == 14 {
				sr := &byteReader{buf: data}
				profiles, err := sr.vec16()
				if err == nil && len(profiles) >= 2 {
					info.srtpProfile = int(binary.BigEndian.Uint16(profiles[0:2]))
				}
			}
		}
	}
	return info, nil
}

func signSHA256(key *ecdsa.PrivateKey, data []byte) ([]byte, error) {
	digest := sha256.Sum256(data)
	return ecdsa.SignASN1(rand.Reader, key, digest[:])
}

func verifySHA256(pub *ecdsa.PublicKey, data, sig []byte) bool {
	digest := sha256.Sum256(data)
	return ecdsa.VerifyASN1(pub, digest[:], sig)
}

func ecdhePremaster(ourPriv *ecdh.PrivateKey, peerPoint []byte) ([]byte, error) {
	pub, err := ecdh.P256().NewPublicKey(peerPoint)
	if err != nil {
		return nil, err
	}
	return ourPriv.ECDH(pub)
}

func peerPointFromKey(pub *ecdsa.PublicKey) ([]byte, error) {
	ecdhPub, err := pub.ECDH()
	if err != nil {
		return nil, err
	}
	return ecdhPub.Bytes(), nil
}

// DtlsConnect runs the client handshake.
func DtlsConnect(io PacketIO, config DtlsConfig) (*DtlsConnection, error) {
	conn := &DtlsConnection{io: io, role: "client", srtpProfile: -1, readHighest: -1}
	hs := newHandshakeState()
	conn.clientRandom = make([]byte, 32)
	if _, err := rand.Read(conn.clientRandom); err != nil {
		return nil, err
	}
	cert := config.Certificate

	var cookie []byte
	var flight [][]byte
	var serverHello *serverHelloInfo
cookieLoop:
	for {
		hs.transcript = nil
		hs.sendSeq = 0
		hs.expectSeq = 0
		packet, err := conn.sendHs(hs, DtlsHandshakeClientHello, clientHelloBody(conn.clientRandom, cookie), 0)
		if err != nil {
			return nil, err
		}
		flight = [][]byte{packet}
		for {
			msg, err := conn.pumpUntilMessage(hs, flight)
			if err != nil {
				return nil, err
			}
			switch msg.typ {
			case DtlsHandshakeHelloVerifyRequest:
				r := &byteReader{buf: msg.body}
				if _, err := r.u8(); err != nil {
					return nil, err
				}
				if _, err := r.u8(); err != nil {
					return nil, err
				}
				newCookie, err := r.vec8()
				if err != nil {
					return nil, err
				}
				cookie = append([]byte{}, newCookie...)
				continue cookieLoop
			case DtlsHandshakeServerHello:
				info, err := parseServerHello(msg.body)
				if err != nil {
					return nil, err
				}
				serverHello = info
				hs.transcript = append(hs.transcript, msg.raw)
				break cookieLoop
			default:
				return nil, errors.New("unexpected message before ServerHello")
			}
		}
	}
	conn.serverRandom = serverHello.serverRandom
	conn.srtpProfile = serverHello.srtpProfile

	var peerEphemeralPoint []byte
	var skeParams []byte
	var skeSignature []byte
	certRequested := false
	for {
		msg, err := conn.pumpUntilMessage(hs, flight)
		if err != nil {
			return nil, err
		}
		hs.transcript = append(hs.transcript, msg.raw)
		switch msg.typ {
		case DtlsHandshakeCertificate:
			der, err := parseFirstCert(msg.body)
			if err != nil {
				return nil, err
			}
			conn.peerCertDER = append([]byte{}, der...)
		case DtlsHandshakeServerKeyExchange:
			r := &byteReader{buf: msg.body}
			curveType, err := r.u8()
			if err != nil {
				return nil, err
			}
			group, err := r.u16()
			if err != nil {
				return nil, err
			}
			if curveType != 3 || group != groupSecp256r1 {
				return nil, errors.New("server picked an unsupported ECDHE group")
			}
			point, err := r.vec8()
			if err != nil {
				return nil, err
			}
			skeParams = append([]byte{}, msg.body[:r.pos]...)
			if _, err := r.u16(); err != nil {
				return nil, err
			}
			sig, err := r.vec16()
			if err != nil {
				return nil, err
			}
			skeSignature = append([]byte{}, sig...)
			peerEphemeralPoint = append([]byte{}, point...)
		case DtlsHandshakeCertificateRequest:
			certRequested = true
		case DtlsHandshakeServerHelloDone:
			goto serverFlightDone
		default:
			return nil, errors.New("unexpected message in server flight")
		}
	}
serverFlightDone:
	if conn.peerCertDER == nil {
		return nil, errors.New("server sent no certificate")
	}
	peerCertKey, err := peerPublicKey(conn.peerCertDER)
	if err != nil {
		return nil, err
	}
	signed := append(append(append([]byte{}, conn.clientRandom...), conn.serverRandom...), skeParams...)
	if !verifySHA256(peerCertKey, signed, skeSignature) {
		return nil, errors.New("ServerKeyExchange signature invalid")
	}
	if err := conn.checkFingerprint(config.ExpectedPeerFingerprint); err != nil {
		return nil, err
	}

	ephPriv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	ephPublicPoint := ephPriv.PublicKey().Bytes()
	premaster, err := ecdhePremaster(ephPriv, peerEphemeralPoint)
	if err != nil {
		return nil, err
	}

	var outFlight [][]byte
	if certRequested {
		packet, err := conn.sendHs(hs, DtlsHandshakeCertificate, certListBody(cert.DER), 0)
		if err != nil {
			return nil, err
		}
		outFlight = append(outFlight, packet)
	}
	cke := append([]byte{byte(len(ephPublicPoint))}, ephPublicPoint...)
	packet, err := conn.sendHs(hs, DtlsHandshakeClientKeyExchange, cke, 0)
	if err != nil {
		return nil, err
	}
	outFlight = append(outFlight, packet)

	sessionHash := hs.hash()
	if serverHello.ems {
		conn.masterSecret = prf(premaster, "extended master secret", sessionHash, 48)
	} else {
		seed := append(append([]byte{}, conn.clientRandom...), conn.serverRandom...)
		conn.masterSecret = prf(premaster, "master secret", seed, 48)
	}
	if err := conn.deriveKeys(conn.masterSecret); err != nil {
		return nil, err
	}

	if certRequested {
		der, err := signSHA256(cert.PrivateKey, hs.bytes())
		if err != nil {
			return nil, err
		}
		cvBody := []byte{0x04, 0x03, byte(len(der) >> 8), byte(len(der))}
		cvBody = append(cvBody, der...)
		packet, err := conn.sendHs(hs, DtlsHandshakeCertificateVerify, cvBody, 0)
		if err != nil {
			return nil, err
		}
		outFlight = append(outFlight, packet)
	}
	ccs, err := conn.sendRecord(DtlsContentChangeCipherSpec, 0, []byte{1})
	if err != nil {
		return nil, err
	}
	outFlight = append(outFlight, ccs)
	verifyData := prf(conn.masterSecret, "client finished", hs.hash(), 12)
	fin, err := conn.sendHs(hs, DtlsHandshakeFinished, verifyData, 1)
	if err != nil {
		return nil, err
	}
	outFlight = append(outFlight, fin)
	flight = outFlight

	for {
		msg, err := conn.pumpUntilMessage(hs, flight)
		if err != nil {
			return nil, err
		}
		if msg.typ == DtlsHandshakeFinished {
			expected := prf(conn.masterSecret, "server finished", hs.hash(), 12)
			if !bytes.Equal(msg.body, expected) {
				return nil, errors.New("server Finished verification failed")
			}
			hs.transcript = append(hs.transcript, msg.raw)
			break
		}
		hs.transcript = append(hs.transcript, msg.raw)
	}
	return conn, nil
}

// DtlsAccept runs the server handshake.
func DtlsAccept(io PacketIO, config DtlsConfig) (*DtlsConnection, error) {
	conn := &DtlsConnection{io: io, role: "server", srtpProfile: -1, readHighest: -1}
	hs := newHandshakeState()
	cert := config.Certificate

	first, err := conn.pumpUntilMessage(hs, nil)
	if err != nil {
		return nil, err
	}
	hs.transcript = append(hs.transcript, first.raw)
	if first.typ != DtlsHandshakeClientHello {
		return nil, errors.New("expected ClientHello")
	}
	clientEms := false
	var clientSrtp []int
	{
		r := &byteReader{buf: first.body}
		if _, err := r.u8(); err != nil {
			return nil, err
		}
		if _, err := r.u8(); err != nil {
			return nil, err
		}
		random, err := r.take(32)
		if err != nil {
			return nil, err
		}
		conn.clientRandom = append([]byte{}, random...)
		if _, err := r.vec8(); err != nil {
			return nil, err
		}
		if _, err := r.vec8(); err != nil {
			return nil, err
		}
		suites, err := r.vec16()
		if err != nil {
			return nil, err
		}
		suiteOk := false
		for i := 0; i+1 < len(suites); i += 2 {
			if binary.BigEndian.Uint16(suites[i:i+2]) == dtlsSuite {
				suiteOk = true
			}
		}
		if !suiteOk {
			return nil, errors.New("client does not offer the required cipher suite")
		}
		if _, err := r.vec8(); err != nil {
			return nil, err
		}
		if !r.done() {
			exts, err := r.vec16()
			if err != nil {
				return nil, err
			}
			er := &byteReader{buf: exts}
			for !er.done() {
				ty, err := er.u16()
				if err != nil {
					return nil, err
				}
				data, err := er.vec16()
				if err != nil {
					return nil, err
				}
				if ty == 23 {
					clientEms = true
				} else if ty == 14 {
					sr := &byteReader{buf: data}
					list, err := sr.vec16()
					if err == nil {
						for i := 0; i+1 < len(list); i += 2 {
							clientSrtp = append(clientSrtp, int(binary.BigEndian.Uint16(list[i:i+2])))
						}
					}
				}
			}
		}
	}
	srtpProfile := -1
	for _, p := range []int{0x0007, 0x0001, 0x0002, 0x0008} {
		for _, offered := range clientSrtp {
			if offered == p {
				srtpProfile = p
			}
		}
		if srtpProfile >= 0 {
			break
		}
	}
	conn.srtpProfile = srtpProfile
	conn.serverRandom = make([]byte, 32)
	if _, err := rand.Read(conn.serverRandom); err != nil {
		return nil, err
	}

	var flight [][]byte
	{
		var exts []byte
		if srtpProfile >= 0 {
			data := []byte{0, 2, byte(srtpProfile >> 8), byte(srtpProfile), 0}
			exts = append(exts, 0, 14, 0, byte(len(data)))
			exts = append(exts, data...)
		}
		if clientEms {
			exts = append(exts, 0, 23, 0, 0)
		}
		exts = append(exts, 0xff, 0x01, 0, 1, 0)
		sh := append([]byte{}, dtlsVersion...)
		sh = append(sh, conn.serverRandom...)
		sh = append(sh, 0)
		sh = append(sh, 0xc0, 0x2b)
		sh = append(sh, 0)
		sh = append(sh, byte(len(exts)>>8), byte(len(exts)))
		sh = append(sh, exts...)
		packet, err := conn.sendHs(hs, DtlsHandshakeServerHello, sh, 0)
		if err != nil {
			return nil, err
		}
		flight = append(flight, packet)
	}
	{
		packet, err := conn.sendHs(hs, DtlsHandshakeCertificate, certListBody(cert.DER), 0)
		if err != nil {
			return nil, err
		}
		flight = append(flight, packet)
	}
	ephPriv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	ephPublicPoint := ephPriv.PublicKey().Bytes()
	{
		params := []byte{3, 0, groupSecp256r1, byte(len(ephPublicPoint))}
		params = append(params, ephPublicPoint...)
		signed := append(append(append([]byte{}, conn.clientRandom...), conn.serverRandom...), params...)
		der, err := signSHA256(cert.PrivateKey, signed)
		if err != nil {
			return nil, err
		}
		ske := append([]byte{}, params...)
		ske = append(ske, 0x04, 0x03, byte(len(der)>>8), byte(len(der)))
		ske = append(ske, der...)
		packet, err := conn.sendHs(hs, DtlsHandshakeServerKeyExchange, ske, 0)
		if err != nil {
			return nil, err
		}
		flight = append(flight, packet)
	}
	{
		pairs := []byte{0x04, 0x03, 0x05, 0x03, 0x06, 0x03, 0x04, 0x01, 0x05, 0x01, 0x06, 0x01}
		cr := []byte{1, 64, byte(len(pairs) >> 8), byte(len(pairs))}
		cr = append(cr, pairs...)
		cr = append(cr, 0, 0)
		packet, err := conn.sendHs(hs, DtlsHandshakeCertificateRequest, cr, 0)
		if err != nil {
			return nil, err
		}
		flight = append(flight, packet)
	}
	{
		packet, err := conn.sendHs(hs, DtlsHandshakeServerHelloDone, nil, 0)
		if err != nil {
			return nil, err
		}
		flight = append(flight, packet)
	}

	sawClientCert := false
	var ckeTranscript []byte
	for {
		msg, err := conn.pumpUntilMessage(hs, flight)
		if err != nil {
			return nil, err
		}
		switch msg.typ {
		case DtlsHandshakeCertificate:
			hs.transcript = append(hs.transcript, msg.raw)
			if len(msg.body) > 3 {
				if der, err := parseFirstCert(msg.body); err == nil {
					conn.peerCertDER = append([]byte{}, der...)
					sawClientCert = true
				}
			}
		case DtlsHandshakeClientKeyExchange:
			hs.transcript = append(hs.transcript, msg.raw)
			r := &byteReader{buf: msg.body}
			point, err := r.vec8()
			if err != nil {
				return nil, err
			}
			premaster, err := ecdhePremaster(ephPriv, point)
			if err != nil {
				return nil, err
			}
			ckeTranscript = hs.bytes()
			if clientEms {
				conn.masterSecret = prf(premaster, "extended master secret", hs.hash(), 48)
			} else {
				seed := append(append([]byte{}, conn.clientRandom...), conn.serverRandom...)
				conn.masterSecret = prf(premaster, "master secret", seed, 48)
			}
			if err := conn.deriveKeys(conn.masterSecret); err != nil {
				return nil, err
			}
		case DtlsHandshakeCertificateVerify:
			peerKey, err := peerPublicKey(conn.peerCertDER)
			if err != nil {
				return nil, err
			}
			r := &byteReader{buf: msg.body}
			if _, err := r.u16(); err != nil {
				return nil, err
			}
			sig, err := r.vec16()
			if err != nil {
				return nil, err
			}
			if !verifySHA256(peerKey, ckeTranscript, sig) {
				return nil, errors.New("CertificateVerify signature invalid")
			}
			hs.transcript = append(hs.transcript, msg.raw)
		case DtlsHandshakeFinished:
			expected := prf(conn.masterSecret, "client finished", hs.hash(), 12)
			if !bytes.Equal(msg.body, expected) {
				return nil, errors.New("client Finished verification failed")
			}
			hs.transcript = append(hs.transcript, msg.raw)
			goto clientFlightDone
		default:
			return nil, errors.New("unexpected message in client flight")
		}
	}
clientFlightDone:
	if config.RequirePeerCertificate && !sawClientCert {
		return nil, errors.New("peer presented no certificate")
	}
	if err := conn.checkFingerprint(config.ExpectedPeerFingerprint); err != nil {
		return nil, err
	}
	if _, err := conn.sendRecord(DtlsContentChangeCipherSpec, 0, []byte{1}); err != nil {
		return nil, err
	}
	verifyData := prf(conn.masterSecret, "server finished", hs.hash(), 12)
	if _, err := conn.sendHs(hs, DtlsHandshakeFinished, verifyData, 1); err != nil {
		return nil, err
	}
	return conn, nil
}

func peerPublicKey(der []byte) (*ecdsa.PublicKey, error) {
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	pub, ok := cert.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, errors.New("peer certificate is not ECDSA")
	}
	return pub, nil
}
