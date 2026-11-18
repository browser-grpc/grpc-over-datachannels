// SCTP association from the shared Rust core
// (crates/dc-sctp-ffi, C ABI via cgo): the dc-webrtc SCTP
// state machine running in-process instead of the mirrored
// Go stack. Sans-io, like the core: pump datagrams in, send
// what comes out.
//
// Behind the dc_sctp build tag so default builds stay
// cgo-free:
//
//	CGO_LDFLAGS="-L<lib dir> -Wl,-rpath,<lib dir>" \
//	  go test -tags dc_sctp ./sctpffi/
//
//go:build dc_sctp

package sctpffi

/*
#cgo CFLAGS: -I${SRCDIR}/../../../crates/dc-sctp-ffi/include
#cgo LDFLAGS: -ldc_sctp_ffi

#include "grpcdc_sctp.h"
#include <stdlib.h>
*/
import "C"

import (
	"encoding/binary"
	"fmt"
	"unsafe"
)

const capSize = 1 << 20

// Event kinds (grpcdc_sctp.h).
const (
	EventConnected   = 1
	EventData        = 2
	EventStreamReset = 3
	EventClosed      = 4
)

// Event is one decoded association event. Payload aliases
// nothing: it is copied out of the FFI buffer.
type Event struct {
	Kind    uint8
	Stream  uint16
	Ppid    uint32
	Payload []byte
}

// SendOptions mirrors the core's per-message reliability.
type SendOptions struct {
	Unordered      bool
	MaxRetransmits int32 // -1 = reliable
	MaxLifetimeMs  int64 // -1 = unset
}

// Reliable is the default ordered, fully-reliable options.
var Reliable = SendOptions{MaxRetransmits: -1, MaxLifetimeMs: -1}

// Association is one SCTP association handle. Like the
// core, it is a single-goroutine pump: not safe for
// concurrent use.
type Association struct {
	h    *C.grpcdc_sctp_t
	pbuf []byte
	ebuf []byte
}

// NewClient creates a client (INIT-sending) association.
func NewClient(localPort, peerPort uint16) *Association {
	return &Association{
		h:    C.grpcdc_sctp_new_client(C.uint16_t(localPort), C.uint16_t(peerPort)),
		pbuf: make([]byte, capSize),
		ebuf: make([]byte, capSize),
	}
}

// NewServer creates a listening association.
func NewServer(localPort, peerPort uint16) *Association {
	return &Association{
		h:    C.grpcdc_sctp_new_server(C.uint16_t(localPort), C.uint16_t(peerPort)),
		pbuf: make([]byte, capSize),
		ebuf: make([]byte, capSize),
	}
}

// Close frees the core handle.
func (a *Association) Close() {
	if a.h != nil {
		C.grpcdc_sctp_free(a.h)
		a.h = nil
	}
}

// Established reports whether the handshake completed.
func (a *Association) Established() bool {
	return C.grpcdc_sctp_is_established(a.h) != 0
}

func check(rc C.int64_t, what string) error {
	if rc < 0 {
		return fmt.Errorf("sctpffi: %s rc=%d", what, int64(rc))
	}
	return nil
}

