#lang racket

;;; runtime-rust.rkt — the rust gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under the language tree are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)

(require "spec.rkt")
(provide emit-rust-runtime-files)

(define rust-lib-body
#<<GRPC_RUNTIME_EOF
//! gRPC over a single WebRTC `RTCDataChannel`.
//!
//! One ordered, reliable data channel carries many concurrent calls,
//! multiplexed by the frame protocol in `SPEC.md` (repository root). The
//! protocol tables and this crate's [`wire_gen`] module are produced by
//! the grpc-dc code generator; service stubs come from the generated
//! protoc plugins `protoc-gen-grpc-dc-rust` / `-js`.
//!
//! Signaling is out of scope: hand any already-open channel to
//! [`Channel`]/[`Server`] through the [`DcTransport`] trait (see
//! [`loopback_pair`] for an in-memory pair, and `transport` for how a real
//! `RTCDataChannel` plugs in).
//!
//! # Method shapes
//!
//! All four gRPC shapes map onto the frame protocol: unary,
//! server-streaming (a stream of responses), client-streaming (a stream of
//! requests, one response), and bidirectional streaming.

pub mod channel;
pub mod codec;
pub mod dynamic;
pub mod endpoint;
pub mod eventbus;
#[cfg(not(target_arch = "wasm32"))]
pub mod eventbus_git;
pub mod message;
pub mod server;
pub mod status;
pub mod transport;
#[cfg(feature = "webrtc")]
pub mod webrtc_direct;
#[cfg(feature = "webrtc")]
pub mod webrtc_transport;
pub mod wire_gen;

pub use async_trait::async_trait;
pub use futures_core;
pub use channel::{CallOptions, Channel};
pub use codec::Frame;
pub use endpoint::{Endpoint, StreamIdParity};
pub use message::Message;
pub use server::{
    bidi_method, client_stream_method, server_stream_method, unary_method, CallCtx, MethodDef,
    MethodKind, RequestStream, ResponseStream, Server, ServiceDef,
};
pub use dynamic::{
    decode_generic, dynamic_service, encode_generic, parse_descriptor_set, DynamicClient,
    DynamicHandler, DynamicSink, FieldModel, FileModel, GenericMessage, GenericValue, MessageModel,
    MethodModel, ServiceModel,
};
pub use status::{Code, Metadata, Status};

/// Monotonic clock seam for deadlines. Native builds use
/// [`std::time::Instant`]. On wasm32, `std::time::Instant::now()`
/// panics ("time not implemented on this platform"), so this
/// module provides an `Instant` backed by the host's
/// `performance.now()` (falling back to `Date.now()`), with the
/// small slice of the std API the runtime uses.
pub mod platform_time {
    #[cfg(not(target_arch = "wasm32"))]
    pub use std::time::Instant;

    #[cfg(target_arch = "wasm32")]
    fn now_ms() -> f64 {
        let global = js_sys::global();
        if let Ok(performance) =
            js_sys::Reflect::get(&global, &wasm_bindgen::JsValue::from_str("performance"))
        {
            if let Ok(now) =
                js_sys::Reflect::get(&performance, &wasm_bindgen::JsValue::from_str("now"))
            {
                if let Ok(value) = js_sys::Function::from(now).call0(&performance) {
                    if let Some(ms) = value.as_f64() {
                        return ms;
                    }
                }
            }
        }
        js_sys::Date::now()
    }

    /// A monotonic instant in milliseconds since the host's
    /// time origin (`performance.now()`), wasm32 only.
    #[cfg(target_arch = "wasm32")]
    #[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
    pub struct Instant(pub(crate) f64);

    #[cfg(target_arch = "wasm32")]
    impl Instant {
        pub fn now() -> Self {
            Self(now_ms())
        }

        pub fn saturating_duration_since(&self, earlier: Instant) -> std::time::Duration {
            let ms = self.0 - earlier.0;
            if ms.is_finite() && ms > 0.0 {
                std::time::Duration::from_millis(ms as u64)
            } else {
                std::time::Duration::ZERO
            }
        }

        pub fn duration_since(&self, earlier: Instant) -> std::time::Duration {
            self.saturating_duration_since(earlier)
        }

        pub fn elapsed(&self) -> std::time::Duration {
            Self::now().saturating_duration_since(*self)
        }
    }

    #[cfg(target_arch = "wasm32")]
    impl std::ops::Add<std::time::Duration> for Instant {
        type Output = Instant;

        fn add(self, duration: std::time::Duration) -> Instant {
            Instant(self.0 + duration.as_secs_f64() * 1000.0)
        }
    }

    #[cfg(target_arch = "wasm32")]
    impl std::ops::AddAssign<std::time::Duration> for Instant {
        fn add_assign(&mut self, duration: std::time::Duration) {
            *self = *self + duration;
        }
    }
}

/// Sleep seam for deadline enforcement, mirroring spawn_task.
/// Public so wasm host crates can delay handlers (slow-call tests):
/// native builds use Tokio's timer; wasm32 builds use the host
/// JavaScript `setTimeout` through a Promise (window or worker).
#[cfg(not(target_arch = "wasm32"))]
pub fn sleep(duration: std::time::Duration) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
    Box::pin(tokio::time::sleep(duration))
}

#[cfg(target_arch = "wasm32")]
struct SendFuture<F>(F);

// Safety: wasm32 browser execution is single-threaded; the wrapped
// JS handles never actually cross a thread boundary.
#[cfg(target_arch = "wasm32")]
unsafe impl<F> Send for SendFuture<F> {}

#[cfg(target_arch = "wasm32")]
impl<F: std::future::Future> std::future::Future for SendFuture<F> {
    type Output = F::Output;

    fn poll(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Self::Output> {
        // Safety: the inner future is only projected, never moved.
        unsafe { std::pin::Pin::new_unchecked(&mut self.get_unchecked_mut().0) }.poll(cx)
    }
}

/// Sleep seam (wasm32: host `setTimeout`, see above).
#[cfg(target_arch = "wasm32")]
pub fn sleep(duration: std::time::Duration) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
    Box::pin(SendFuture(async move {
        let millis = duration.as_millis().min(i32::MAX as u128) as i32;
        let promise = js_sys::Promise::new(&mut |resolve, _reject| {
            let callback = wasm_bindgen::closure::Closure::once_into_js(move || {
                let _ = resolve.call0(&wasm_bindgen::JsValue::NULL);
            });
            let global = js_sys::global();
            if let Ok(set_timeout) =
                js_sys::Reflect::get(&global, &wasm_bindgen::JsValue::from_str("setTimeout"))
            {
                let function = js_sys::Function::from(set_timeout);
                let _ = function.call2(
                    &global,
                    callback.as_ref(),
                    &wasm_bindgen::JsValue::from_f64(millis as f64),
                );
            }
        });
        let _ = wasm_bindgen_futures::JsFuture::from(promise).await;
    }))
}

/// Spawn a background task — the runtime's single executor seam.
/// Native builds use Tokio; on wasm32 the browser event loop drives
/// tasks via wasm-bindgen-futures.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn spawn_task<F>(future: F)
where
    F: std::future::Future<Output = ()> + Send + 'static,
{
    tokio::spawn(future);
}

/// Spawn a background task (wasm32: browser event loop).
#[cfg(target_arch = "wasm32")]
pub(crate) fn spawn_task<F>(future: F)
where
    F: std::future::Future<Output = ()> + 'static,
{
    wasm_bindgen_futures::spawn_local(future);
}
pub use transport::{loopback_pair, DcTransport, InboxDc};
#[cfg(feature = "webrtc")]
pub use transport::{EthDc, EthFramePort};

use std::future::Future;
use std::pin::Pin;

/// A boxed, sendable future — the shape of generated server handlers.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Convenience alias used by generated code and handlers.
pub type Result<T> = std::result::Result<T, Status>;
GRPC_RUNTIME_EOF
)

(define rust-codec-body
#<<GRPC_RUNTIME_EOF
//! Frame codec: one DataChannel message == one frame (SPEC.md).
//!
//! `type:u8 | stream_id:u32be | payload_len:u32be | payload`

use crate::status::{Metadata, Status};
use crate::wire_gen::frame_type;
use bytes::{BufMut, Bytes, BytesMut};
use serde::{Deserialize, Serialize};

pub const HEADER_LEN: usize = 9;
pub const MAX_DATA_PAYLOAD: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub frame_type: u8,
    pub stream_id: u32,
    pub payload: Bytes,
}

impl Frame {
    pub fn new(frame_type: u8, stream_id: u32, payload: impl Into<Bytes>) -> Self {
        Self { frame_type, stream_id, payload: payload.into() }
    }

    pub fn headers(stream_id: u32, headers: &Headers) -> Result<Self, Status> {
        Ok(Self::new(frame_type::HEADERS, stream_id, serde_json::to_vec(headers)?))
    }

    pub fn data(stream_id: u32, payload: impl Into<Bytes>) -> Self {
        Self::new(frame_type::DATA, stream_id, payload)
    }

    pub fn trailers(stream_id: u32, status: &Status) -> Result<Self, Status> {
        let payload = Trailers {
            code: status.code as u32,
            message: status.message.clone(),
            metadata: status.trailers.clone(),
        };
        Ok(Self::new(frame_type::TRAILERS, stream_id, serde_json::to_vec(&payload)?))
    }

    pub fn rst(stream_id: u32, status: &Status) -> Result<Self, Status> {
        let payload = Trailers {
            code: status.code as u32,
            message: status.message.clone(),
            metadata: status.trailers.clone(),
        };
        Ok(Self::new(frame_type::RST, stream_id, serde_json::to_vec(&payload)?))
    }

    pub fn half_close(stream_id: u32) -> Self {
        Self::new(frame_type::HALF_CLOSE, stream_id, Bytes::new())
    }

    pub fn encode(&self) -> Result<Bytes, Status> {
        if !matches!(
            self.frame_type,
            frame_type::HEADERS | frame_type::DATA | frame_type::TRAILERS | frame_type::HALF_CLOSE | frame_type::RST
        ) {
            return Err(Status::invalid_argument(format!("unknown frame type {}", self.frame_type)));
        }
        if self.frame_type == frame_type::DATA && self.payload.len() > MAX_DATA_PAYLOAD {
            return Err(Status::new(
                crate::wire_gen::Code::ResourceExhausted,
                "DATA payload exceeds 16 MiB",
            ));
        }
        let mut out = BytesMut::with_capacity(HEADER_LEN + self.payload.len());
        out.put_u8(self.frame_type);
        out.put_u32(self.stream_id);
        out.put_u32(self.payload.len() as u32);
        out.extend_from_slice(&self.payload);
        Ok(out.freeze())
    }

    pub fn decode(msg: &[u8]) -> Result<Self, Status> {
        if msg.len() < HEADER_LEN {
            return Err(Status::invalid_argument(format!(
                "frame shorter than 9-byte header: {} bytes",
                msg.len()
            )));
        }
        let frame_type = msg[0];
        let stream_id = u32::from_be_bytes([msg[1], msg[2], msg[3], msg[4]]);
        let len = u32::from_be_bytes([msg[5], msg[6], msg[7], msg[8]]) as usize;
        if len != msg.len() - HEADER_LEN {
            return Err(Status::invalid_argument(format!(
                "payload length {len} does not match message size {}",
                msg.len()
            )));
        }
        Ok(Self { frame_type, stream_id, payload: Bytes::copy_from_slice(&msg[HEADER_LEN..]) })
    }

    pub fn parse_headers(&self) -> Result<Headers, Status> {
        Ok(serde_json::from_slice(&self.payload)?)
    }

    pub fn parse_status(&self) -> Result<Status, Status> {
        let t: Trailers = serde_json::from_slice(&self.payload)?;
        let mut status = Status::from_code_u32(t.code, t.message);
        status.trailers = t.metadata;
        Ok(status)
    }
}

/// gRPC timeout grammar (grpc-timeout metadata): `<digits><unit>`,
/// units H/M/S/m/u/n (at most 8 digits). Encoding uses
/// milliseconds (seconds past the digit limit), rounded up so a
/// deadline never shrinks in propagation.
pub fn encode_timeout(timeout: std::time::Duration) -> String {
    let mut ms = timeout.as_millis();
    if timeout.subsec_nanos() % 1_000_000 > 0 {
        ms += 1;
    }
    if ms <= 99_999_999 {
        format!("{ms}m")
    } else {
        format!("{}S", timeout.as_secs() + u64::from(timeout.subsec_nanos() > 0))
    }
}

/// Decode a grpc-timeout value; None when malformed.
pub fn parse_timeout(text: &str) -> Option<std::time::Duration> {
    let (digits, unit) = text.split_at(text.len().checked_sub(1)?);
    if digits.is_empty() || digits.len() > 8 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n: u64 = digits.parse().ok()?;
    let d = match unit {
        "H" => std::time::Duration::from_secs(n * 3600),
        "M" => std::time::Duration::from_secs(n * 60),
        "S" => std::time::Duration::from_secs(n),
        "m" => std::time::Duration::from_millis(n),
        "u" => std::time::Duration::from_micros(n),
        "n" => std::time::Duration::from_nanos(n),
        _ => return None,
    };
    Some(d)
}

/// HEADERS payload. The client sends `path` + `metadata`; the server's
/// initial-metadata HEADERS carries an empty object.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Headers {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Metadata::is_empty")]
    pub metadata: Metadata,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Trailers {
    code: u32,
    message: String,
    #[serde(default, skip_serializing_if = "Metadata::is_empty")]
    metadata: Metadata,
}

