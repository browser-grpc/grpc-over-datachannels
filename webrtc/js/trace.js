// Homegrown stack tracing: a synchronous event observer, same
// shape as the Rust dc-webrtc trace module and the gRPC hooks
// (no SDK, no dependencies). Dormant until setStackObserver
// registers one; observer exceptions are swallowed.
//
// Events emitted by Peer.connect():
// - ice.nominated (detail: the nominated pair address)
// - dtls.handshake (detail: 'full' or 'resumed')
// - endpoint.ready (detail: DTLS role, 'client' or 'server')

let observer = null;

export function setStackObserver(fn) {
  observer = fn ?? null;
}

export function emitStackEvent(name, detail) {
  if (observer === null) return;
  try {
    observer({ name, detail });
  } catch {
    // observers must never break the connection
  }
}
