//! Homegrown tracing for the WebRTC stack: a synchronous event
//! observer, same shape as the gRPC runtime hooks (no SDK, no
//! dependencies). Dormant until `set_observer` registers one;
//! observer panics are caught so tracing never breaks a call.
//!
//! Events emitted by `Peer::connect`:
//! - `ice.nominated` (detail: the nominated pair address)
//! - `dtls.handshake` (detail: `full` or `resumed`)
//! - `endpoint.ready` (detail: DTLS role, `client` or `server`)

use std::sync::{Arc, RwLock};

/// One observed stack event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TraceEvent {
    pub name: &'static str,
    pub detail: String,
}

/// Synchronous event observer.
pub type Observer = dyn Fn(&TraceEvent) + Send + Sync;

static OBSERVER: RwLock<Option<Arc<Observer>>> = RwLock::new(None);

/// Register (or clear, with None) the stack event observer.
pub fn set_observer(observer: Option<Arc<Observer>>) {
    *OBSERVER.write().unwrap() = observer;
}

/// Emit one event to the registered observer, if any.
pub(crate) fn emit(name: &'static str, detail: String) {
    let observer = OBSERVER.read().unwrap().clone();
    if let Some(observer) = observer {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            observer(&TraceEvent { name, detail });
        }));
    }
}