impl From<serde_json::Error> for Status {
    fn from(e: serde_json::Error) -> Self {
        Status::internal(format!("json: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vectors() -> serde_json::Value {
        serde_json::from_str(include_str!("../../fixtures/vectors.json")).expect("vectors.json")
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn golden_frame_vectors() {
        let v = vectors();
        for f in v["frames"].as_array().unwrap() {
            let stream = f["stream"].as_u64().unwrap() as u32;
            let ty = f["type"].as_u64().unwrap() as u8;
            let payload: Vec<u8> = if let Some(s) = f["payload_utf8"].as_str() {
                s.as_bytes().to_vec()
            } else {
                let h = f["payload_hex"].as_str().unwrap();
                (0..h.len()).step_by(2).map(|i| u8::from_str_radix(&h[i..i + 2], 16).unwrap()).collect()
            };
            let frame = Frame::new(ty, stream, payload.clone());
            assert_eq!(hex(&frame.encode().unwrap()), f["hex"].as_str().unwrap(), "encode {}", f["name"]);
            let decoded = Frame::decode(&frame.encode().unwrap()).unwrap();
            assert_eq!(decoded, frame, "decode {}", f["name"]);
        }
    }

    #[test]
    fn rejects_malformed_frames() {
        assert!(Frame::decode(&[1, 2, 3]).is_err());
        let mut bad = Frame::data(1, vec![1u8, 2]).encode().unwrap().to_vec();
        bad[8] = 99; // corrupt length
        assert!(Frame::decode(&bad).is_err());
        assert!(Frame::new(99, 1, Vec::new()).encode().is_err());
    }
}
GRPC_RUNTIME_EOF
)

(define rust-status-body
#<<GRPC_RUNTIME_EOF
//! gRPC status: a [`Code`] (generated by grpc-dc codegen) plus a message.

pub use crate::wire_gen::Code;
use std::collections::HashMap;
use std::fmt;

pub type Metadata = HashMap<String, String>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub code: Code,
    pub message: String,
    /// Trailing metadata carried by a status frame (empty when
    /// the peer sent none).
    pub trailers: Metadata,
}

impl Status {
    pub fn new(code: Code, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), trailers: Metadata::new() }
    }
    pub fn ok() -> Self {
        Self::new(Code::Ok, "")
    }
    pub fn cancelled(message: impl Into<String>) -> Self {
        Self::new(Code::Cancelled, message)
    }
    pub fn unknown(message: impl Into<String>) -> Self {
        Self::new(Code::Unknown, message)
    }
    pub fn invalid_argument(message: impl Into<String>) -> Self {
        Self::new(Code::InvalidArgument, message)
    }
    pub fn unimplemented(message: impl Into<String>) -> Self {
        Self::new(Code::Unimplemented, message)
    }
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(Code::Internal, message)
    }
    pub fn unavailable(message: impl Into<String>) -> Self {
        Self::new(Code::Unavailable, message)
    }
    pub fn from_code_u32(code: u32, message: impl Into<String>) -> Self {
        Self::new(Code::from_u32(code).unwrap_or(Code::Unknown), message)
    }
    pub fn is_ok(&self) -> bool {
        self.code == Code::Ok
    }
}

impl fmt::Display for Status {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code.name(), self.message)
    }
}

impl std::error::Error for Status {}

// ---------------------------------------------------------------------------
// Homegrown tracing (W3C traceparent propagation)
// ---------------------------------------------------------------------------
// Tracing support lives here so every module can reach it.
// Dormant until a tracer is registered; generated code stays
// dependency-free (sampling and export are the app's problem).

/// Span observer (kind is "client" or "server").
pub trait Tracer: Send + Sync {
    fn on_start(&self, kind: &str, method: &str, trace_id: &str, span_id: &str, parent_span_id: &str);
    fn on_end(&self, kind: &str, method: &str, trace_id: &str, span_id: &str, status: &str);
}

/// One in-flight span's context.
#[derive(Clone, Debug)]
pub struct TraceContext {
    pub trace_id: String,
    pub span_id: String,
    pub parent_span_id: String,
}

/// Parsed traceparent parent.
#[derive(Clone, Debug)]
pub struct TraceParent {
    pub trace_id: String,
    pub span_id: String,
}

static TRACER: std::sync::OnceLock<std::sync::RwLock<Option<std::sync::Arc<dyn Tracer>>>> =
    std::sync::OnceLock::new();

fn tracer_slot() -> &'static std::sync::RwLock<Option<std::sync::Arc<dyn Tracer>>> {
    TRACER.get_or_init(|| std::sync::RwLock::new(None))
}

/// Register the global span observer (None disables tracing).
pub fn set_tracer(tracer: Option<std::sync::Arc<dyn Tracer>>) {
    *tracer_slot().write().unwrap() = tracer;
}

/// Whether a tracer is registered.
pub fn tracing_enabled() -> bool {
    tracer_slot().read().unwrap().is_some()
}

static TRACE_FILTER: std::sync::OnceLock<std::sync::RwLock<Vec<String>>> =
    std::sync::OnceLock::new();

fn trace_filter_slot() -> &'static std::sync::RwLock<Vec<String>> {
    TRACE_FILTER.get_or_init(|| std::sync::RwLock::new(Vec::new()))
}

/// Restrict traced methods: `;`-separated paths, a trailing
/// `*` means prefix match (`/echo.Echo/*`). Empty = trace all.
pub fn set_trace_filter(patterns: &str) {
    *trace_filter_slot().write().unwrap() =
        patterns.split(';').filter(|p| !p.is_empty()).map(str::to_string).collect();
}

fn trace_allowed(method: &str) -> bool {
    let filter = trace_filter_slot().read().unwrap();
    if filter.is_empty() {
        return true;
    }
    filter.iter().any(|p| {
        if let Some(prefix) = p.strip_suffix('*') {
            method.starts_with(prefix)
        } else {
            method == p
        }
    })
}

fn random_hex(bytes_len: usize) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let mut state = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
        ^ COUNTER.fetch_add(0x9e37_79b9_7f4a_7c15, Ordering::Relaxed);
    const DIGITS: &[u8] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes_len * 2);
    for _ in 0..bytes_len {
        // xorshift64
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let b = (state >> 32) as u8;
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 0xf) as usize] as char);
    }
    out
}

pub fn format_traceparent(trace_id: &str, span_id: &str) -> String {
    format!("00-{trace_id}-{span_id}-01")
}

pub fn parse_traceparent(value: Option<&String>) -> Option<TraceParent> {
    let value = value?;
    let parts: Vec<&str> = value.split('-').collect();
    if parts.len() != 4 || parts[1].len() != 32 || parts[2].len() != 16 {
        return None;
    }
    if !parts[1].bytes().all(|b| b.is_ascii_hexdigit())
        || !parts[2].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return None;
    }
    Some(TraceParent {
        trace_id: parts[1].to_string(),
        span_id: parts[2].to_string(),
    })
}

/// Begin a span; returns None when tracing is dormant.
pub fn trace_start(kind: &str, method: &str, parent: Option<TraceParent>) -> Option<TraceContext> {
    if !trace_allowed(method) {
        return None;
    }
    let tracer = tracer_slot().read().unwrap().clone()?;
    let ctx = TraceContext {
        trace_id: parent
            .as_ref()
            .map(|p| p.trace_id.clone())
            .unwrap_or_else(|| random_hex(16)),
        span_id: random_hex(8),
        parent_span_id: parent.map(|p| p.span_id).unwrap_or_default(),
    };
    tracer.on_start(kind, method, &ctx.trace_id, &ctx.span_id, &ctx.parent_span_id);
    Some(ctx)
}

/// End a span started with trace_start.
pub fn trace_end(kind: &str, method: &str, ctx: Option<&TraceContext>, status: &str) {
    let (Some(tracer), Some(ctx)) = (tracer_slot().read().unwrap().clone(), ctx) else {
        return;
    };
    tracer.on_end(kind, method, &ctx.trace_id, &ctx.span_id, status);
}

impl From<String> for Status {
    fn from(message: String) -> Self {
        Status::unknown(message)
    }
}

impl From<&str> for Status {
    fn from(message: &str) -> Self {
        Status::unknown(message.to_string())
    }
}
GRPC_RUNTIME_EOF
)

(define rust-message-body
#<<GRPC_RUNTIME_EOF
//! The message contract generated code relies on.
//!
//! Hand-written message types implement this directly; the
//! generated message types (`rust/gen/echo_pb.rs`) get impls from
//! `examples/echo_demo/pb_message_impl.rs`. With the `prost`
//! feature, every `prost::Message` type implements it automatically.
//! Raw `Bytes` and `Vec<u8>` pass through unchanged for byte-level callers.

use crate::status::Status;
use bytes::Bytes;

pub trait Message: Sized + Send {
    fn encode(&self) -> Vec<u8>;
    fn decode(bytes: &[u8]) -> Result<Self, Status>;
}

impl Message for Bytes {
    fn encode(&self) -> Vec<u8> {
        self.to_vec()
    }
    fn decode(bytes: &[u8]) -> Result<Self, Status> {
        Ok(Bytes::copy_from_slice(bytes))
    }
}

impl Message for Vec<u8> {
    fn encode(&self) -> Vec<u8> {
        self.clone()
    }
    fn decode(bytes: &[u8]) -> Result<Self, Status> {
        Ok(bytes.to_vec())
    }
}

/// With the `prost` feature, implement [`Message`] for prost-generated
/// types with one line per message (a blanket impl would violate coherence
/// against the raw `Bytes`/`Vec<u8>` impls above):
///
/// ```ignore
/// grpc_dc::impl_message_via_prost!(crate::pb::EchoRequest);
/// ```
#[cfg(feature = "prost")]
#[macro_export]
macro_rules! impl_message_via_prost {
    ($t:ty) => {
        impl $crate::Message for $t {
            fn encode(&self) -> Vec<u8> {
                prost::Message::encode_to_vec(self)
            }
            fn decode(bytes: &[u8]) -> Result<Self, $crate::Status> {
                prost::Message::decode(bytes).map_err(|e| {
                    $crate::Status::invalid_argument(format!("protobuf decode: {e}"))
                })
            }
        }
    };
}
GRPC_RUNTIME_EOF
)

(define rust-transport-body
#<<GRPC_RUNTIME_EOF
//! Transport abstraction over an already-open data channel.
//!
//! [`DcTransport`] is the only seam between this crate and a WebRTC stack:
//! messages go out whole (DataChannels preserve boundaries) and come in
//! whole. To plug in a real `RTCDataChannel` (for example the `webrtc`
//! crate): wire its `on_message` callback to the sender half of
//! [`inbox_dc`], and drain the receiver half into its `send` method —
//! [`InboxDc`] is exactly that adapter. Signaling stays with the caller.

use crate::status::Status;
use async_trait::async_trait;
use bytes::Bytes;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};

#[async_trait]
pub trait DcTransport: Send + Sync {
    /// Send one whole DataChannel message.
    async fn send(&self, msg: Bytes) -> Result<(), Status>;
    /// Receive the next whole message; `None` means the channel closed.
    async fn next(&self) -> Option<Result<Bytes, Status>>;
}

const LOOPBACK_CAPACITY: usize = 128;

/// In-memory transport with bounded queues (backpressure via `send`).
pub struct LoopbackDc {
    tx: mpsc::Sender<Bytes>,
    rx: Mutex<mpsc::Receiver<Bytes>>,
}

/// A connected pair of in-memory transports with `RTCDataChannel`-like
/// semantics: message boundaries preserved, ordered, reliable.
pub fn loopback_pair() -> (LoopbackDc, LoopbackDc) {
    let (a_tx, a_rx) = mpsc::channel(LOOPBACK_CAPACITY);
    let (b_tx, b_rx) = mpsc::channel(LOOPBACK_CAPACITY);
    (
        LoopbackDc { tx: a_tx, rx: Mutex::new(b_rx) },
        LoopbackDc { tx: b_tx, rx: Mutex::new(a_rx) },
    )
}

#[async_trait]
impl DcTransport for LoopbackDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        self.tx.send(msg).await.map_err(|_| Status::unavailable("data channel closed"))
    }
    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut rx = self.rx.lock().await;
        rx.recv().await.map(Ok)
    }
}

/// Adapter for callback/event-driven RTC stacks: feed inbound messages
/// into the returned sender, forward outbound messages from the returned
/// receiver to the channel's `send`.
pub struct InboxDc {
    tx: mpsc::Sender<Bytes>,
    rx: Mutex<mpsc::Receiver<Bytes>>,
}

pub fn inbox_dc() -> (Arc<InboxDc>, mpsc::Sender<Bytes>, mpsc::Receiver<Bytes>) {
    let (in_tx, in_rx) = mpsc::channel(LOOPBACK_CAPACITY);
    let (out_tx, out_rx) = mpsc::channel(LOOPBACK_CAPACITY);
    (Arc::new(InboxDc { tx: out_tx, rx: Mutex::new(in_rx) }), in_tx, out_rx)
}

#[async_trait]
impl DcTransport for InboxDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        self.tx.send(msg).await.map_err(|_| Status::unavailable("data channel closed"))
    }
    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut rx = self.rx.lock().await;
        rx.recv().await.map(Ok)
    }
}

