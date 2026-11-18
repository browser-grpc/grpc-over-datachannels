//go:build !js

// DTLS connection from the shared Rust core
// (crates/dc-dtls-ffi, C ABI via cgo): the dc-webrtc
// DtlsHandshake + DtlsCore running in-process instead of
// the mirrored Go stack. Sans-io, like the core: pump
// datagrams in, send what comes out.
//
// The Rust core is the default backend; build it first:
//
//	cargo build --release (in crates/dc-dtls-ffi)
//
// The cgo directives below link the in-repo release lib.

package dtlsffi

/*
#cgo CFLAGS: -I${SRCDIR}/../../../crates/dc-dtls-ffi/include
#cgo LDFLAGS: -L${SRCDIR}/../../../crates/dc-dtls-ffi/target/release -Wl,-rpath,${SRCDIR}/../../../crates/dc-dtls-ffi/target/release -ldc_dtls_ffi

#include "grpcdc_dtls.h"
#include <stdlib.h>
*/
import "C"

import (
	"encoding/binary"
	"errors"
	"fmt"
	"unsafe"
)

const capSize = 1 << 20

// Return codes (grpcdc_dtls.h).
const (
	rcNoData  = -3 // datagram carried no application data
	rcCrypto  = -4 // record failed decryption/verification
	rcTooSmal = -2 // output stashed in handle; drain to re-read
)

// Config mirrors grpcdc_dtls_config. CertDER and KeyScalar
// (the P-256 private scalar, 32 bytes big-endian) are
// required; the Rust side copies everything at New, so the
// slices are only borrowed for the call.
type Config struct {
	CertDER                []byte
	KeyScalar              []byte
	ExpectedFingerprint    string // "" = no expectation
	RequirePeerCertificate bool
	SessionResumption      bool
	TicketKey              []byte // 32 bytes, or nil
	ConnectionID           []byte
	PairHint               []byte
}

// Connection is one DTLS handshake + established core.
// Single-goroutine pump: not safe for concurrent use.
type Connection struct {
	h   *C.grpcdc_dtls_t
	buf []byte
	app []byte
}

// ErrNoData reports a datagram without application data.
var ErrNoData = errors.New("dtlsffi: no application data")

// ErrCrypto reports a record that failed decryption.
var ErrCrypto = errors.New("dtlsffi: record decryption failed")

func bytePtr(b []byte) *C.uint8_t {
	if len(b) == 0 {
		return nil
	}
	return (*C.uint8_t)(unsafe.Pointer(&b[0]))
}

func newConnection(cfg Config, nowMs uint64, server bool) (*Connection, error) {
	if len(cfg.KeyScalar) != 32 {
		return nil, fmt.Errorf("dtlsffi: key scalar must be 32 bytes, got %d", len(cfg.KeyScalar))
	}
	// The config struct and its slices are copied into C
	// memory: cgo forbids passing a Go struct that holds
	// Go pointers. The core copies everything at New, so
	// all of it is freed on return.
	ccfg := (*C.grpcdc_dtls_config)(C.malloc(C.size_t(unsafe.Sizeof(C.grpcdc_dtls_config{}))))
	defer C.free(unsafe.Pointer(ccfg))
	*ccfg = C.grpcdc_dtls_config{}
	cbytes := func(b []byte) *C.uint8_t {
		if len(b) == 0 {
			return nil
		}
		return (*C.uint8_t)(C.CBytes(b))
	}
	ccfg.cert_der = cbytes(cfg.CertDER)
	defer C.free(unsafe.Pointer(ccfg.cert_der))
	ccfg.cert_der_len = C.size_t(len(cfg.CertDER))
	ccfg.key_scalar = cbytes(cfg.KeyScalar)
	defer C.free(unsafe.Pointer(ccfg.key_scalar))
	if cfg.ExpectedFingerprint != "" {
		fp := C.CString(cfg.ExpectedFingerprint)
		defer C.free(unsafe.Pointer(fp))
		ccfg.expected_fingerprint = fp
	}
	if cfg.RequirePeerCertificate {
		ccfg.require_peer_certificate = 1
	}
	if cfg.SessionResumption {
		ccfg.session_resumption = 1
	}
	ccfg.ticket_key = cbytes(cfg.TicketKey)
	defer C.free(unsafe.Pointer(ccfg.ticket_key))
	ccfg.connection_id = cbytes(cfg.ConnectionID)
	defer C.free(unsafe.Pointer(ccfg.connection_id))
	ccfg.connection_id_len = C.size_t(len(cfg.ConnectionID))
	ccfg.pair_hint = cbytes(cfg.PairHint)
	defer C.free(unsafe.Pointer(ccfg.pair_hint))
	ccfg.pair_hint_len = C.size_t(len(cfg.PairHint))
	var h *C.grpcdc_dtls_t
	if server {
		h = C.grpcdc_dtls_new_server(ccfg, C.uint64_t(nowMs))
	} else {
		h = C.grpcdc_dtls_new_client(ccfg, nil, C.uint64_t(nowMs))
	}
	if h == nil {
		return nil, errors.New("dtlsffi: core rejected the configuration")
	}
	return &Connection{h: h, buf: make([]byte, capSize), app: make([]byte, capSize)}, nil
}

// NewClient starts a client handshake at nowMs; call Start
// for the first flight.
func NewClient(cfg Config, nowMs uint64) (*Connection, error) {
	return newConnection(cfg, nowMs, false)
}

