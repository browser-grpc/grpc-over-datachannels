package dcwebrtc

import "sync"

// Homegrown stack tracing: a synchronous event observer, same
// shape as the Rust dc-webrtc trace module and the gRPC hooks
// (no SDK, no dependencies). Dormant until SetStackObserver
// registers one; observer panics are recovered so tracing can
// never break a connection.
//
// Events emitted by Peer.Connect:
// - ice.nominated (detail: the nominated pair address)
// - dtls.handshake (detail: "full" or "resumed")
// - endpoint.ready (detail: DTLS role, "client" or "server")

// StackEvent is one observed stack event.
type StackEvent struct {
	Name   string
	Detail string
}

var stackObserver struct {
	sync.RWMutex
	fn func(StackEvent)
}

// SetStackObserver registers (or clears, with nil) the stack
// event observer.
func SetStackObserver(fn func(StackEvent)) {
	stackObserver.Lock()
	defer stackObserver.Unlock()
	stackObserver.fn = fn
}

func emitStackEvent(name, detail string) {
	stackObserver.RLock()
	fn := stackObserver.fn
	stackObserver.RUnlock()
	if fn == nil {
		return
	}
	defer func() { _ = recover() }()
	fn(StackEvent{Name: name, Detail: detail})
}