/// One raw Ethernet port: the only NIC-driver seam of [`EthDc`].
/// `dc_webrtc::net::RawEthernetPort` (the virtual cable) implements
/// it; an embedded target implements it over its NIC driver
/// (blocking `recv_frame` with a timeout, `None` on expiry).
#[cfg(feature = "webrtc")]
pub trait EthFramePort: Send + Sync {
    /// Put one whole Ethernet II frame on the wire.
    fn send_frame(&self, frame: Vec<u8>);
    /// Next inbound frame; `None` on timeout.
    fn recv_frame(&self, timeout: std::time::Duration) -> Option<Vec<u8>>;
}

#[cfg(feature = "webrtc")]
impl EthFramePort for dc_webrtc::net::RawEthernetPort {
    fn send_frame(&self, frame: Vec<u8>) {
        dc_webrtc::net::RawEthernetPort::send_frame(self, frame)
    }
    fn recv_frame(&self, timeout: std::time::Duration) -> Option<Vec<u8>> {
        dc_webrtc::net::RawEthernetPort::recv_frame(self, timeout)
    }
}

/// `DcTransport` over raw Ethernet framing (EtherType 0x88B5,
/// `dc_webrtc::net::EthFraming`): whole wire messages travel
/// directly in Ethernet II frames to one peer MAC — no IP, UDP, or
/// ICE — for bare-metal targets whose only network surface is a
/// NIC driver. A background thread pumps inbound frames into the
/// message queue; a lost fragment drops its message (see
/// `EthFraming` for the documented reliability limits).
#[cfg(feature = "webrtc")]
pub struct EthDc {
    framing: std::sync::Mutex<dc_webrtc::net::EthFraming>,
    port: Arc<dyn EthFramePort>,
    rx: Mutex<mpsc::Receiver<Bytes>>,
}

#[cfg(feature = "webrtc")]
impl EthDc {
    pub fn new(
        local: dc_webrtc::net::MacAddr,
        peer: dc_webrtc::net::MacAddr,
        port: Arc<dyn EthFramePort>,
    ) -> Arc<Self> {
        let (tx, rx) = mpsc::channel(LOOPBACK_CAPACITY);
        let framing = std::sync::Mutex::new(dc_webrtc::net::EthFraming::new(local, peer));
        let shared = Arc::new(EthDc { framing, port, rx: Mutex::new(rx) });
        let pump = shared.clone();
        std::thread::spawn(move || loop {
            match pump.port.recv_frame(std::time::Duration::from_millis(50)) {
                Some(frame) => {
                    let msg = pump.framing.lock().unwrap().input(&frame);
                    if let Some(msg) = msg {
                        if tx.blocking_send(Bytes::from(msg)).is_err() {
                            return;
                        }
                    }
                }
                None => {
                    if tx.is_closed() {
                        return;
                    }
                }
            }
        });
        shared
    }
}

#[cfg(feature = "webrtc")]
#[async_trait]
impl DcTransport for EthDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        let mut frames = Vec::new();
        self.framing.lock().unwrap().encode(&msg, &mut frames);
        for frame in frames {
            self.port.send_frame(frame);
        }
        Ok(())
    }
    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut rx = self.rx.lock().await;
        rx.recv().await.map(Ok)
    }
}
GRPC_RUNTIME_EOF
)

(define rust-endpoint-body
#<<GRPC_RUNTIME_EOF
//! Stream multiplexor: one transport, many concurrent calls.
//!
//! An [`Endpoint`] owns the frame reader loop. Client-initiated streams get
//! odd ids from the peer that created the channel and even ids from the
//! answering peer, so a bidirectional peer never collides with itself.

use crate::codec::{Frame, Headers};
use crate::server::{CallCtx, RequestStream, ResponseSink, ServerCall, ServiceDef};
use crate::status::Status;
use crate::transport::DcTransport;
use crate::wire_gen::frame_type;
use bytes::Bytes;
use futures_channel::mpsc::{self, UnboundedReceiver, UnboundedSender};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use tokio::sync::Mutex as AsyncMutex;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamIdParity {
    Odd,
    Even,
}

/// Events delivered to one stream's owner. Headers only flow server→client
/// (initial metadata); Trailers/Rst are terminal.
#[doc(hidden)]
#[derive(Debug)]
pub enum StreamEvent {
    Headers(Headers),
    Data(Bytes),
    HalfClose,
    Trailers(Status),
    Rst(Status),
}

type StreamTx = UnboundedSender<StreamEvent>;

pub struct Endpoint {
    transport: Arc<dyn DcTransport>,
    streams: Mutex<HashMap<u32, StreamTx>>,
    services: RwLock<HashMap<String, crate::server::MethodDef>>,
    next_id: AtomicU32,
    send_lock: AsyncMutex<()>,
    traces: Mutex<HashMap<u32, (crate::status::TraceContext, String)>>,
}

impl Endpoint {
    pub fn new(transport: Arc<dyn DcTransport>, parity: StreamIdParity) -> Arc<Self> {
        Arc::new(Self {
            transport,
            streams: Mutex::new(HashMap::new()),
            services: RwLock::new(HashMap::new()),
            next_id: AtomicU32::new(match parity {
                StreamIdParity::Odd => 1,
                StreamIdParity::Even => 2,
            }),
            send_lock: AsyncMutex::new(()),
            traces: Mutex::new(HashMap::new()),
        })
    }

    /// Record the client span for a locally-initiated stream.
    pub fn set_stream_trace(&self, id: u32, ctx: crate::status::TraceContext, path: String) {
        self.traces.lock().unwrap().insert(id, (ctx, path));
    }

    /// Fire the client span-end hook for a stream, if traced.
    pub fn end_stream_trace(&self, id: u32, status_name: &str) {
        if let Some((ctx, path)) = self.traces.lock().unwrap().remove(&id) {
            crate::status::trace_end("client", &path, Some(&ctx), status_name);
        }
    }

    pub fn register_service(&self, service: ServiceDef) {
        let mut services = self.services.write().unwrap();
        for method in service.methods {
            let path = format!("/{}/{}", service.name, method.name);
            services.insert(path, method);
        }
    }

    /// Allocate a locally-initiated stream and register its event sink.
    pub fn open_stream(&self) -> (u32, UnboundedReceiver<StreamEvent>) {
        let id = self.next_id.fetch_add(2, Ordering::Relaxed);
        let (tx, rx) = mpsc::unbounded();
        self.streams.lock().unwrap().insert(id, tx);
        (id, rx)
    }

    pub fn close_stream(&self, id: u32) {
        self.streams.lock().unwrap().remove(&id);
    }

    pub async fn send_frame(&self, frame: Frame) -> Result<(), Status> {
        let bytes = frame.encode()?;
        let _guard = self.send_lock.lock().await;
        self.transport.send(bytes).await
    }

    fn deliver(&self, stream_id: u32, event: StreamEvent) {
        let mut streams = self.streams.lock().unwrap();
        if let Some(tx) = streams.get(&stream_id) {
            if tx.unbounded_send(event).is_err() {
                streams.remove(&stream_id);
            }
        }
    }

    pub(crate) fn has_stream(&self, stream_id: u32) -> bool {
        self.streams.lock().unwrap().contains_key(&stream_id)
    }

    /// Frame reader loop. Runs until the transport closes, then fails every
    /// live stream with UNAVAILABLE.
    pub async fn run(self: Arc<Self>) {
        while let Some(msg) = self.transport.next().await {
            let msg = match msg {
                Ok(m) => m,
                Err(_) => break,
            };
            let frame = match Frame::decode(&msg) {
                Ok(f) => f,
                Err(_) => continue, // malformed frame: drop, keep the channel up
            };
            self.dispatch(frame).await;
        }
        let leftover: Vec<StreamTx> =
            self.streams.lock().unwrap().drain().map(|(_, tx)| tx).collect();
        for tx in leftover {
            let _ = tx.unbounded_send(StreamEvent::Rst(Status::unavailable("data channel closed")));
        }
    }

    async fn dispatch(self: &Arc<Self>, frame: Frame) {
        @@FRAME_DISPATCH@@
    }

    async fn on_headers(self: &Arc<Self>, frame: Frame) {
        let headers = match frame.parse_headers() {
            Ok(h) => h,
            Err(e) => {
                let _ = self.send_frame(Frame::rst(frame.stream_id, &e).unwrap()).await;
                return;
            }
        };
        match headers.path.clone() {
            None => {
                // Server initial metadata for one of our outbound streams.
                self.deliver(frame.stream_id, StreamEvent::Headers(headers));
            }
            Some(path) => {
                if self.has_stream(frame.stream_id) {
                    let _ = self
                        .send_frame(
                            Frame::rst(
                                frame.stream_id,
                                &Status::internal("HEADERS for stream already in use"),
                            )
                            .unwrap(),
                        )
                        .await;
                    return;
                }
                let handler = {
                    let services = self.services.read().unwrap();
                    services.get(&path).map(|m| m.handler.clone())
                };
                let Some(handler) = handler else {
                    let _ = self
                        .send_frame(
                            Frame::trailers(
                                frame.stream_id,
                                &Status::unimplemented(format!("unknown method {path}")),
                            )
                            .unwrap(),
                        )
                        .await;
                    return;
                };
                let (tx, rx) = mpsc::unbounded();
                self.streams.lock().unwrap().insert(frame.stream_id, tx);
                // No eager HEADERS: initial metadata flushes
                // lazily via the sink (first DATA, or below on a
                // DATA-less success) so handlers can set_headers
                // first. Errors end trailers-only, as gRPC allows.
                let response_meta: crate::server::SharedMeta = Default::default();
                let sink = ResponseSink::new(self.clone(), frame.stream_id, response_meta.clone());
                let flush_sink = sink.clone();
                let call = ServerCall {
                    ctx: CallCtx {
                        path: path.clone(),
                        metadata: headers.metadata.clone(),
                        stream_id: frame.stream_id,
                        deadline: headers
                            .metadata
                            .get("grpc-timeout")
                            .and_then(|t| crate::codec::parse_timeout(t))
                            .map(|d| crate::platform_time::Instant::now() + d),
                        response_meta: response_meta.clone(),
                    },
                    requests: RequestStream::<Bytes>::from_events(rx),
                    sink,
                };
                let trace_ctx = crate::status::trace_start(
                    "server",
                    &path,
                    crate::status::parse_traceparent(headers.metadata.get("traceparent")),
                );
                let ep = self.clone();
                let stream_id = frame.stream_id;
                crate::spawn_task(async move {
                    let mut status = match handler(call).await {
                        Ok(()) => Status::ok(),
                        Err(s) => s,
                    };
                    crate::status::trace_end(
                        "server",
                        &path,
                        trace_ctx.as_ref(),
                        status.code.name(),
                    );
                    if status.is_ok() {
                        let _ = flush_sink.flush_headers().await;
                    }
                    {
                        let meta = response_meta.lock().unwrap();
                        for (k, v) in &meta.trailers {
                            status.trailers.entry(k.clone()).or_insert_with(|| v.clone());
                        }
                    }
                    let _ = ep.send_frame(Frame::trailers(stream_id, &status).unwrap()).await;
                    ep.close_stream(stream_id);
                });
            }
        }
    }
}

/// A bidirectional peer: client and server over the same channel.
/// The reader loop is spawned on construction (needs a Tokio runtime).
pub struct Peer {
    ep: Arc<Endpoint>,
}

impl Peer {
    pub fn new(transport: Arc<dyn DcTransport>, parity: StreamIdParity) -> Self {
        let ep = Endpoint::new(transport, parity);
        crate::spawn_task(ep.clone().run());
        Self { ep }
    }

    pub fn channel(&self) -> crate::channel::Channel {
        crate::channel::Channel::from_endpoint(self.ep.clone())
    }

    pub fn server(&self) -> crate::server::Server {
        crate::server::Server::from_endpoint(self.ep.clone())
    }

    pub fn endpoint(&self) -> Arc<Endpoint> {
        self.ep.clone()
    }
}
GRPC_RUNTIME_EOF
)

(define rust-channel-body
#<<GRPC_RUNTIME_EOF
//! Client side: a [`Channel`] opens streams on one endpoint and speaks
//! all four gRPC method shapes. Metadata-carrying `*_with` variants mirror
//! the plain ones.

use crate::codec::{encode_timeout, Frame, Headers};
use crate::endpoint::{Endpoint, StreamEvent, StreamIdParity};
use crate::message::Message;
use crate::server::ResponseStream;
use crate::status::{Code, Metadata, Status};
use crate::transport::DcTransport;
use futures_channel::mpsc::UnboundedReceiver;
use futures_core::Stream;
use futures_util::StreamExt;
use std::sync::Arc;
use std::time::Duration;

use crate::platform_time::Instant;

/// Per-call options: metadata plus an optional deadline timeout.
/// The timeout is propagated as grpc-timeout metadata and enforced
/// locally — on expiry the stream is aborted (RST) and
/// DEADLINE_EXCEEDED is returned.
#[derive(Clone, Debug, Default)]
pub struct CallOptions {
    pub metadata: Metadata,
    pub timeout: Option<Duration>,
    /// When set, response initial metadata is copied into the
    /// sink as it arrives.
    pub response_headers: Option<SharedMetaSink>,
    /// When set, response trailing metadata is copied into the
    /// sink with the terminal status.
    pub response_trailers: Option<SharedMetaSink>,
}

/// Shared capture slot for response metadata.
pub type SharedMetaSink = Arc<std::sync::Mutex<Metadata>>;

/// (headers sink, trailers sink) lifted from CallOptions.
pub type Capture = (Option<SharedMetaSink>, Option<SharedMetaSink>);

/// Copy response metadata into a capture sink, when present.
pub fn fill_capture(sink: &Option<SharedMetaSink>, metadata: &Metadata) {
    if let Some(sink) = sink {
        *sink.lock().unwrap() = metadata.clone();
    }
}

impl CallOptions {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_timeout(timeout: Duration) -> Self {
        Self { metadata: Metadata::new(), timeout: Some(timeout), ..Default::default() }
    }

    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = Some(timeout);
        self
    }

    pub fn metadata(mut self, metadata: Metadata) -> Self {
        self.metadata = metadata;
        self
    }

    /// Capture response initial metadata into `sink`.
    pub fn capture_headers(mut self, sink: SharedMetaSink) -> Self {
        self.response_headers = Some(sink);
        self
    }

    /// Capture response trailing metadata into `sink`.
    pub fn capture_trailers(mut self, sink: SharedMetaSink) -> Self {
        self.response_trailers = Some(sink);
        self
    }
}