// NewServer starts a server handshake at nowMs.
func NewServer(cfg Config, nowMs uint64) (*Connection, error) {
	return newConnection(cfg, nowMs, true)
}

// Close frees the core handle.
func (c *Connection) Close() {
	if c.h != nil {
		C.grpcdc_dtls_free(c.h)
		c.h = nil
	}
}

func check(rc C.int64_t, what string) error {
	if rc < 0 {
		return fmt.Errorf("dtlsffi: %s rc=%d", what, int64(rc))
	}
	return nil
}

func splitPackets(buf []byte) [][]byte {
	var out [][]byte
	for len(buf) >= 4 {
		n := int(binary.BigEndian.Uint32(buf))
		buf = buf[4:]
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		out = append(out, pkt)
		buf = buf[n:]
	}
	return out
}

// framed runs one framed-output call; on -2 the core has
// stashed the output, so grow and drain (never re-run).
func (c *Connection) framed(call func(out *C.uint8_t, cap C.size_t) C.int64_t, what string) ([][]byte, error) {
	for {
		n := call((*C.uint8_t)(unsafe.Pointer(&c.buf[0])), C.size_t(len(c.buf)))
		if n == rcTooSmal {
			c.buf = make([]byte, len(c.buf)*2)
			n = C.grpcdc_dtls_drain(c.h, (*C.uint8_t)(unsafe.Pointer(&c.buf[0])), C.size_t(len(c.buf)))
		}
		if err := check(n, what); err != nil {
			return nil, err
		}
		return splitPackets(c.buf[:n]), nil
	}
}

// Start returns the initial client flight (empty for a
// server until the first datagram arrives).
func (c *Connection) Start() ([][]byte, error) {
	return c.framed(func(out *C.uint8_t, cap C.size_t) C.int64_t {
		return C.grpcdc_dtls_start(c.h, out, cap)
	}, "start")
}

// HandleDatagram feeds one inbound datagram at nowMs and
// returns datagrams to send.
func (c *Connection) HandleDatagram(packet []byte, nowMs uint64) ([][]byte, error) {
	return c.framed(func(out *C.uint8_t, cap C.size_t) C.int64_t {
		return C.grpcdc_dtls_handle_datagram(c.h, bytePtr(packet), C.size_t(len(packet)), C.uint64_t(nowMs), out, cap)
	}, "handle_datagram")
}

// Tick drives handshake timers at nowMs.
func (c *Connection) Tick(nowMs uint64) ([][]byte, error) {
	return c.framed(func(out *C.uint8_t, cap C.size_t) C.int64_t {
		return C.grpcdc_dtls_tick(c.h, C.uint64_t(nowMs), out, cap)
	}, "tick")
}

// NextTimeout is the milliseconds until the next Tick,
// or -1 when the handshake is done or failed.
func (c *Connection) NextTimeout(nowMs uint64) int64 {
	return int64(C.grpcdc_dtls_next_timeout(c.h, C.uint64_t(nowMs)))
}

// Established reports whether the handshake completed.
func (c *Connection) Established() bool {
	return C.grpcdc_dtls_is_established(c.h) != 0
}

// WasResumed reports an abbreviated (resumed) handshake.
func (c *Connection) WasResumed() bool {
	return C.grpcdc_dtls_was_resumed(c.h) != 0
}

// Failure returns the handshake failure message, or "".
func (c *Connection) Failure() string {
	buf := make([]byte, 512)
	n := C.grpcdc_dtls_failure(c.h, (*C.char)(unsafe.Pointer(&buf[0])), C.size_t(len(buf)))
	if n <= 0 {
		return ""
	}
	if int(n) >= len(buf) {
		n = C.int64_t(len(buf) - 1)
	}
	return string(buf[:n])
}

// EncryptApp seals one application record.
func (c *Connection) EncryptApp(data []byte) ([]byte, error) {
	out := make([]byte, len(data)+4096)
	n := C.grpcdc_dtls_encrypt_app(c.h, bytePtr(data), C.size_t(len(data)),
		(*C.uint8_t)(unsafe.Pointer(&out[0])), C.size_t(len(out)))
	if err := check(n, "encrypt_app"); err != nil {
		return nil, err
	}
	return out[:n], nil
}

// HandleApp opens one inbound datagram: ErrNoData when it
// carried no application data, ErrCrypto on a bad record.
// The payload aliases the connection's scratch buffer: it
// is valid until the next HandleApp call (copy it to keep
// it). Allocating per record made the receive pump drop
// datagrams at burst rates.
func (c *Connection) HandleApp(packet []byte) ([]byte, error) {
	n := C.grpcdc_dtls_handle_app(c.h, bytePtr(packet), C.size_t(len(packet)),
		(*C.uint8_t)(unsafe.Pointer(&c.app[0])), C.size_t(len(c.app)))
	switch n {
	case rcNoData:
		return nil, ErrNoData
	case rcCrypto:
		return nil, ErrCrypto
	}
	if err := check(n, "handle_app"); err != nil {
		return nil, err
	}
	return c.app[:n], nil
}

// PeerFingerprint returns the peer certificate fingerprint
// ("" before the handshake reveals it).
func (c *Connection) PeerFingerprint() string {
	buf := make([]byte, 256)
	n := C.grpcdc_dtls_peer_fingerprint(c.h, (*C.char)(unsafe.Pointer(&buf[0])), C.size_t(len(buf)))
	if n <= 0 {
		return ""
	}
	if int(n) >= len(buf) {
		n = C.int64_t(len(buf) - 1)
	}
	return string(buf[:n])
}
