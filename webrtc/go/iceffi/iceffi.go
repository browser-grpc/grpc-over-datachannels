// ICE agent from the shared Rust core (crates/dc-ice-ffi,
// C ABI via cgo): the dc-webrtc IceAgent running in-process
// instead of the mirrored Go stack. Sans-io, like the core:
// candidates cross as SDP lines, checks and responses as
// framed (packet, addr) buffers, events framed alongside.
//
// The Rust core is the default backend; build it first:
//
//	cargo build --release (in crates/dc-ice-ffi)
//
// The cgo directives below link the in-repo release lib.

package iceffi

/*
#cgo CFLAGS: -I${SRCDIR}/../../../crates/dc-ice-ffi/include
#cgo LDFLAGS: -L${SRCDIR}/../../../crates/dc-ice-ffi/target/release -Wl,-rpath,${SRCDIR}/../../../crates/dc-ice-ffi/target/release -ldc_ice_ffi

#include "grpcdc_ice.h"
#include <stdlib.h>
*/
import "C"

import (
	"encoding/binary"
	"fmt"
	"unsafe"
)

const capSize = 1 << 20

// Event kinds (grpcdc_ice.h).
const (
	EventPairValid = 1
	EventNominated = 2
)

// Packet is one datagram plus its destination address.
type Packet struct {
	Bytes []byte
	Addr  string
}

// Event is one decoded agent event.
type Event struct {
	Kind uint8
	Addr string
}

// Agent is one ICE agent handle. Single-goroutine pump:
// not safe for concurrent use.
type Agent struct {
	h    *C.grpcdc_ice_t
	buf  []byte
	ebuf []byte
}

// New creates an agent; controlling selects the ICE role.
func New(controlling bool) *Agent {
	c := C.uint8_t(0)
	if controlling {
		c = 1
	}
	return &Agent{
		h:    C.grpcdc_ice_new(c),
		buf:  make([]byte, capSize),
		ebuf: make([]byte, capSize),
	}
}

// Close frees the core handle.
func (a *Agent) Close() {
	if a.h != nil {
		C.grpcdc_ice_free(a.h)
		a.h = nil
	}
}

func check(rc int64, what string) error {
	if rc < 0 {
		return fmt.Errorf("iceffi: %s rc=%d", what, rc)
	}
	return nil
}

func (a *Agent) getString(f func(*C.grpcdc_ice_t, *C.char, C.size_t) C.int64_t) string {
	buf := make([]byte, 512)
	n := f(a.h, (*C.char)(unsafe.Pointer(&buf[0])), C.size_t(len(buf)))
	if n <= 0 {
		return ""
	}
	if int(n) >= len(buf) {
		n = C.int64_t(len(buf) - 1)
	}
	return string(buf[:n])
}

// LocalUfrag returns the local ICE ufrag.
func (a *Agent) LocalUfrag() string {
	return a.getString(func(h *C.grpcdc_ice_t, b *C.char, c C.size_t) C.int64_t {
		return C.grpcdc_ice_local_ufrag(h, b, c)
	})
}

// LocalPwd returns the local ICE password.
func (a *Agent) LocalPwd() string {
	return a.getString(func(h *C.grpcdc_ice_t, b *C.char, c C.size_t) C.int64_t {
		return C.grpcdc_ice_local_pwd(h, b, c)
	})
}

// SetLocalCredentials overrides the generated credentials.
func (a *Agent) SetLocalCredentials(ufrag, pwd string) error {
	cu := C.CString(ufrag)
	defer C.free(unsafe.Pointer(cu))
	cp := C.CString(pwd)
	defer C.free(unsafe.Pointer(cp))
	return check(int64(C.grpcdc_ice_set_local_credentials(a.h, cu, cp)), "set_local_credentials")
}

// AddLocalCandidate adds one local candidate from an SDP
// line (with or without the "a=" prefix).
func (a *Agent) AddLocalCandidate(sdpLine string) error {
	cs := C.CString(sdpLine)
	defer C.free(unsafe.Pointer(cs))
	return check(int64(C.grpcdc_ice_add_local_candidate(a.h, cs)), "add_local_candidate")
}

// SetRemote installs the remote credentials.
func (a *Agent) SetRemote(ufrag, pwd string) error {
	cu := C.CString(ufrag)
	defer C.free(unsafe.Pointer(cu))
	cp := C.CString(pwd)
	defer C.free(unsafe.Pointer(cp))
	return check(int64(C.grpcdc_ice_set_remote(a.h, cu, cp)), "set_remote")
}

// AddRemoteCandidate trickles one remote candidate in
// from an SDP line; false when already known.
func (a *Agent) AddRemoteCandidate(sdpLine string) (bool, error) {
	cs := C.CString(sdpLine)
	defer C.free(unsafe.Pointer(cs))
	rc := C.grpcdc_ice_add_remote_candidate(a.h, cs)
	if err := check(int64(rc), "add_remote_candidate"); err != nil {
		return false, err
	}
	return rc != 0, nil
}

// SetControlling sets the ICE role before checks begin.
func (a *Agent) SetControlling(controlling bool) {
	c := C.uint8_t(0)
	if controlling {
		c = 1
	}
	C.grpcdc_ice_set_controlling(a.h, c)
}