impl From<Metadata> for CallOptions {
    fn from(metadata: Metadata) -> Self {
        Self { metadata, timeout: None, ..Default::default() }
    }
}

/// Next stream event, enforcing an optional deadline instant.
async fn next_with_deadline(
    ep: &Arc<Endpoint>,
    id: u32,
    rx: &mut UnboundedReceiver<StreamEvent>,
    deadline: Option<Instant>,
) -> Result<Option<StreamEvent>, Status> {
    let Some(deadline) = deadline else {
        return Ok(rx.next().await);
    };
    let remaining = deadline.saturating_duration_since(Instant::now());
    match futures_util::future::select(rx.next(), crate::sleep(remaining)).await {
        futures_util::future::Either::Left((event, _)) => Ok(event),
        futures_util::future::Either::Right(((), _)) => {
            let _ = ep
                .send_frame(
                    Frame::rst(id, &Status::cancelled("deadline exceeded")).unwrap(),
                )
                .await;
            ep.close_stream(id);
            Err(Status::new(Code::DeadlineExceeded, "deadline exceeded"))
        }
    }
}

#[derive(Clone)]
pub struct Channel {
    ep: Arc<Endpoint>,
}

impl Channel {
    /// Client over a fresh endpoint; this peer created the channel, so it
    /// allocates odd stream ids. Spawns the reader loop (Tokio runtime
    /// required, like any async constructor side effect).
    pub fn new(transport: Arc<dyn DcTransport>) -> Self {
        Self::with_parity(transport, StreamIdParity::Odd)
    }

    pub fn with_parity(transport: Arc<dyn DcTransport>, parity: StreamIdParity) -> Self {
        let ep = Endpoint::new(transport, parity);
        crate::spawn_task(ep.clone().run());
        Self { ep }
    }

    pub fn from_endpoint(ep: Arc<Endpoint>) -> Self {
        Self { ep }
    }

    pub fn endpoint(&self) -> Arc<Endpoint> {
        self.ep.clone()
    }

    async fn open_with_options(
        &self,
        path: &str,
        mut options: CallOptions,
    ) -> Result<(u32, UnboundedReceiver<StreamEvent>, Option<Instant>, Capture), Status> {
        let capture: Capture = (options.response_headers.clone(), options.response_trailers.clone());
        let deadline = options.timeout.map(|timeout| {
            options
                .metadata
                .insert("grpc-timeout".to_string(), encode_timeout(timeout));
            Instant::now() + timeout
        });
        let mut metadata = options.metadata;
        let mut trace_ctx = None;
        if crate::status::tracing_enabled() {
            trace_ctx = crate::status::trace_start(
                "client",
                path,
                crate::status::parse_traceparent(metadata.get("traceparent")),
            );
            if let Some(ctx) = &trace_ctx {
                metadata.insert(
                    "traceparent".to_string(),
                    crate::status::format_traceparent(&ctx.trace_id, &ctx.span_id),
                );
            }
        }
        let (id, rx) = self.ep.open_stream();
        if let Some(ctx) = trace_ctx {
            self.ep.set_stream_trace(id, ctx, path.to_string());
        }
        let headers = Headers { path: Some(path.to_string()), metadata };
        match self.ep.send_frame(Frame::headers(id, &headers)?).await {
            Ok(()) => Ok((id, rx, deadline, capture)),
            Err(e) => {
                self.ep.end_stream_trace(id, "UNAVAILABLE");
                self.ep.close_stream(id);
                Err(e)
            }
        }
    }

    async fn send_data<Req: Message>(&self, id: u32, req: &Req) -> Result<(), Status> {
        self.ep.send_frame(Frame::data(id, req.encode())).await
    }

    async fn collect_one_with_deadline<Resp: Message>(
        &self,
        id: u32,
        mut rx: UnboundedReceiver<StreamEvent>,
        deadline: Option<Instant>,
        capture: Capture,
    ) -> Result<Resp, Status> {
        let mut response: Option<Resp> = None;
        let result = loop {
            match next_with_deadline(&self.ep, id, &mut rx, deadline).await {
                Err(status) => break Err(status),
                Ok(Some(StreamEvent::Headers(headers))) => {
                    fill_capture(&capture.0, &headers.metadata);
                    continue;
                }
                Ok(Some(StreamEvent::Data(bytes))) => match Resp::decode(&bytes) {
                    Ok(msg) => {
                        if response.is_some() {
                            break Err(Status::internal("unary call received more than one response"));
                        }
                        response = Some(msg);
                    }
                    Err(e) => break Err(e),
                },
                Ok(Some(StreamEvent::Trailers(status))) => {
                    fill_capture(&capture.1, &status.trailers);
                    self.ep.end_stream_trace(id, status.code.name());
                    if status.is_ok() {
                        match response {
                            Some(msg) => break Ok(msg),
                            None => {
                                break Err(Status::internal("call closed with no response"));
                            }
                        }
                    } else {
                        break Err(status);
                    }
                }
                Ok(Some(StreamEvent::Rst(status))) => {
                    fill_capture(&capture.1, &status.trailers);
                    self.ep.end_stream_trace(id, status.code.name());
                    break Err(status)
                }
                Ok(Some(StreamEvent::HalfClose)) => continue,
                Ok(None) => break Err(Status::unavailable("data channel closed")),
            }
        };
        self.ep.close_stream(id);
        result
    }

    // -- unary ---------------------------------------------------------------
    pub async fn unary<Req, Resp>(&self, path: &str, req: Req) -> Result<Resp, Status>
    where
        Req: Message,
        Resp: Message,
    {
        self.unary_with(path, req, Metadata::new()).await
    }

    pub async fn unary_with<Req, Resp>(
        &self,
        path: &str,
        req: Req,
        metadata: Metadata,
    ) -> Result<Resp, Status>
    where
        Req: Message,
        Resp: Message,
    {
        self.unary_with_options(path, req, CallOptions { metadata, timeout: None, ..Default::default() })
            .await
    }

    pub async fn unary_with_options<Req, Resp>(
        &self,
        path: &str,
        req: Req,
        options: CallOptions,
    ) -> Result<Resp, Status>
    where
        Req: Message,
        Resp: Message,
    {
        let (id, rx, deadline, capture) = self.open_with_options(path, options).await?;
        self.send_data(id, &req).await?;
        self.ep.send_frame(Frame::half_close(id)).await?;
        self.collect_one_with_deadline(id, rx, deadline, capture).await
    }

    // -- server-streaming ------------------------------------------------------
    pub async fn server_stream<Req, Resp>(
        &self,
        path: &str,
        req: Req,
    ) -> Result<ResponseStream<Resp>, Status>
    where
        Req: Message,
        Resp: Message + 'static,
    {
        self.server_stream_with(path, req, Metadata::new()).await
    }

    pub async fn server_stream_with<Req, Resp>(
        &self,
        path: &str,
        req: Req,
        metadata: Metadata,
    ) -> Result<ResponseStream<Resp>, Status>
    where
        Req: Message,
        Resp: Message + 'static,
    {
        self.server_stream_with_options(path, req, CallOptions { metadata, timeout: None, ..Default::default() })
            .await
    }

    pub async fn server_stream_with_options<Req, Resp>(
        &self,
        path: &str,
        req: Req,
        options: CallOptions,
    ) -> Result<ResponseStream<Resp>, Status>
    where
        Req: Message,
        Resp: Message + 'static,
    {
        let (id, rx, deadline, capture) = self.open_with_options(path, options).await?;
        self.send_data(id, &req).await?;
        self.ep.send_frame(Frame::half_close(id)).await?;
        Ok(typed_response_stream(self.ep.clone(), id, rx, deadline, capture))
    }

    // -- client-streaming ------------------------------------------------------
    pub async fn client_stream<Req, Resp, S>(
        &self,
        path: &str,
        reqs: S,
    ) -> Result<Resp, Status>
    where
        Req: Message + 'static,
        Resp: Message,
        S: Stream<Item = Req> + Send + 'static,
    {
        self.client_stream_with(path, reqs, Metadata::new()).await
    }

    pub async fn client_stream_with<Req, Resp, S>(
        &self,
        path: &str,
        reqs: S,
        metadata: Metadata,
    ) -> Result<Resp, Status>
    where
        Req: Message + 'static,
        Resp: Message,
        S: Stream<Item = Req> + Send + 'static,
    {
        self.client_stream_with_options(path, reqs, CallOptions { metadata, timeout: None, ..Default::default() })
            .await
    }

    pub async fn client_stream_with_options<Req, Resp, S>(
        &self,
        path: &str,
        reqs: S,
        options: CallOptions,
    ) -> Result<Resp, Status>
    where
        Req: Message + 'static,
        Resp: Message,
        S: Stream<Item = Req> + Send + 'static,
    {
        let (id, rx, deadline, capture) = self.open_with_options(path, options).await?;
        self.spawn_pump(id, reqs);
        self.collect_one_with_deadline(id, rx, deadline, capture).await
    }

    // -- bidirectional ---------------------------------------------------------
    pub async fn bidi<Req, Resp, S>(
        &self,
        path: &str,
        reqs: S,
    ) -> Result<ResponseStream<Resp>, Status>
    where
        Req: Message + 'static,
        Resp: Message + 'static,
        S: Stream<Item = Req> + Send + 'static,
    {
        self.bidi_with(path, reqs, Metadata::new()).await
    }

    pub async fn bidi_with<Req, Resp, S>(
        &self,
        path: &str,
        reqs: S,
        metadata: Metadata,
    ) -> Result<ResponseStream<Resp>, Status>
    where
        Req: Message + 'static,
        Resp: Message + 'static,
        S: Stream<Item = Req> + Send + 'static,
    {
        self.bidi_with_options(path, reqs, CallOptions { metadata, timeout: None, ..Default::default() })
            .await
    }

    pub async fn bidi_with_options<Req, Resp, S>(
        &self,
        path: &str,
        reqs: S,
        options: CallOptions,
    ) -> Result<ResponseStream<Resp>, Status>
    where
        Req: Message + 'static,
        Resp: Message + 'static,
        S: Stream<Item = Req> + Send + 'static,
    {
        let (id, rx, deadline, capture) = self.open_with_options(path, options).await?;
        self.spawn_pump(id, reqs);
        Ok(typed_response_stream(self.ep.clone(), id, rx, deadline, capture))
    }

    fn spawn_pump<Req, S>(&self, id: u32, reqs: S)
    where
        Req: Message + 'static,
        S: Stream<Item = Req> + Send + 'static,
    {
        let ep = self.ep.clone();
        crate::spawn_task(async move {
            futures_util::pin_mut!(reqs);
            while let Some(req) = reqs.next().await {
                if ep.send_frame(Frame::data(id, req.encode())).await.is_err() {
                    return;
                }
            }
            let _ = ep.send_frame(Frame::half_close(id)).await;
        });
    }

    /// Abort one outbound stream (sends RST CANCELLED).
    pub async fn cancel(&self, stream_id: u32) {
        let _ = self
            .ep
            .send_frame(Frame::rst(stream_id, &Status::cancelled("cancelled by caller")).unwrap())
            .await;
        self.ep.close_stream(stream_id);
    }
}

/// Cancels the call when the response stream is dropped while
/// still live: dropping a stream mid-call RSTs it so the server
/// stops producing instead of streaming into the void.
struct CancelOnDrop {
    ep: Arc<Endpoint>,
    id: u32,
    armed: bool,
}

impl CancelOnDrop {
    fn disarm(&mut self) {
        self.armed = false;
        self.ep.close_stream(self.id);
    }
}

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let ep = self.ep.clone();
        let id = self.id;
        // Best effort: dropped outside the async runtime, the
        // call is simply forgotten locally.
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
            crate::spawn_task(async move {
                let _ = ep
                    .send_frame(
                        Frame::rst(id, &Status::cancelled("cancelled by caller")).unwrap(),
                    )
                    .await;
                ep.close_stream(id);
            });
        }));
    }
}

