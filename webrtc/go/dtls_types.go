package dcwebrtc

// Shared DTLS-adjacent types: the packet transport the
// seam pumps, certificates/fingerprints, and the binary
// reader shared with mux.go. The DTLS implementation
// itself is the Rust core (crates/dc-dtls-ffi) behind
// DtlsConn; see dtls_ffi.go.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"fmt"
	"math/big"
	"net"
	"strings"
	"time"
)

// PacketIO is the datagram transport a DTLS handshake
// and connection run over.
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

// DtlsConfig configures a handshake.
type DtlsConfig struct {
	Certificate             *Certificate
	ExpectedPeerFingerprint string
	RequirePeerCertificate  bool
	// ConnectionID, when set, is announced in the handshake
	// (RFC 9146 ext 54): honoring peers stamp it on every
	// record they send us, and we accept both layouts.
	ConnectionID []byte
	// PairHint rides the first ClientHello (private ext) so a
	// shared-socket mux can route it before any route exists.
	PairHint []byte
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