// Controlling reports the current (possibly repaired) role.
func (a *Agent) Controlling() bool {
	return C.grpcdc_ice_controlling(a.h) != 0
}

// Restart begins an ICE restart in the core.
func (a *Agent) Restart() { C.grpcdc_ice_restart(a.h) }

// Generation is the core's restart generation.
func (a *Agent) Generation() uint64 { return uint64(C.grpcdc_ice_generation(a.h)) }

// Renominated reports whether the nomination is current.
func (a *Agent) Renominated() bool { return C.grpcdc_ice_renominated(a.h) != 0 }

// Nominated returns the nominated remote "ip:port", or "".
func (a *Agent) Nominated() string {
	return a.getString(func(h *C.grpcdc_ice_t, b *C.char, c C.size_t) C.int64_t {
		return C.grpcdc_ice_nominated(h, b, c)
	})
}

func splitFramed(buf []byte) []Packet {
	var out []Packet
	for len(buf) >= 4 {
		n := int(binary.BigEndian.Uint32(buf))
		buf = buf[4:]
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		buf = buf[n:]
		alen := int(binary.BigEndian.Uint16(buf))
		buf = buf[2:]
		addr := string(buf[:alen])
		buf = buf[alen:]
		out = append(out, Packet{Bytes: pkt, Addr: addr})
	}
	return out
}

func splitEvents(buf []byte) []Event {
	var out []Event
	for len(buf) >= 3 {
		kind := buf[0]
		alen := int(binary.BigEndian.Uint16(buf[1:]))
		buf = buf[3:]
		addr := string(buf[:alen])
		buf = buf[alen:]
		out = append(out, Event{Kind: kind, Addr: addr})
	}
	return out
}

// framed runs one framed-output call; on -2 the output is
// stashed in the handle, so grow and drain (never re-run).
func (a *Agent) framed(call func(out *C.uint8_t, cap C.size_t) C.int64_t, what string) ([]Packet, error) {
	for {
		n := call((*C.uint8_t)(unsafe.Pointer(&a.buf[0])), C.size_t(len(a.buf)))
		if n == -2 {
			a.buf = make([]byte, len(a.buf)*2)
			n = C.grpcdc_ice_drain(a.h, (*C.uint8_t)(unsafe.Pointer(&a.buf[0])), C.size_t(len(a.buf)))
		}
		if err := check(int64(n), what); err != nil {
			return nil, err
		}
		return splitFramed(a.buf[:n]), nil
	}
}

// DueChecks returns the checks due now.
func (a *Agent) DueChecks() ([]Packet, error) {
	return a.framed(func(out *C.uint8_t, cap C.size_t) C.int64_t {
		return C.grpcdc_ice_due_checks(a.h, out, cap)
	}, "due_checks")
}

// ConsentCheck returns the consent check for the
// nominated pair, if any.
func (a *Agent) ConsentCheck() ([]Packet, error) {
	return a.framed(func(out *C.uint8_t, cap C.size_t) C.int64_t {
		return C.grpcdc_ice_consent_check(a.h, out, cap)
	}, "consent_check")
}

// HandleStun feeds one STUN datagram from src ("ip:port")
// and returns response packets plus agent events.
func (a *Agent) HandleStun(packet []byte, src string) ([]Packet, []Event, error) {
	var pktPtr *C.uint8_t
	if len(packet) > 0 {
		pktPtr = (*C.uint8_t)(unsafe.Pointer(&packet[0]))
	}
	cs := C.CString(src)
	defer C.free(unsafe.Pointer(cs))
	var elen C.size_t
	for {
		n := C.grpcdc_ice_handle_stun(a.h, pktPtr, C.size_t(len(packet)), cs,
			(*C.uint8_t)(unsafe.Pointer(&a.buf[0])), C.size_t(len(a.buf)),
			(*C.uint8_t)(unsafe.Pointer(&a.ebuf[0])), C.size_t(len(a.ebuf)), &elen)
		if n == -2 {
			a.buf = make([]byte, len(a.buf)*2)
			a.ebuf = make([]byte, len(a.ebuf)*2)
			n = C.grpcdc_ice_drain(a.h, (*C.uint8_t)(unsafe.Pointer(&a.buf[0])), C.size_t(len(a.buf)))
			if err := check(int64(n), "handle_stun"); err != nil {
				return nil, nil, err
			}
			return splitFramed(a.buf[:n]), splitEvents(a.ebuf[:elen]), nil
		}
		if err := check(int64(n), "handle_stun"); err != nil {
			return nil, nil, err
		}
		return splitFramed(a.buf[:n]), splitEvents(a.ebuf[:elen]), nil
	}
}

// TouchConsent marks consent freshly confirmed.
func (a *Agent) TouchConsent() { C.grpcdc_ice_touch_consent(a.h) }

// ConsentExpired reports consent lapse past expiryMs.
func (a *Agent) ConsentExpired(expiryMs uint64) bool {
	return C.grpcdc_ice_consent_expired(a.h, C.uint64_t(expiryMs)) != 0
}