fn typed_response_stream<Resp>(
    ep: Arc<Endpoint>,
    id: u32,
    rx: UnboundedReceiver<StreamEvent>,
    deadline: Option<Instant>,
    capture: Capture,
) -> ResponseStream<Resp>
where
    Resp: Message + 'static,
{
    let guard = CancelOnDrop { ep, id, armed: true };
    let stream = futures_util::stream::unfold(
        (guard, rx, false, capture),
        move |(mut guard, mut rx, done, capture)| async move {
        if done {
            return None;
        }
        loop {
            match next_with_deadline(&guard.ep, id, &mut rx, deadline).await {
                Err(status) => {
                    guard.disarm();
                    return Some((Err(status), (guard, rx, true, capture)));
                }
                Ok(event) => match event {
                Some(StreamEvent::Headers(headers)) => {
                    fill_capture(&capture.0, &headers.metadata);
                    continue;
                }
                Some(StreamEvent::HalfClose) => continue,
                Some(StreamEvent::Data(bytes)) => match Resp::decode(&bytes) {
                    Ok(msg) => return Some((Ok(msg), (guard, rx, false, capture))),
                    Err(e) => {
                        guard.disarm();
                        return Some((Err(e), (guard, rx, true, capture)));
                    }
                },
                Some(StreamEvent::Trailers(status)) => {
                    fill_capture(&capture.1, &status.trailers);
                    guard.ep.end_stream_trace(id, status.code.name());
                    guard.disarm();
                    return if status.is_ok() {
                        None
                    } else {
                        Some((Err(status), (guard, rx, true, capture)))
                    };
                }
                Some(StreamEvent::Rst(status)) => {
                    fill_capture(&capture.1, &status.trailers);
                    guard.ep.end_stream_trace(id, status.code.name());
                    guard.disarm();
                    return Some((Err(status), (guard, rx, true, capture)))
                }
                None => {
                    guard.disarm();
                    return Some((
                        Err(Status::unavailable("data channel closed")),
                        (guard, rx, true, capture),
                    ))
                }
                },
            }
        }
        },
    );
    Box::pin(stream)
}
GRPC_RUNTIME_EOF
)

(define rust-server-body
#<<GRPC_RUNTIME_EOF
//! Server side: service registry and typed method adapters.
//!
//! Generated code builds a [`ServiceDef`] from a user trait implementation
//! via [`unary_method`]/[`server_stream_method`]/[`client_stream_method`]/
//! [`bidi_method`]; an endpoint dispatches incoming HEADERS by path.

use crate::endpoint::{Endpoint, StreamEvent};
use crate::message::Message;
use crate::status::{Metadata, Status};
use crate::transport::DcTransport;
use crate::BoxFuture;
use bytes::Bytes;
use futures_core::Stream;
use futures_util::StreamExt;
use std::future::Future;
use std::marker::PhantomData;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

/// Response initial/trailing metadata accumulated during one
/// call (handler -> CallCtx, flush -> ResponseSink/endpoint).
#[derive(Debug, Default)]
pub struct ResponseMeta {
    pub headers: Metadata,
    pub trailers: Metadata,
    pub headers_sent: bool,
}

/// Shared per-call response metadata.
pub type SharedMeta = Arc<std::sync::Mutex<ResponseMeta>>;

/// Per-call context handed to handlers.
#[derive(Clone, Debug)]
pub struct CallCtx {
    pub path: String,
    pub metadata: Metadata,
    pub stream_id: u32,
    /// Deadline propagated via grpc-timeout, when the client set one.
    pub deadline: Option<crate::platform_time::Instant>,
    pub(crate) response_meta: SharedMeta,
}

impl CallCtx {
    /// Time left before the deadline, or None when unbounded.
    pub fn time_remaining(&self) -> Option<std::time::Duration> {
        self.deadline
            .map(|d| d.saturating_duration_since(crate::platform_time::Instant::now()))
    }

    pub fn deadline_exceeded(&self) -> bool {
        self.time_remaining() == Some(std::time::Duration::ZERO)
    }

    /// Record response initial metadata (sent lazily, before
    /// the first response message).
    pub fn set_headers(&self, metadata: Metadata) {
        let mut meta = self.response_meta.lock().unwrap();
        for (k, v) in metadata {
            meta.headers.insert(k, v);
        }
    }

    /// Record response trailing metadata (rides the terminal
    /// status frame).
    pub fn set_trailers(&self, metadata: Metadata) {
        let mut meta = self.response_meta.lock().unwrap();
        for (k, v) in metadata {
            meta.trailers.insert(k, v);
        }
    }
}

/// A stream of decoded responses (client side of streaming calls, and the
/// return type of server-streaming handlers).
pub type ResponseStream<T> = Pin<Box<dyn Stream<Item = Result<T, Status>> + Send>>;

/// A stream of requests decoded from DATA frames.
pub struct RequestStream<T> {
    inner: Pin<Box<dyn Stream<Item = Result<Bytes, Status>> + Send>>,
    _marker: PhantomData<fn() -> T>,
}

impl<T> RequestStream<T> {
    pub(crate) fn from_events(
        rx: futures_channel::mpsc::UnboundedReceiver<StreamEvent>,
    ) -> RequestStream<Bytes> {
        let stream = futures_util::stream::unfold(rx, |mut rx| async move {
            loop {
                match rx.next().await {
                    Some(StreamEvent::Data(b)) => return Some((Ok(b), rx)),
                    Some(StreamEvent::HalfClose) => return None,
                    Some(StreamEvent::Rst(s)) | Some(StreamEvent::Trailers(s)) => {
                        return Some((Err(s), rx))
                    }
                    Some(StreamEvent::Headers(_)) => continue,
                    None => return None,
                }
            }
        });
        RequestStream { inner: Box::pin(stream), _marker: PhantomData }
    }

    pub(crate) fn from_bytes(inner: RequestStream<Bytes>) -> Self {
        Self { inner: inner.inner, _marker: PhantomData }
    }
}

impl<T: Message> Stream for RequestStream<T> {
    type Item = Result<T, Status>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        match self.inner.as_mut().poll_next(cx) {
            Poll::Ready(Some(Ok(bytes))) => Poll::Ready(Some(T::decode(&bytes))),
            Poll::Ready(Some(Err(e))) => Poll::Ready(Some(Err(e))),
            Poll::Ready(None) => Poll::Ready(None),
            Poll::Pending => Poll::Pending,
        }
    }
}

/// Writes DATA frames for one server stream.
#[derive(Clone)]
pub struct ResponseSink {
    ep: Arc<Endpoint>,
    stream_id: u32,
    meta: SharedMeta,
}

impl ResponseSink {
    pub(crate) fn new(ep: Arc<Endpoint>, stream_id: u32, meta: SharedMeta) -> Self {
        Self { ep, stream_id, meta }
    }

    /// Send the initial-metadata HEADERS once (with whatever
    /// the handler recorded via CallCtx::set_headers).
    pub async fn flush_headers(&self) -> Result<(), Status> {
        let headers = {
            let mut meta = self.meta.lock().unwrap();
            if meta.headers_sent {
                return Ok(());
            }
            meta.headers_sent = true;
            crate::codec::Headers { path: None, metadata: meta.headers.clone() }
        };
        self.ep.send_frame(crate::codec::Frame::headers(self.stream_id, &headers)?).await
    }

    pub async fn send(&self, payload: Vec<u8>) -> Result<(), Status> {
        // A stream the endpoint has forgotten was RST by the
        // peer (or the channel went away): fail the send so a
        // producing handler stops instead of streaming into
        // the void.
        if !self.ep.has_stream(self.stream_id) {
            return Err(Status::cancelled("call cancelled"));
        }
        self.flush_headers().await?;
        self.ep.send_frame(crate::codec::Frame::data(self.stream_id, payload)).await
    }
}