// growFor doubles the named scratch buffer; the FFI
// returns -2 (buffer too small, nothing written) when a
// burst does not fit, and callers retry with a bigger one.
func (a *Association) grow(events bool) {
	if events {
		a.ebuf = make([]byte, len(a.ebuf)*2)
	} else {
		a.pbuf = make([]byte, len(a.pbuf)*2)
	}
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

func parseEvents(buf []byte) []Event {
	var out []Event
	for len(buf) >= 11 {
		kind := buf[0]
		stream := binary.BigEndian.Uint16(buf[1:])
		ppid := binary.BigEndian.Uint32(buf[3:])
		n := int(binary.BigEndian.Uint32(buf[7:]))
		buf = buf[11:]
		payload := make([]byte, n)
		copy(payload, buf[:n])
		buf = buf[n:]
		out = append(out, Event{Kind: kind, Stream: stream, Ppid: ppid, Payload: payload})
	}
	return out
}

// Connect returns the INIT packet (client side).
func (a *Association) Connect(nowMs uint64) ([]byte, error) {
	out := make([]byte, 4096)
	n := C.grpcdc_sctp_connect(a.h, C.uint64_t(nowMs), (*C.uint8_t)(unsafe.Pointer(&out[0])), C.size_t(len(out)))
	if err := check(n, "connect"); err != nil {
		return nil, err
	}
	return out[:n], nil
}

// SendData queues one message and returns packets to send.
func (a *Association) SendData(stream uint16, ppid uint32, data []byte, opts SendOptions, nowMs uint64) ([][]byte, error) {
	var dataPtr *C.uint8_t
	if len(data) > 0 {
		dataPtr = (*C.uint8_t)(unsafe.Pointer(&data[0]))
	}
	unordered := C.uint8_t(0)
	if opts.Unordered {
		unordered = 1
	}
	for {
		n := C.grpcdc_sctp_send_data(a.h, C.uint16_t(stream), C.uint32_t(ppid),
			dataPtr, C.size_t(len(data)), unordered,
			C.int32_t(opts.MaxRetransmits), C.int64_t(opts.MaxLifetimeMs),
			C.uint64_t(nowMs), (*C.uint8_t)(unsafe.Pointer(&a.pbuf[0])), C.size_t(len(a.pbuf)))
		if n == -2 {
			a.grow(false)
			continue
		}
		if err := check(n, "send_data"); err != nil {
			return nil, err
		}
		return splitPackets(a.pbuf[:n]), nil
	}
}

// HandlePacket feeds one inbound datagram; returns reply
// packets and events.
func (a *Association) HandlePacket(packet []byte, nowMs uint64) ([][]byte, []Event, error) {
	var elen C.size_t
	var pktPtr *C.uint8_t
	if len(packet) > 0 {
		pktPtr = (*C.uint8_t)(unsafe.Pointer(&packet[0]))
	}
	n := C.grpcdc_sctp_handle_packet(a.h, pktPtr, C.size_t(len(packet)), C.uint64_t(nowMs),
		(*C.uint8_t)(unsafe.Pointer(&a.pbuf[0])), C.size_t(len(a.pbuf)),
		(*C.uint8_t)(unsafe.Pointer(&a.ebuf[0])), C.size_t(len(a.ebuf)), &elen)
	if n == -2 {
		// The core call HAS run; its outputs are stashed
		// in the handle. Grow and drain — never re-run
		// the same packet through the association.
		for n == -2 {
			a.grow(false)
			a.grow(true)
			var dn C.int64_t
			_, _, dn = a.Drain()
			n = dn
		}
		if err := check(n, "handle_packet"); err != nil {
			return nil, nil, err
		}
		packets, events, _ := a.Drain()
		return packets, events, nil
	}
	if err := check(n, "handle_packet"); err != nil {
		return nil, nil, err
	}
	return splitPackets(a.pbuf[:n]), parseEvents(a.ebuf[:elen]), nil
}

// Tick drives timers (RTO, retransmits) at nowMs.
func (a *Association) Tick(nowMs uint64) ([][]byte, []Event, error) {
	var elen C.size_t
	n := C.grpcdc_sctp_tick(a.h, C.uint64_t(nowMs),
		(*C.uint8_t)(unsafe.Pointer(&a.pbuf[0])), C.size_t(len(a.pbuf)),
		(*C.uint8_t)(unsafe.Pointer(&a.ebuf[0])), C.size_t(len(a.ebuf)), &elen)
	if n == -2 {
		for n == -2 {
			a.grow(false)
			a.grow(true)
			var dn C.int64_t
			_, _, dn = a.Drain()
			n = dn
		}
		if err := check(n, "tick"); err != nil {
			return nil, nil, err
		}
		packets, events, _ := a.Drain()
		return packets, events, nil
	}
	if err := check(n, "tick"); err != nil {
		return nil, nil, err
	}
	return splitPackets(a.pbuf[:n]), parseEvents(a.ebuf[:elen]), nil
}

// CloseStream signals an SCTP stream reset; returns
// packets to send.
func (a *Association) CloseStream(stream uint16) ([][]byte, error) {
	n := C.grpcdc_sctp_close_stream(a.h, C.uint16_t(stream),
		(*C.uint8_t)(unsafe.Pointer(&a.pbuf[0])), C.size_t(len(a.pbuf)))
	if err := check(n, "close_stream"); err != nil {
		return nil, err
	}
	return splitPackets(a.pbuf[:n]), nil
}

// Shutdown starts SCTP shutdown; returns packets to send.
// The handle is freed as part of Shutdown.
func (a *Association) Shutdown(nowMs uint64) ([][]byte, error) {
	n := C.grpcdc_sctp_close(a.h, C.uint64_t(nowMs),
		(*C.uint8_t)(unsafe.Pointer(&a.pbuf[0])), C.size_t(len(a.pbuf)))
	if err := check(n, "close"); err != nil {
		return nil, err
	}
	out := splitPackets(a.pbuf[:n])
	a.Close()
	return out, nil
}

// Drain re-reads the stashed outputs of the last
// HandlePacket or Tick call (after a -2 too-small return
// with bigger buffers). It never re-runs the core.
func (a *Association) Drain() ([][]byte, []Event, C.int64_t) {
	var elen C.size_t
	n := C.grpcdc_sctp_drain(a.h,
		(*C.uint8_t)(unsafe.Pointer(&a.pbuf[0])), C.size_t(len(a.pbuf)),
		(*C.uint8_t)(unsafe.Pointer(&a.ebuf[0])), C.size_t(len(a.ebuf)), &elen)
	if n < 0 {
		return nil, nil, n
	}
	return splitPackets(a.pbuf[:n]), parseEvents(a.ebuf[:elen]), n
}

// Stats returns the 7 core counters (see grpcdc_sctp.h).
func (a *Association) Stats() ([7]uint64, error) {
	var out [7]uint64
	rc := C.grpcdc_sctp_stats(a.h, (*C.uint64_t)(unsafe.Pointer(&out[0])))
	if rc != 0 {
		return out, fmt.Errorf("sctpffi: stats rc=%d", int(rc))
	}
	return out, nil
}