/// One incoming call, pre-decoding. Adapters (below) wrap this.
pub struct ServerCall {
    pub ctx: CallCtx,
    pub requests: RequestStream<Bytes>,
    pub sink: ResponseSink,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MethodKind {
    Unary,
    ClientStreaming,
    ServerStreaming,
    BidiStreaming,
}

pub type MethodHandler =
    Arc<dyn Fn(ServerCall) -> BoxFuture<'static, Result<(), Status>> + Send + Sync>;

pub struct MethodDef {
    pub name: &'static str,
    pub kind: MethodKind,
    pub handler: MethodHandler,
}

pub struct ServiceDef {
    pub name: String,
    pub methods: Vec<MethodDef>,
}

impl ServiceDef {
    pub fn new(name: impl Into<String>, methods: Vec<MethodDef>) -> Self {
        Self { name: name.into(), methods }
    }
}

// ---------------------------------------------------------------------------
// Typed adapters used by generated code
// ---------------------------------------------------------------------------

pub fn unary_method<Req, Resp, F, Fut>(name: &'static str, f: F) -> MethodDef
where
    Req: Message + 'static,
    Resp: Message + 'static,
    F: Fn(Req, CallCtx) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<Resp, Status>> + Send + 'static,
{
    let f = Arc::new(f);
    MethodDef {
        name,
        kind: MethodKind::Unary,
        handler: Arc::new(move |call| {
            let f = f.clone();
            Box::pin(async move {
                let ServerCall { ctx, requests, sink } = call;
                let mut stream = RequestStream::<Req>::from_bytes(requests);
                let req = match stream.next().await {
                    Some(Ok(req)) => req,
                    Some(Err(e)) => return Err(e),
                    None => {
                        return Err(Status::invalid_argument("missing request message"));
                    }
                };
                let resp = f(req, ctx).await?;
                sink.send(resp.encode()).await
            })
        }),
    }
}

pub fn server_stream_method<Req, Resp, F, Fut>(name: &'static str, f: F) -> MethodDef
where
    Req: Message + 'static,
    Resp: Message + 'static,
    F: Fn(Req, CallCtx) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<ResponseStream<Resp>, Status>> + Send + 'static,
{
    let f = Arc::new(f);
    MethodDef {
        name,
        kind: MethodKind::ServerStreaming,
        handler: Arc::new(move |call| {
            let f = f.clone();
            Box::pin(async move {
                let ServerCall { ctx, requests, sink } = call;
                let mut stream = RequestStream::<Req>::from_bytes(requests);
                let req = match stream.next().await {
                    Some(Ok(req)) => req,
                    Some(Err(e)) => return Err(e),
                    None => {
                        return Err(Status::invalid_argument("missing request message"));
                    }
                };
                let mut responses = f(req, ctx).await?;
                while let Some(item) = responses.next().await {
                    sink.send(item?.encode()).await?;
                }
                Ok(())
            })
        }),
    }
}

pub fn client_stream_method<Req, Resp, F, Fut>(name: &'static str, f: F) -> MethodDef
where
    Req: Message + 'static,
    Resp: Message + 'static,
    F: Fn(RequestStream<Req>, CallCtx) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<Resp, Status>> + Send + 'static,
{
    let f = Arc::new(f);
    MethodDef {
        name,
        kind: MethodKind::ClientStreaming,
        handler: Arc::new(move |call| {
            let f = f.clone();
            Box::pin(async move {
                let ServerCall { ctx, requests, sink } = call;
                let stream = RequestStream::<Req>::from_bytes(requests);
                let resp = f(stream, ctx).await?;
                sink.send(resp.encode()).await
            })
        }),
    }
}

pub fn bidi_method<Req, Resp, F, Fut>(name: &'static str, f: F) -> MethodDef
where
    Req: Message + 'static,
    Resp: Message + 'static,
    F: Fn(RequestStream<Req>, CallCtx) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<ResponseStream<Resp>, Status>> + Send + 'static,
{
    let f = Arc::new(f);
    MethodDef {
        name,
        kind: MethodKind::BidiStreaming,
        handler: Arc::new(move |call| {
            let f = f.clone();
            Box::pin(async move {
                let ServerCall { ctx, requests, sink } = call;
                let stream = RequestStream::<Req>::from_bytes(requests);
                let mut responses = f(stream, ctx).await?;
                while let Some(item) = responses.next().await {
                    sink.send(item?.encode()).await?;
                }
                Ok(())
            })
        }),
    }
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

pub struct Server {
    ep: Arc<Endpoint>,
}

impl Server {
    pub fn from_endpoint(ep: Arc<Endpoint>) -> Self {
        Self { ep }
    }

    pub fn add_service(self, service: ServiceDef) -> Self {
        self.ep.register_service(service);
        self
    }

    /// Serve the given services over one transport until it closes.
    /// This side answers, so it allocates even stream ids for any calls
    /// it initiates itself (see `Peer` for bidirectional use).
    pub async fn serve(transport: Arc<dyn DcTransport>, services: Vec<ServiceDef>) {
        let ep = Endpoint::new(transport, crate::endpoint::StreamIdParity::Even);
        for service in services {
            ep.register_service(service);
        }
        ep.run().await;
    }
}
GRPC_RUNTIME_EOF
)

(define rust-webrtc-transport-body
#<<GRPC_RUNTIME_EOF
//! `DcTransport` over the reimplemented WebRTC stack: one SCTP
//! datachannel from `dc-webrtc` carries gRPC frames. Enabled by the
//! `webrtc` feature. The endpoint's event queue is bridged to async by
//! a small forwarder thread, so no messages are lost between the
//! channel appearing and this transport starting.

use crate::status::Status;
use crate::transport::DcTransport;
use async_trait::async_trait;
use bytes::Bytes;
use dc_webrtc::endpoint::{ChannelHandle, DcEndpoint, EndpointEvent};
use std::sync::Arc;

pub struct WebRtcDc {
    channel: ChannelHandle,
    inbox: tokio::sync::Mutex<tokio::sync::mpsc::UnboundedReceiver<Vec<u8>>>,
    _endpoint: Arc<DcEndpoint>,
}

impl WebRtcDc {
    pub fn new(endpoint: Arc<DcEndpoint>, channel: ChannelHandle) -> Self {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
        let stream = channel.stream;
        let forwarder_endpoint = endpoint.clone();
        std::thread::spawn(move || loop {
            match forwarder_endpoint.recv_event() {
                Some(EndpointEvent::Message { stream: s, data, .. }) if s == stream => {
                    if tx.send(data).is_err() {
                        break;
                    }
                }
                Some(EndpointEvent::ChannelClosed { stream: s }) if s == stream => break,
                Some(_) => {}
                None => break,
            }
        });
        Self {
            channel,
            inbox: tokio::sync::Mutex::new(rx),
            _endpoint: endpoint,
        }
    }
}

#[async_trait]
impl DcTransport for WebRtcDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        self.channel
            .send_binary(&msg)
            .map_err(|e| Status::unavailable(format!("webrtc channel send: {e}")))
    }

    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let data = self.inbox.lock().await.recv().await?;
        Some(Ok(Bytes::from(data)))
    }
}
GRPC_RUNTIME_EOF
)

;; Frame dispatch: match arms are expanded from spec.rkt's frame
;; table, one arm per table entry (frame_type constants as stamped in
;; wire_gen.rs); arm bodies are the per-language handlers.
(define rust-webrtc-direct-body
#<<GRPC_RUNTIME_EOF
//! WebRTC-Direct (libp2p-style) client->server connections for
//! generated clients and servers: no ICE, no SDP exchange. The
//! listener is identified by the certhash in its multiaddr
//! (`/ip4/.../udp/.../webrtc-direct/certhash/f...`); dialers pin
//! the listener certificate to that hash. `direct_client_turn`
//! is the symmetric-NAT path: the whole DTLS handshake rides a
//! TURN allocation. See `dc_webrtc::direct`.

use crate::status::Status;
use crate::transport::DcTransport;
use crate::webrtc_transport::WebRtcDc;
pub use dc_webrtc::dcep::ChannelParams;
pub use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::endpoint::DcEndpoint;
use dc_webrtc::x509::Certificate;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

pub use dc_webrtc::direct::{
    certhash_of_cert, direct_multiaddr, parse_certhash, parse_direct_multiaddr, DirectListener,
};
pub use dc_webrtc::dcep::Reliability;
pub use dc_webrtc::turn::TurnServerConfig;

fn bad(e: std::io::Error) -> Status {
    Status::unavailable(format!("webrtc-direct: {e}"))
}

/// Bind a WebRTC-Direct listener. Its `multiaddr()` (address +
/// certhash) is everything a dialer needs.
pub fn direct_listener(addr: SocketAddr) -> Result<DirectListener, Status> {
    DirectListener::bind(addr, Certificate::generate_self_signed("grpc-dc")).map_err(bad)
}

/// Accept one direct connection and its "grpc" channel; serve
/// it with `Server::serve(transport, services)`.
pub async fn accept_direct_transport(
    listener: Arc<DirectListener>,
) -> Result<Arc<dyn DcTransport>, Status> {
    let endpoint = Arc::new(
        tokio::task::spawn_blocking(move || listener.accept())
            .await
            .map_err(|e| Status::internal(format!("webrtc-direct join: {e}")))?
            .map_err(bad)?,
    );
    let ep = endpoint.clone();
    let channel = tokio::task::spawn_blocking(move || loop {
        match ep.recv_event_timeout(Duration::from_secs(30)) {
            Some(EndpointEvent::ChannelOpened { channel }) => break Ok(channel),
            Some(_) => continue,
            None => break Err(Status::unavailable("webrtc-direct: no channel")),
        }
    })
    .await
    .map_err(|e| Status::internal(format!("webrtc-direct join: {e}")))??;
    Ok(Arc::new(WebRtcDc::new(endpoint, channel)))
}

/// Dial a direct listener by multiaddr and open the "grpc"
/// channel; build a generated `Channel` on the returned
/// transport.
pub async fn direct_client(multiaddr: &str) -> Result<Arc<dyn DcTransport>, Status> {
    let ma = multiaddr.to_string();
    let endpoint = tokio::task::spawn_blocking(move || {
        dc_webrtc::direct::direct_dial_multiaddr(&ma, Certificate::generate_self_signed("grpc-dc"))
    })
    .await
    .map_err(|e| Status::internal(format!("webrtc-direct join: {e}")))?
    .map_err(bad)?;
    open_grpc_channel(Arc::new(endpoint)).await
}

/// Dial a direct listener by multiaddr and return the raw
/// endpoint (no channel opened yet). Use this to open extra
/// application channels next to the "grpc" one -- including
/// lossy or unordered ones, via `DcEndpoint::open_channel` with
/// `ChannelParams { ordered: false,
/// reliability: Reliability::MaxRetransmits(n)` or
/// `MaxLifetimeMs(ms), .. }`. The "grpc" channel itself must
/// stay reliable and ordered: grpc-dc framing assumes in-order
/// reliable delivery, so keep `direct_client`'s defaults for
/// gRPC traffic and use lossy channels only for application
/// data that tolerates drops and reordering.
pub async fn direct_client_endpoint(multiaddr: &str) -> Result<Arc<DcEndpoint>, Status> {
    let ma = multiaddr.to_string();
    let endpoint = tokio::task::spawn_blocking(move || {
        dc_webrtc::direct::direct_dial_multiaddr(&ma, Certificate::generate_self_signed("grpc-dc"))
    })
    .await
    .map_err(|e| Status::internal(format!("webrtc-direct join: {e}")))?
    .map_err(bad)?;
    Ok(Arc::new(endpoint))
}

/// Accept one direct connection and return the raw endpoint
/// (its "grpc" channel not yet consumed). Incoming application
/// channels -- including lossy/unordered ones opened by the
/// dialer -- surface as `EndpointEvent::ChannelOpened` on this
/// endpoint; see `direct_client_endpoint` for the reliability
/// contract.
pub async fn accept_direct_endpoint(
    listener: Arc<DirectListener>,
) -> Result<Arc<DcEndpoint>, Status> {
    let endpoint = tokio::task::spawn_blocking(move || listener.accept())
        .await
        .map_err(|e| Status::internal(format!("webrtc-direct join: {e}")))?
        .map_err(bad)?;
    Ok(Arc::new(endpoint))
}

/// Dial a direct listener by multiaddr through a TURN
/// allocation (browser/symmetric-NAT shape, native form): the
/// dialer only ever talks to its TURN server.
pub async fn direct_client_turn(
    multiaddr: &str,
    turn: &TurnServerConfig,
) -> Result<Arc<dyn DcTransport>, Status> {
    let ma = multiaddr.to_string();
    let turn = turn.clone();
    let endpoint = tokio::task::spawn_blocking(move || {
        dc_webrtc::direct::direct_dial_turn_multiaddr(
            &ma,
            Certificate::generate_self_signed("grpc-dc"),
            &turn,
        )
    })
    .await
    .map_err(|e| Status::internal(format!("webrtc-direct join: {e}")))?
    .map_err(bad)?;
    open_grpc_channel(Arc::new(endpoint)).await
}

async fn open_grpc_channel(endpoint: Arc<DcEndpoint>) -> Result<Arc<dyn DcTransport>, Status> {
    let channel = endpoint
        .open_channel(ChannelParams { label: "grpc".into(), ..Default::default() })
        .map_err(bad)?;
    Ok(Arc::new(WebRtcDc::new(endpoint, channel)))
}
GRPC_RUNTIME_EOF
)

(define rust-dispatch-arms
  '((HEADERS    . "self.on_headers(frame).await")
    (DATA       . "self.deliver(frame.stream_id, StreamEvent::Data(frame.payload))")
    (HALF-CLOSE . "self.deliver(frame.stream_id, StreamEvent::HalfClose)")
    (TRAILERS   . "{ if let Ok(status) = frame.parse_status() { self.deliver(frame.stream_id, StreamEvent::Trailers(status)); } }")
    (RST        . "{ let status = frame.parse_status().unwrap_or_else(|_| Status::cancelled(\"stream reset\")); self.deliver(frame.stream_id, StreamEvent::Rst(status)); self.streams.lock().unwrap().remove(&frame.stream_id); }")))

(define (emit-rust-dispatch)
  (string-append
   "match frame.frame_type {\n"
   (apply string-append
          (for/list ([e (in-list frame-table)])
            (define arm (assoc (first e) rust-dispatch-arms))
            (unless arm (error 'runtime-rust "no Rust dispatch arm for ~a" (first e)))
            (format "            frame_type::~a => ~a,\n"
                    (string-replace (symbol->string (first e)) "-" "_") (cdr arm))))
   "            _ => {} // unknown frame type: ignore for forward compatibility\n        }"))

(define rust-dynamic-body
#<<GRPC_RUNTIME_EOF
//! Dynamic, descriptor-driven client and server.
//!
//! Parses a FileDescriptorSet (as produced by
//! `protoc --descriptor_set_out`) at runtime and builds clients and
//! servers whose messages are generic field maps — no generated stubs
//! required. This is the runtime-generation counterpart of the
//! protoc-plugin surfaces: schemas arrive as data (descriptor.proto),
//! not as code.
//!
//! Generic values by field type: varint family -> I64/U64/Bool,
//! string -> Str, bytes/message -> Bytes / Msg(GenericMessage),
//! fixed/float -> U64/I64 / F32/F64. Repeated fields are value lists
//! in field-number order.

use crate::channel::Channel;
use crate::server::{
    CallCtx, MethodDef, MethodKind, ResponseSink, ResponseStream, ServerCall, ServiceDef,
};
use crate::status::Status;
use bytes::Bytes;
use futures_util::StreamExt;
use std::collections::{BTreeMap, HashMap};
use std::pin::Pin;
use std::sync::Arc;

// FieldDescriptorProto.Type values (descriptor.proto).
pub const TYPE_DOUBLE: i32 = 1;
pub const TYPE_FLOAT: i32 = 2;
pub const TYPE_INT64: i32 = 3;
pub const TYPE_UINT64: i32 = 4;
pub const TYPE_INT32: i32 = 5;
pub const TYPE_FIXED64: i32 = 6;
pub const TYPE_FIXED32: i32 = 7;
pub const TYPE_BOOL: i32 = 8;
pub const TYPE_STRING: i32 = 9;
pub const TYPE_GROUP: i32 = 10;
pub const TYPE_MESSAGE: i32 = 11;
pub const TYPE_BYTES: i32 = 12;
pub const TYPE_UINT32: i32 = 13;
pub const TYPE_ENUM: i32 = 14;
pub const TYPE_SFIXED32: i32 = 15;
pub const TYPE_SFIXED64: i32 = 16;
pub const TYPE_SINT32: i32 = 17;
pub const TYPE_SINT64: i32 = 18;

const LABEL_REPEATED: i32 = 3;

#[derive(Clone, Debug)]
pub struct FieldModel {
    pub number: u32,
    pub name: String,
    pub ty: i32,
    pub repeated: bool,
    /// For TYPE_MESSAGE, e.g. ".echo.EchoRequest".
    pub type_name: String,
}

#[derive(Clone, Debug)]
pub struct MessageModel {
    pub full_name: String,
    pub fields: BTreeMap<u32, FieldModel>,
    pub by_name: HashMap<String, u32>,
}

impl MessageModel {
    pub fn field(&self, number: u32) -> Option<&FieldModel> {
        self.fields.get(&number)
    }
    pub fn field_by_name(&self, name: &str) -> Option<&FieldModel> {
        self.by_name.get(name).and_then(|n| self.fields.get(n))
    }
}

#[derive(Clone, Debug)]
pub struct MethodModel {
    pub name: String,
    pub path: String,
    pub kind: MethodKind,
    pub input: Arc<MessageModel>,
    pub output: Arc<MessageModel>,
}

#[derive(Clone, Debug)]
pub struct ServiceModel {
    pub full_name: String,
    pub methods: HashMap<String, Arc<MethodModel>>,
}

/// Parsed descriptor set: messages and services by full name.
/// Message keys carry the leading dot (".echo.EchoRequest"), matching
/// FieldDescriptorProto.type_name; service keys do not ("echo.Echo").
#[derive(Clone, Debug, Default)]
pub struct FileModel {
    pub messages: HashMap<String, Arc<MessageModel>>,
    pub services: HashMap<String, Arc<ServiceModel>>,
}

impl FileModel {
    pub fn message(&self, full_name: &str) -> Result<Arc<MessageModel>, Status> {
        self.messages
            .get(full_name)
            .cloned()
            .ok_or_else(|| Status::invalid_argument(format!("unknown message {full_name}")))
    }
    pub fn service(&self, full_name: &str) -> Result<Arc<ServiceModel>, Status> {
        self.services
            .get(full_name)
            .cloned()
            .ok_or_else(|| Status::invalid_argument(format!("unknown service {full_name}")))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum GenericValue {
    I64(i64),
    U64(u64),
    Bool(bool),
    Str(String),
    Bytes(Vec<u8>),
    Msg(Box<GenericMessage>),
    F32(f32),
    F64(f64),
}

impl From<&str> for GenericValue {
    fn from(v: &str) -> Self {
        GenericValue::Str(v.to_string())
    }
}
impl From<String> for GenericValue {
    fn from(v: String) -> Self {
        GenericValue::Str(v)
    }
}
impl From<i64> for GenericValue {
    fn from(v: i64) -> Self {
        GenericValue::I64(v)
    }
}
impl From<i32> for GenericValue {
    fn from(v: i32) -> Self {
        GenericValue::I64(v as i64)
    }
}
impl From<u64> for GenericValue {
    fn from(v: u64) -> Self {
        GenericValue::U64(v)
    }
}
impl From<u32> for GenericValue {
    fn from(v: u32) -> Self {
        GenericValue::U64(v as u64)
    }
}
impl From<bool> for GenericValue {
    fn from(v: bool) -> Self {
        GenericValue::Bool(v)
    }
}
impl From<Vec<u8>> for GenericValue {
    fn from(v: Vec<u8>) -> Self {
        GenericValue::Bytes(v)
    }
}
impl From<f32> for GenericValue {
    fn from(v: f32) -> Self {
        GenericValue::F32(v)
    }
}
impl From<f64> for GenericValue {
    fn from(v: f64) -> Self {
        GenericValue::F64(v)
    }
}
impl From<GenericMessage> for GenericValue {
    fn from(v: GenericMessage) -> Self {
        GenericValue::Msg(Box::new(v))
    }
}

/// A message as field number -> list of values (descriptor order).
///
/// Fields not in the model are retained as raw encoded chunks in
/// `unknown` (protobuf unknown-field retention): a decode -> encode
/// round trip re-emits them after the known fields, so intermediate
/// hops do not strip newer fields.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GenericMessage {
    pub values: BTreeMap<u32, Vec<GenericValue>>,
    pub unknown: Vec<Vec<u8>>,
}

impl GenericMessage {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&mut self, number: u32, value: impl Into<GenericValue>) -> &mut Self {
        self.values.insert(number, vec![value.into()]);
        self
    }

    pub fn add(&mut self, number: u32, value: impl Into<GenericValue>) -> &mut Self {
        self.values.entry(number).or_default().push(value.into());
        self
    }

    pub fn get(&self, number: u32) -> Option<&GenericValue> {
        self.values.get(&number).and_then(|v| v.first())
    }

    pub fn get_all(&self, number: u32) -> &[GenericValue] {
        self.values.get(&number).map(|v| v.as_slice()).unwrap_or(&[])
    }

    pub fn get_string(&self, number: u32) -> String {
        match self.get(number) {
            Some(GenericValue::Str(s)) => s.clone(),
            _ => String::new(),
        }
    }

    pub fn get_i64(&self, number: u32) -> i64 {
        match self.get(number) {
            Some(GenericValue::I64(v)) => *v,
            Some(GenericValue::U64(v)) => *v as i64,
            Some(GenericValue::Bool(v)) => *v as i64,
            _ => 0,
        }
    }
}

// ---------------------------------------------------------------------------
// Generic protobuf codec
// ---------------------------------------------------------------------------

struct PbReader<'a> {
    buf: &'a [u8],
    pos: usize,
}

enum PbValue<'a> {
    Varint(u64),
    Len(&'a [u8]),
    Fixed64([u8; 8]),
    Fixed32([u8; 4]),
}

impl<'a> PbReader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn varint(&mut self) -> Result<u64, Status> {
        let mut result: u64 = 0;
        let mut shift = 0;
        loop {
            if self.pos >= self.buf.len() {
                return Err(Status::invalid_argument("truncated varint"));
            }
            let b = self.buf[self.pos];
            self.pos += 1;
            result |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return Ok(result);
            }
            shift += 7;
            if shift >= 70 {
                return Err(Status::invalid_argument("varint too long"));
            }
        }
    }

    fn len_bytes(&mut self) -> Result<&'a [u8], Status> {
        let n = self.varint()? as usize;
        if self.pos + n > self.buf.len() {
            return Err(Status::invalid_argument("truncated bytes field"));
        }
        let out = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(out)
    }

    /// Next (number, wire_type, value, raw_chunk); None at end.
    fn next_field(&mut self) -> Option<Result<(u32, u32, PbValue<'a>, Vec<u8>), Status>> {
        if self.pos >= self.buf.len() {
            return None;
        }
        let start = self.pos;
        let tag = match self.varint() {
            Ok(v) => v,
            Err(e) => return Some(Err(e)),
        };
        let (number, wire) = ((tag >> 3) as u32, (tag & 7) as u32);
        let value = match wire {
            0 => match self.varint() {
                Ok(v) => PbValue::Varint(v),
                Err(e) => return Some(Err(e)),
            },
            2 => match self.len_bytes() {
                Ok(b) => PbValue::Len(b),
                Err(e) => return Some(Err(e)),
            },
            1 => {
                if self.pos + 8 > self.buf.len() {
                    return Some(Err(Status::invalid_argument("truncated fixed64")));
                }
                let mut b = [0u8; 8];
                b.copy_from_slice(&self.buf[self.pos..self.pos + 8]);
                self.pos += 8;
                PbValue::Fixed64(b)
            }
            5 => {
                if self.pos + 4 > self.buf.len() {
                    return Some(Err(Status::invalid_argument("truncated fixed32")));
                }
                let mut b = [0u8; 4];
                b.copy_from_slice(&self.buf[self.pos..self.pos + 4]);
                self.pos += 4;
                PbValue::Fixed32(b)
            }
            _ => return Some(Err(Status::invalid_argument(format!("unsupported wire type {wire}")))),
        };
        Some(Ok((number, wire, value, self.buf[start..self.pos].to_vec())))
    }
}

fn as_str<'a>(value: &PbValue<'a>) -> Result<&'a str, Status> {
    match value {
        PbValue::Len(b) => std::str::from_utf8(b)
            .map_err(|e| Status::invalid_argument(format!("invalid utf-8 in descriptor: {e}"))),
        _ => Err(Status::invalid_argument("expected length-delimited field")),
    }
}

fn as_varint(value: &PbValue) -> Result<u64, Status> {
    match value {
        PbValue::Varint(v) => Ok(*v),
        _ => Err(Status::invalid_argument("expected varint field")),
    }
}

fn wire_type(ty: i32) -> Option<u32> {
    match ty {
        TYPE_INT64 | TYPE_UINT64 | TYPE_INT32 | TYPE_BOOL | TYPE_UINT32 | TYPE_ENUM | TYPE_SINT32
        | TYPE_SINT64 => Some(0),
        TYPE_FIXED64 | TYPE_SFIXED64 | TYPE_DOUBLE => Some(1),
        TYPE_STRING | TYPE_BYTES | TYPE_MESSAGE | TYPE_GROUP => Some(2),
        TYPE_FIXED32 | TYPE_SFIXED32 | TYPE_FLOAT => Some(5),
        _ => None,
    }
}

fn encode_varint(out: &mut Vec<u8>, mut v: u64) {
    while v > 0x7f {
        out.push(((v & 0x7f) as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn zigzag_encode(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

fn zigzag_decode(v: u64) -> i64 {
    ((v >> 1) as i64) ^ -((v & 1) as i64)
}

fn value_as_i64(value: &GenericValue) -> i64 {
    match value {
        GenericValue::I64(v) => *v,
        GenericValue::U64(v) => *v as i64,
        GenericValue::Bool(v) => *v as i64,
        _ => 0,
    }
}

fn value_as_u64(value: &GenericValue) -> u64 {
    match value {
        GenericValue::U64(v) => *v,
        GenericValue::I64(v) => *v as u64,
        GenericValue::Bool(v) => *v as u64,
        _ => 0,
    }
}

pub fn encode_generic(
    model: &MessageModel,
    message: &GenericMessage,
    file: &FileModel,
) -> Result<Vec<u8>, Status> {
    let mut out = Vec::new();
    for (number, values) in &message.values {
        let field = model
            .field(*number)
            .ok_or_else(|| {
                Status::invalid_argument(format!("unknown field {number} for {}", model.full_name))
            })?;
        if field.repeated {
            for value in values {
                encode_value(&mut out, field, value, file)?;
            }
        } else if let Some(value) = values.first() {
            encode_value(&mut out, field, value, file)?;
        }
    }
    for chunk in &message.unknown {
        out.extend_from_slice(chunk);
    }
    Ok(out)
}

fn encode_value(
    out: &mut Vec<u8>,
    field: &FieldModel,
    value: &GenericValue,
    file: &FileModel,
) -> Result<(), Status> {
    let wire = wire_type(field.ty)
        .ok_or_else(|| Status::invalid_argument(format!("unsupported field type {}", field.ty)))?;
    encode_varint(out, ((field.number as u64) << 3) | wire as u64);
    match wire {
        0 => {
            let v = match field.ty {
                TYPE_SINT32 | TYPE_SINT64 => {
                    let v = value_as_i64(value);
                    if field.ty == TYPE_SINT32 {
                        zigzag_encode(v as i32 as i64) as u32 as u64
                    } else {
                        zigzag_encode(v)
                    }
                }
                TYPE_BOOL => {
                    if matches!(value, GenericValue::Bool(true)) || value_as_i64(value) != 0 {
                        1
                    } else {
                        0
                    }
                }
                _ => value_as_u64(value),
            };
            encode_varint(out, v);
        }
        1 => {
            if field.ty == TYPE_DOUBLE {
                let v = match value {
                    GenericValue::F64(v) => *v,
                    _ => value_as_i64(value) as f64,
                };
                out.extend_from_slice(&v.to_le_bytes());
            } else {
                out.extend_from_slice(&value_as_u64(value).to_le_bytes());
            }
        }
        5 => {
            if field.ty == TYPE_FLOAT {
                let v = match value {
                    GenericValue::F32(v) => *v,
                    GenericValue::F64(v) => *v as f32,
                    _ => value_as_i64(value) as f32,
                };
                out.extend_from_slice(&v.to_le_bytes());
            } else {
                out.extend_from_slice(&(value_as_u64(value) as u32).to_le_bytes());
            }
        }
        _ => {
            let data: Vec<u8> = match (field.ty, value) {
                (TYPE_STRING, GenericValue::Str(s)) => s.as_bytes().to_vec(),
                (TYPE_MESSAGE, GenericValue::Msg(m)) => {
                    let nested = file.message(&field.type_name)?;
                    encode_generic(&nested, m, file)?
                }
                (_, GenericValue::Bytes(b)) => b.clone(),
                (_, GenericValue::Str(s)) => s.as_bytes().to_vec(),
                _ => {
                    return Err(Status::invalid_argument(format!(
                        "value does not match field {} type {}",
                        field.name, field.ty
                    )))
                }
            };
            encode_varint(out, data.len() as u64);
            out.extend_from_slice(&data);
        }
    }
    Ok(())
}

pub fn decode_generic(
    model: &MessageModel,
    data: &[u8],
    file: &FileModel,
) -> Result<GenericMessage, Status> {
    let mut message = GenericMessage::new();
    let mut reader = PbReader::new(data);
    while let Some(field_result) = reader.next_field() {
        let (number, wire, raw, chunk) = field_result?;
        let Some(field) = model.field(number) else {
            // Unknown field: retain the raw encoded chunk verbatim.
            message.unknown.push(chunk);
            continue;
        };
        let value = decode_value(field, wire, &raw, file)?;
        message.values.entry(number).or_default().push(value);
    }
    Ok(message)
}

fn decode_value(
    field: &FieldModel,
    _wire: u32,
    raw: &PbValue,
    file: &FileModel,
) -> Result<GenericValue, Status> {
    match raw {
        PbValue::Varint(v) => Ok(match field.ty {
            TYPE_BOOL => GenericValue::Bool(*v != 0),
            TYPE_SINT32 | TYPE_SINT64 => GenericValue::I64(zigzag_decode(*v)),
            TYPE_INT32 | TYPE_ENUM => GenericValue::I64((*v as u32 as i32) as i64),
            TYPE_INT64 => GenericValue::I64(*v as i64),
            _ => GenericValue::U64(*v),
        }),
        PbValue::Fixed64(b) => Ok(match field.ty {
            TYPE_DOUBLE => GenericValue::F64(f64::from_le_bytes(*b)),
            TYPE_SFIXED64 => GenericValue::I64(i64::from_le_bytes(*b)),
            _ => GenericValue::U64(u64::from_le_bytes(*b)),
        }),
        PbValue::Fixed32(b) => Ok(match field.ty {
            TYPE_FLOAT => GenericValue::F32(f32::from_le_bytes(*b)),
            TYPE_SFIXED32 => GenericValue::I64((i32::from_le_bytes(*b)) as i64),
            _ => GenericValue::U64((u32::from_le_bytes(*b)) as u64),
        }),
        PbValue::Len(b) => Ok(match field.ty {
            TYPE_STRING => GenericValue::Str(
                String::from_utf8(b.to_vec())
                    .map_err(|e| Status::invalid_argument(format!("invalid utf-8: {e}")))?,
            ),
            TYPE_MESSAGE => {
                let nested = file.message(&field.type_name)?;
                GenericValue::Msg(Box::new(decode_generic(&nested, b, file)?))
            }
            _ => GenericValue::Bytes(b.to_vec()),
        }),
    }
}

// ---------------------------------------------------------------------------
// Descriptor set parsing
// ---------------------------------------------------------------------------

/// Parse FileDescriptorSet bytes into a FileModel.
pub fn parse_descriptor_set(data: &[u8]) -> Result<FileModel, Status> {
    let mut file = FileModel::default();
    let mut pending_services: Vec<(String, Vec<u8>)> = Vec::new();
    let mut reader = PbReader::new(data);
    while let Some(field_result) = reader.next_field() {
        let (number, _wire, value, _chunk) = field_result?;
        if number != 1 {
            continue;
        }
        let PbValue::Len(file_bytes) = value else {
            return Err(Status::invalid_argument("FileDescriptorSet.file must be a message"));
        };
        let mut package = String::new();
        let mut message_types: Vec<Vec<u8>> = Vec::new();
        let mut service_types: Vec<Vec<u8>> = Vec::new();
        let mut file_reader = PbReader::new(file_bytes);
        while let Some(file_field) = file_reader.next_field() {
            let (fnum, _w, fval, _c) = file_field?;
            match (fnum, &fval) {
                (2, _) => package = as_str(&fval)?.to_string(),
                (4, PbValue::Len(b)) => message_types.push(b.to_vec()),
                (6, PbValue::Len(b)) => service_types.push(b.to_vec()),
                _ => {}
            }
        }
        for message_bytes in &message_types {
            parse_message(&package, message_bytes, &mut file)?;
        }
        for service_bytes in service_types {
            pending_services.push((package.clone(), service_bytes));
        }
    }
    for (package, service_bytes) in &pending_services {
        parse_service(package, service_bytes, &mut file)?;
    }
    Ok(file)
}

fn parse_message(prefix: &str, data: &[u8], file: &mut FileModel) -> Result<(), Status> {
    let mut name = String::new();
    let mut raw_fields: Vec<Vec<u8>> = Vec::new();
    let mut nested: Vec<Vec<u8>> = Vec::new();
    let mut reader = PbReader::new(data);
    while let Some(field_result) = reader.next_field() {
        let (fnum, _w, fval, _c) = field_result?;
        match (fnum, &fval) {
            (1, _) => name = as_str(&fval)?.to_string(),
            (2, PbValue::Len(b)) => raw_fields.push(b.to_vec()),
            (3, PbValue::Len(b)) => nested.push(b.to_vec()),
            _ => {}
        }
    }
    let full_name = if prefix.is_empty() {
        name.clone()
    } else {
        format!("{prefix}.{name}")
    };
    let mut fields = BTreeMap::new();
    let mut by_name = HashMap::new();
    for field_bytes in &raw_fields {
        let field = parse_field(field_bytes)?;
        by_name.insert(field.name.clone(), field.number);
        fields.insert(field.number, field);
    }
    file.messages.insert(
        format!(".{full_name}"),
        Arc::new(MessageModel { full_name: full_name.clone(), fields, by_name }),
    );
    for nested_bytes in &nested {
        parse_message(&full_name, nested_bytes, file)?;
    }
    Ok(())
}

fn parse_field(data: &[u8]) -> Result<FieldModel, Status> {
    let mut field = FieldModel {
        number: 0,
        name: String::new(),
        ty: 0,
        repeated: false,
        type_name: String::new(),
    };
    let mut reader = PbReader::new(data);
    while let Some(field_result) = reader.next_field() {
        let (fnum, _w, fval, _c) = field_result?;
        match fnum {
            1 => field.name = as_str(&fval)?.to_string(),
            3 => field.number = as_varint(&fval)? as u32,
            4 => field.repeated = as_varint(&fval)? as i32 == LABEL_REPEATED,
            5 => field.ty = as_varint(&fval)? as i32,
            6 => field.type_name = as_str(&fval)?.to_string(),
            _ => {}
        }
    }
    Ok(field)
}

fn kind_of(client_streaming: bool, server_streaming: bool) -> MethodKind {
    match (client_streaming, server_streaming) {
        (true, true) => MethodKind::BidiStreaming,
        (true, false) => MethodKind::ClientStreaming,
        (false, true) => MethodKind::ServerStreaming,
        (false, false) => MethodKind::Unary,
    }
}

fn parse_service(package: &str, data: &[u8], file: &mut FileModel) -> Result<(), Status> {
    let mut name = String::new();
    let mut raw_methods: Vec<Vec<u8>> = Vec::new();
    let mut reader = PbReader::new(data);
    while let Some(field_result) = reader.next_field() {
        let (fnum, _w, fval, _c) = field_result?;
        match (fnum, &fval) {
            (1, _) => name = as_str(&fval)?.to_string(),
            (2, PbValue::Len(b)) => raw_methods.push(b.to_vec()),
            _ => {}
        }
    }
    let full_name = if package.is_empty() {
        name.clone()
    } else {
        format!("{package}.{name}")
    };
    let mut methods = HashMap::new();
    for method_bytes in &raw_methods {
        let mut mname = String::new();
        let mut input_type = String::new();
        let mut output_type = String::new();
        let mut client_streaming = false;
        let mut server_streaming = false;
        let mut method_reader = PbReader::new(method_bytes);
        while let Some(method_field) = method_reader.next_field() {
            let (fnum, _w, fval, _c) = method_field?;
            match fnum {
                1 => mname = as_str(&fval)?.to_string(),
                2 => input_type = as_str(&fval)?.to_string(),
                3 => output_type = as_str(&fval)?.to_string(),
                5 => client_streaming = as_varint(&fval)? != 0,
                6 => server_streaming = as_varint(&fval)? != 0,
                _ => {}
            }
        }
        let method = MethodModel {
            path: format!("/{full_name}/{mname}"),
            name: mname.clone(),
            kind: kind_of(client_streaming, server_streaming),
            input: file.message(&input_type)?,
            output: file.message(&output_type)?,
        };
        methods.insert(mname, Arc::new(method));
    }
    file.services.insert(
        full_name.clone(),
        Arc::new(ServiceModel { full_name, methods }),
    );
    Ok(())
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Runtime-built client: methods resolve from the FileModel.
#[derive(Clone)]
pub struct DynamicClient {
    channel: Channel,
    model: Arc<FileModel>,
}

impl DynamicClient {
    pub fn new(channel: Channel, model: Arc<FileModel>) -> Self {
        Self { channel, model }
    }

    fn method(&self, service_name: &str, method_name: &str) -> Result<Arc<MethodModel>, Status> {
        let service = self.model.service(service_name)?;
        service
            .methods
            .get(method_name)
            .cloned()
            .ok_or_else(|| {
                Status::invalid_argument(format!("unknown method {service_name}/{method_name}"))
            })
    }

    pub async fn unary(
        &self,
        service_name: &str,
        method_name: &str,
        request: GenericMessage,
    ) -> Result<GenericMessage, Status> {
        let method = self.method(service_name, method_name)?;
        let bytes = encode_generic(&method.input, &request, &self.model)?;
        let resp: Vec<u8> = self.channel.unary(&method.path, bytes).await?;
        decode_generic(&method.output, &resp, &self.model)
    }

    pub async fn server_stream(
        &self,
        service_name: &str,
        method_name: &str,
        request: GenericMessage,
    ) -> Result<ResponseStream<GenericMessage>, Status> {
        let method = self.method(service_name, method_name)?;
        let bytes = encode_generic(&method.input, &request, &self.model)?;
        let raw: ResponseStream<Vec<u8>> =
            self.channel.server_stream(&method.path, bytes).await?;
        Ok(decode_stream(raw, method.output.clone(), self.model.clone()))
    }

    pub async fn client_stream(
        &self,
        service_name: &str,
        method_name: &str,
        requests: Vec<GenericMessage>,
    ) -> Result<GenericMessage, Status> {
        let method = self.method(service_name, method_name)?;
        let mut encoded = Vec::with_capacity(requests.len());
        for request in &requests {
            encoded.push(encode_generic(&method.input, request, &self.model)?);
        }
        let resp: Vec<u8> = self
            .channel
            .client_stream(&method.path, futures_util::stream::iter(encoded))
            .await?;
        decode_generic(&method.output, &resp, &self.model)
    }

    pub async fn bidi(
        &self,
        service_name: &str,
        method_name: &str,
        requests: Vec<GenericMessage>,
    ) -> Result<ResponseStream<GenericMessage>, Status> {
        let method = self.method(service_name, method_name)?;
        let mut encoded = Vec::with_capacity(requests.len());
        for request in &requests {
            encoded.push(encode_generic(&method.input, request, &self.model)?);
        }
        let raw: ResponseStream<Vec<u8>> = self
            .channel
            .bidi(&method.path, futures_util::stream::iter(encoded))
            .await?;
        Ok(decode_stream(raw, method.output.clone(), self.model.clone()))
    }
}

fn decode_stream(
    raw: ResponseStream<Vec<u8>>,
    model: Arc<MessageModel>,
    file: Arc<FileModel>,
) -> ResponseStream<GenericMessage> {
    Box::pin(raw.map(move |item| {
        item.and_then(|bytes| decode_generic(&model, &bytes, &file))
    }))
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/// Sends GenericMessage responses for one dynamic server stream.
#[derive(Clone)]
pub struct DynamicSink {
    sink: ResponseSink,
    model: Arc<MessageModel>,
    file: Arc<FileModel>,
}

impl DynamicSink {
    pub async fn send(&self, message: &GenericMessage) -> Result<(), Status> {
        self.sink
            .send(encode_generic(&self.model, message, &self.file)?)
            .await
    }
}

pub type DynamicRequestStream =
    Pin<Box<dyn futures_core::Stream<Item = Result<GenericMessage, Status>> + Send>>;

/// Handler protocol for dynamic_service. Implement the shapes your
/// service uses; the defaults return UNIMPLEMENTED.
#[async_trait::async_trait]
pub trait DynamicHandler: Send + Sync {
    async fn unary(
        &self,
        _ctx: CallCtx,
        _method: &MethodModel,
        _request: GenericMessage,
    ) -> Result<GenericMessage, Status> {
        Err(Status::unimplemented("unary not implemented"))
    }

    async fn server_stream(
        &self,
        _ctx: CallCtx,
        _method: &MethodModel,
        _request: GenericMessage,
        _sink: DynamicSink,
    ) -> Result<(), Status> {
        Err(Status::unimplemented("server_stream not implemented"))
    }

    async fn client_stream(
        &self,
        _ctx: CallCtx,
        _method: &MethodModel,
        _requests: DynamicRequestStream,
    ) -> Result<GenericMessage, Status> {
        Err(Status::unimplemented("client_stream not implemented"))
    }

    async fn bidi(
        &self,
        _ctx: CallCtx,
        _method: &MethodModel,
        _requests: DynamicRequestStream,
        _sink: DynamicSink,
    ) -> Result<(), Status> {
        Err(Status::unimplemented("bidi not implemented"))
    }
}

/// Build a ServiceDef for a descriptor-named service, dispatching to
/// `handler`. Register it with Server::add_service /
/// Server::serve like a generated service.
pub fn dynamic_service(
    file: &Arc<FileModel>,
    service_name: &str,
    handler: Arc<dyn DynamicHandler>,
) -> Result<ServiceDef, Status> {
    let service = file.service(service_name)?;
    let mut methods = Vec::with_capacity(service.methods.len());
    for method in service.methods.values() {
        let handler = handler.clone();
        let method_for_call = method.clone();
        let file_for_call = file.clone();
        // MethodDef.name is &'static str (generated stubs use string
        // literals); a runtime-built name is leaked once per method —
        // registration is once-per-process and bounded by schema size.
        let leaked_name: &'static str = Box::leak(method.name.clone().into_boxed_str());
        methods.push(MethodDef {
            name: leaked_name,
            kind: method.kind,
            handler: Arc::new(move |call| {
                let handler = handler.clone();
                let method = method_for_call.clone();
                let file = file_for_call.clone();
                Box::pin(async move {
                    let ServerCall { ctx, requests, sink } = call;
                    let mut decoded = decode_requests(requests, method.input.clone(), file.clone());
                    let out_sink = DynamicSink {
                        sink: sink.clone(),
                        model: method.output.clone(),
                        file: file.clone(),
                    };
                    match method.kind {
                        MethodKind::Unary => {
                            let request = next_request(&mut decoded).await?;
                            let resp = handler.unary(ctx, &method, request).await?;
                            out_sink.send(&resp).await
                        }
                        MethodKind::ServerStreaming => {
                            let request = next_request(&mut decoded).await?;
                            handler.server_stream(ctx, &method, request, out_sink).await
                        }
                        MethodKind::ClientStreaming => {
                            let resp = handler.client_stream(ctx, &method, decoded).await?;
                            out_sink.send(&resp).await
                        }
                        MethodKind::BidiStreaming => {
                            handler.bidi(ctx, &method, decoded, out_sink).await
                        }
                    }
                })
            }),
        });
    }
    Ok(ServiceDef::new(service.full_name.clone(), methods))
}

async fn next_request(
    requests: &mut DynamicRequestStream,
) -> Result<GenericMessage, Status> {
    match requests.next().await {
        Some(Ok(req)) => Ok(req),
        Some(Err(e)) => Err(e),
        None => Err(Status::invalid_argument("missing request message")),
    }
}

fn decode_requests(
    requests: crate::server::RequestStream<Bytes>,
    model: Arc<MessageModel>,
    file: Arc<FileModel>,
) -> DynamicRequestStream {
    Box::pin(requests.map(move |item| {
        item.and_then(|bytes| decode_generic(&model, &bytes, &file))
    }))
}
GRPC_RUNTIME_EOF
)

(define (emit-rust-runtime-files)
  (list
   (cons "lib.rs" rust-lib-body)
   (cons "codec.rs" rust-codec-body)
   (cons "status.rs" rust-status-body)
   (cons "message.rs" rust-message-body)
   (cons "transport.rs" rust-transport-body)
   (cons "endpoint.rs"
         (string-replace rust-endpoint-body "@@FRAME_DISPATCH@@" (emit-rust-dispatch)))
   (cons "channel.rs" rust-channel-body)
   (cons "server.rs" rust-server-body)
   (cons "dynamic.rs" rust-dynamic-body)
   (cons "webrtc_transport.rs" rust-webrtc-transport-body)
   (cons "webrtc_direct.rs" rust-webrtc-direct-body)))
