#lang racket

;;; runtime-rust.rkt — the rust gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under the language tree are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)

(require "spec.rkt" "runtime-rust-http2.rkt")
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
#[cfg(not(target_arch = "wasm32"))]
pub mod http2;
pub mod link_stats;
pub mod server;
pub mod status;
pub mod transport;
#[cfg(feature = "webrtc")]
pub mod webrtc_direct;
#[cfg(all(feature = "webrtc", not(target_arch = "wasm32")))]
pub mod http_signaling;
#[cfg(all(feature = "webrtc", not(target_arch = "wasm32")))]
pub mod rendezvous;
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
    bidi_method, client_stream_method, decode_rendezvous_claims, encode_rendezvous_claims,
    issue_rendezvous_token, server_stream_method, unary_method, CallCtx, MethodDef, MethodKind,
    RendezvousAuth, RendezvousClaims, RequestStream, ResponseStream, Server, ServiceDef,
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
#[cfg(not(target_arch = "wasm32"))]
pub use transport::{stdio_dc, StreamDc};
#[cfg(all(unix, not(target_arch = "wasm32")))]
pub use transport::{uds_dc, uds_dc_accept};
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
// Homegrown tracing@@TRACING_BETA@@ (W3C traceparent propagation)
// ---------------------------------------------------------------------------
// Tracing support lives here so every module can reach it.
// Dormant until a tracer is registered; generated code stays
// dependency-free (sampling and export are the app's problem).

/// Span observer (kind is "client" or "server").
pub trait Tracer: Send + Sync {
    fn on_start(&self, kind: &str, method: &str, trace_id: &str, span_id: &str, parent_span_id: &str);
    fn on_end(&self, kind: &str, method: &str, trace_id: &str, span_id: &str, status: &str, duration_ms: f64);
}

/// One in-flight span's context.
#[derive(Clone, Debug)]
pub struct TraceContext {
    pub trace_id: String,
    pub span_id: String,
    pub parent_span_id: String,
    pub sampled: bool,
    pub start: crate::platform_time::Instant,
}

/// Parsed traceparent parent.
#[derive(Clone, Debug)]
pub struct TraceParent {
    pub trace_id: String,
    pub span_id: String,
    pub sampled: bool,
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
    // Seed from the wall clock where std has one; on
    // wasm32-unknown-unknown SystemTime::now() traps, so seed
    // from the platform_time monotonic clock there instead.
    #[cfg(not(target_arch = "wasm32"))]
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    #[cfg(target_arch = "wasm32")]
    let seed = crate::platform_time::Instant::now().0.to_bits();
    let mut state = seed ^ COUNTER.fetch_add(0x9e37_79b9_7f4a_7c15, Ordering::Relaxed);
    if state == 0 {
        state = 0x2545_f491_4f6c_dd1d;
    }
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

pub fn format_traceparent(trace_id: &str, span_id: &str, sampled: bool) -> String {
    format!("00-{trace_id}-{span_id}-{}", if sampled { "01" } else { "00" })
}

pub fn parse_traceparent(value: Option<&String>) -> Option<TraceParent> {
    let value = value?;
    let parts: Vec<&str> = value.split('-').collect();
    if parts.len() != 4 || parts[1].len() != 32 || parts[2].len() != 16 {
        return None;
    }
    if !parts[1].bytes().all(|b| b.is_ascii_hexdigit())
        || !parts[2].bytes().all(|b| b.is_ascii_hexdigit())
        || parts[3].len() != 2
        || !parts[3].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return None;
    }
    let flags = u8::from_str_radix(parts[3], 16).ok()?;
    Some(TraceParent {
        trace_id: parts[1].to_string(),
        span_id: parts[2].to_string(),
        sampled: flags & 1 == 1,
    })
}

/// Begin a span; returns None when tracing is dormant.
pub fn trace_start(kind: &str, method: &str, parent: Option<TraceParent>) -> Option<TraceContext> {
    if !trace_allowed(method) {
        return None;
    }
    let tracer = tracer_slot().read().unwrap().clone()?;
    let sampled = parent.as_ref().map(|p| p.sampled).unwrap_or(true);
    let ctx = TraceContext {
        trace_id: parent
            .as_ref()
            .map(|p| p.trace_id.clone())
            .unwrap_or_else(|| random_hex(16)),
        span_id: random_hex(8),
        parent_span_id: parent.map(|p| p.span_id).unwrap_or_default(),
        sampled,
        start: crate::platform_time::Instant::now(),
    };
    if !ctx.sampled {
        return Some(ctx);
    }
    tracer.on_start(kind, method, &ctx.trace_id, &ctx.span_id, &ctx.parent_span_id);
    Some(ctx)
}

/// End a span started with trace_start.
pub fn trace_end(kind: &str, method: &str, ctx: Option<&TraceContext>, status: &str) {
    let (Some(tracer), Some(ctx)) = (tracer_slot().read().unwrap().clone(), ctx) else {
        return;
    };
    if !ctx.sampled {
        return;
    }
    tracer.on_end(
        kind,
        method,
        &ctx.trace_id,
        &ctx.span_id,
        status,
        ctx.start.elapsed().as_secs_f64() * 1000.0,
    );
}

/// Start a root span context (e.g. for a client workflow grouping
/// several outbound calls under one trace). Pair with trace_end.
/// None when tracing is dormant.
pub fn new_trace_context(kind: &str, method: &str) -> Option<TraceContext> {
    trace_start(kind, method, None)
}

/// View a span context as a traceparent parent for an outbound call.
pub fn trace_parent_of(ctx: &TraceContext) -> TraceParent {
    TraceParent {
        trace_id: ctx.trace_id.clone(),
        span_id: ctx.span_id.clone(),
        sampled: ctx.sampled,
    }
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

/// IPC transport over a byte stream (stdio pipes or a Unix
/// domain socket): one message is a 4-byte big-endian length
/// prefix plus the frame bytes — the same framing the stdio
/// examples have always used, promoted into the runtime so a
/// plugin process in any language can speak grpc-dc to a host
/// without a WebRTC stack. `R`/`W` are the stream halves
/// (tokio stdin/stdout, or a split UnixStream).
#[cfg(not(target_arch = "wasm32"))]
pub struct StreamDc<R, W> {
    tx: tokio::sync::Mutex<W>,
    rx: tokio::sync::Mutex<R>,
}

#[cfg(not(target_arch = "wasm32"))]
impl<R, W> StreamDc<R, W> {
    pub fn new(reader: R, writer: W) -> Self {
        Self { tx: tokio::sync::Mutex::new(writer), rx: tokio::sync::Mutex::new(reader) }
    }
}

/// DcTransport over the process's stdin/stdout (host/plugin
/// IPC). Pair with a plugin that does the inverse.
#[cfg(not(target_arch = "wasm32"))]
pub fn stdio_dc() -> StreamDc<tokio::io::Stdin, tokio::io::Stdout> {
    StreamDc::new(tokio::io::stdin(), tokio::io::stdout())
}

/// Connect a Unix domain socket and frame it as a DcTransport.
#[cfg(all(unix, not(target_arch = "wasm32")))]
pub async fn uds_dc(path: impl AsRef<std::path::Path>) -> Result<StreamDc<tokio::io::ReadHalf<tokio::net::UnixStream>, tokio::io::WriteHalf<tokio::net::UnixStream>>, Status> {
    let stream = tokio::net::UnixStream::connect(path.as_ref())
        .await
        .map_err(|e| Status::unavailable(format!("uds connect: {e}")))?;
    let (rx, tx) = tokio::io::split(stream);
    Ok(StreamDc::new(rx, tx))
}

/// Accept one Unix domain socket connection as a DcTransport
/// (host side; bind with tokio::net::UnixListener).
#[cfg(all(unix, not(target_arch = "wasm32")))]
pub fn uds_dc_accept(stream: tokio::net::UnixStream) -> StreamDc<tokio::io::ReadHalf<tokio::net::UnixStream>, tokio::io::WriteHalf<tokio::net::UnixStream>> {
    let (rx, tx) = tokio::io::split(stream);
    StreamDc::new(rx, tx)
}

#[cfg(not(target_arch = "wasm32"))]
#[async_trait]
impl<R, W> DcTransport for StreamDc<R, W>
where
    R: tokio::io::AsyncRead + Unpin + Send,
    W: tokio::io::AsyncWrite + Unpin + Send,
{
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        use tokio::io::AsyncWriteExt;
        let mut tx = self.tx.lock().await;
        tx.write_u32(msg.len() as u32)
            .await
            .map_err(|e| Status::unavailable(format!("stream write: {e}")))?;
        tx.write_all(&msg)
            .await
            .map_err(|e| Status::unavailable(format!("stream write: {e}")))?;
        tx.flush()
            .await
            .map_err(|e| Status::unavailable(format!("stream write: {e}")))?;
        Ok(())
    }

    async fn next(&self) -> Option<Result<Bytes, Status>> {
        use tokio::io::AsyncReadExt;
        let mut rx = self.rx.lock().await;
        let len = match rx.read_u32().await {
            Ok(n) => n as usize,
            Err(_) => return None,
        };
        let mut buf = vec![0u8; len];
        match rx.read_exact(&mut buf).await {
            Ok(_) => Some(Ok(Bytes::from(buf))),
            Err(e) => Some(Err(Status::unavailable(format!("stream read: {e}")))),
        }
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
    fallback: RwLock<Option<crate::server::MethodHandler>>,
    next_id: AtomicU32,
    send_lock: AsyncMutex<()>,
    traces: Mutex<HashMap<u32, (crate::status::TraceContext, String)>>,
    rendezvous_auth: RwLock<Option<Arc<crate::server::RendezvousAuth>>>,
}

impl Endpoint {
    pub fn new(transport: Arc<dyn DcTransport>, parity: StreamIdParity) -> Arc<Self> {
        Arc::new(Self {
            transport,
            streams: Mutex::new(HashMap::new()),
            services: RwLock::new(HashMap::new()),
            fallback: RwLock::new(None),
            next_id: AtomicU32::new(match parity {
                StreamIdParity::Odd => 1,
                StreamIdParity::Even => 2,
            }),
            send_lock: AsyncMutex::new(()),
            traces: Mutex::new(HashMap::new()),
            rendezvous_auth: RwLock::new(None),
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

    /// Remove every method of `name` (runtime unregistration:
    /// later calls to those paths fail UNIMPLEMENTED).
    pub fn unregister_service(&self, name: &str) {
        let prefix = format!("/{name}/");
        self.services.write().unwrap().retain(|path, _| !path.starts_with(&prefix));
    }

    /// Names of services with at least one registered method,
    /// sorted (registry/discovery source).
    pub fn registered_services(&self) -> Vec<String> {
        let mut names: Vec<String> = self
            .services
            .read()
            .unwrap()
            .keys()
            .filter_map(|path| path[1..].split('/').next().map(str::to_string))
            .collect();
        names.sort();
        names.dedup();
        names
    }

    /// Require rendezvous bearer auth on every inbound call
    /// (see crate::server::RendezvousAuth): verified claims
    /// land on CallCtx.claims.
    pub fn set_rendezvous_auth(&self, auth: Arc<crate::server::RendezvousAuth>) {
        *self.rendezvous_auth.write().unwrap() = Some(auth);
    }

    /// Install a raw handler for paths with no registered
    /// method (generic dispatch; the TCP proxy uses this to
    /// forward arbitrary services without descriptors).
    pub fn set_fallback_handler(&self, handler: crate::server::MethodHandler) {
        *self.fallback.write().unwrap() = Some(handler);
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
                        .or_else(|| self.fallback.read().unwrap().clone())
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
                // Rendezvous auth: verify before dispatch; the
                // failure ends the call trailers-only.
                let claims = {
                    let auth = self.rendezvous_auth.read().unwrap().clone();
                    match auth {
                        None => None,
                        Some(auth) => match auth.verify_metadata(&headers.metadata, &path) {
                            Ok(claims) => Some(claims),
                            Err(status) => {
                                let _ = self
                                    .send_frame(
                                        Frame::trailers(frame.stream_id, &status).unwrap(),
                                    )
                                    .await;
                                return;
                            }
                        },
                    }
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
                let trace_ctx = crate::status::trace_start(
                    "server",
                    &path,
                    crate::status::parse_traceparent(headers.metadata.get("traceparent")),
                );
                let call = ServerCall {
                    ctx: CallCtx {
                        path: path.clone(),
                        metadata: headers.metadata.clone(),
                        claims,
                        trace_context: trace_ctx.clone(),
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
    /// Parent span for this call's client span (usually the
    /// serving span from CallCtx::trace_context). Explicit
    /// traceparent metadata still wins.
    pub trace_parent: Option<crate::status::TraceParent>,
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

    /// Parent this call's client span to a span context (usually
    /// CallCtx::trace_context of the call being served).
    pub fn trace_parent(mut self, ctx: &crate::status::TraceContext) -> Self {
        self.trace_parent = Some(crate::status::trace_parent_of(ctx));
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
            let parent = crate::status::parse_traceparent(metadata.get("traceparent"))
                .or_else(|| options.trace_parent.clone());
            trace_ctx = crate::status::trace_start("client", path, parent);
            if let Some(ctx) = &trace_ctx {
                metadata.insert(
                    "traceparent".to_string(),
                    crate::status::format_traceparent(&ctx.trace_id, &ctx.span_id, ctx.sampled),
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
use crate::status::{Code, Metadata, Status};
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

// ---------------------------------------------------------------------------
// Rendezvous auth tokens: base64url(protobuf claims) + "." +
// base64url(HMAC-SHA256(secret, claims)). Claims wire layout
// (protobuf, no schema dependency): 1 sub, 2 iss, 3 aud
// (strings); 4 exp, 5 nbf, 6 iat (varint seconds); 7 scopes
// (repeated string); 8 jti (string). The same layout is
// implemented in the JS and Go rendezvous code, so one token
// verifies on every stack. Rendezvous-only by design: no
// protoc plugin option. SHA-256/HMAC are implemented natively
// here so the runtime stays dependency-free.

/// The payload of a rendezvous token.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RendezvousClaims {
    pub sub: String,
    pub iss: String,
    pub aud: String,
    pub exp: i64,
    pub nbf: i64,
    pub iat: i64,
    pub scopes: Vec<String>,
    pub jti: String,
}

fn push_varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

fn push_len_field(out: &mut Vec<u8>, field: u64, payload: &[u8]) {
    push_varint(out, (field << 3) | 2);
    push_varint(out, payload.len() as u64);
    out.extend_from_slice(payload);
}

fn push_varint_field(out: &mut Vec<u8>, field: u64, v: i64) {
    push_varint(out, (field << 3) | 0);
    push_varint(out, v as u64);
}

/// Serialize rendezvous claims to protobuf wire bytes.
pub fn encode_rendezvous_claims(claims: &RendezvousClaims) -> Vec<u8> {
    let mut out = Vec::new();
    if !claims.sub.is_empty() {
        push_len_field(&mut out, 1, claims.sub.as_bytes());
    }
    if !claims.iss.is_empty() {
        push_len_field(&mut out, 2, claims.iss.as_bytes());
    }
    if !claims.aud.is_empty() {
        push_len_field(&mut out, 3, claims.aud.as_bytes());
    }
    if claims.exp != 0 {
        push_varint_field(&mut out, 4, claims.exp);
    }
    if claims.nbf != 0 {
        push_varint_field(&mut out, 5, claims.nbf);
    }
    if claims.iat != 0 {
        push_varint_field(&mut out, 6, claims.iat);
    }
    for scope in &claims.scopes {
        push_len_field(&mut out, 7, scope.as_bytes());
    }
    if !claims.jti.is_empty() {
        push_len_field(&mut out, 8, claims.jti.as_bytes());
    }
    out
}

/// Parse rendezvous claims from protobuf wire bytes.
pub fn decode_rendezvous_claims(data: &[u8]) -> Result<RendezvousClaims, Status> {
    let mut claims = RendezvousClaims::default();
    let mut pos = 0usize;
    fn read_varint(data: &[u8], pos: &mut usize) -> Result<u64, Status> {
        let mut v: u64 = 0;
        let mut shift = 0u32;
        loop {
            if *pos >= data.len() {
                return Err(Status::invalid_argument("truncated varint"));
            }
            let b = data[*pos];
            *pos += 1;
            v |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return Ok(v);
            }
            shift += 7;
        }
    }
    while pos < data.len() {
        let tag = read_varint(data, &mut pos)?;
        let field = tag >> 3;
        match tag & 7 {
            2 => {
                let len = read_varint(data, &mut pos)? as usize;
                if pos + len > data.len() {
                    return Err(Status::invalid_argument("truncated length-delimited field"));
                }
                let slice = &data[pos..pos + len];
                pos += len;
                let text = String::from_utf8_lossy(slice).into_owned();
                match field {
                    1 => claims.sub = text,
                    2 => claims.iss = text,
                    3 => claims.aud = text,
                    7 => claims.scopes.push(text),
                    8 => claims.jti = text,
                    _ => {}
                }
            }
            0 => {
                let v = read_varint(data, &mut pos)? as i64;
                match field {
                    4 => claims.exp = v,
                    5 => claims.nbf = v,
                    6 => claims.iat = v,
                    _ => {}
                }
            }
            _ => return Err(Status::invalid_argument("unsupported wire type")),
        }
    }
    Ok(claims)
}

const SHA256_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let bit_len = (data.len() as u64).wrapping_mul(8);
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());
    for chunk in msg.chunks_exact(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([chunk[4 * i], chunk[4 * i + 1], chunk[4 * i + 2], chunk[4 * i + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(SHA256_K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }
    let mut out = [0u8; 32];
    for (i, v) in h.iter().enumerate() {
        out[4 * i..4 * i + 4].copy_from_slice(&v.to_be_bytes());
    }
    out
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut block = [0u8; 64];
    if key.len() > 64 {
        block[..32].copy_from_slice(&sha256(key));
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let mut inner = Vec::with_capacity(64 + data.len());
    inner.extend(block.iter().map(|b| b ^ 0x36));
    inner.extend_from_slice(data);
    let inner_hash = sha256(&inner);
    let mut outer = Vec::with_capacity(64 + 32);
    outer.extend(block.iter().map(|b| b ^ 0x5c));
    outer.extend_from_slice(&inner_hash);
    sha256(&outer)
}

const B64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn b64url_encode(data: &[u8]) -> String {
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(B64URL[(n >> 18) as usize & 63] as char);
        out.push(B64URL[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(B64URL[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(B64URL[n as usize & 63] as char);
        }
    }
    out
}

fn b64url_decode(text: &str) -> Result<Vec<u8>, Status> {
    let mut vals = Vec::with_capacity(text.len());
    for c in text.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' => 62,
            b'_' => 63,
            _ => return Err(Status::invalid_argument("malformed rendezvous token")),
        };
        vals.push(v);
    }
    let mut out = Vec::new();
    for chunk in vals.chunks(4) {
        let mut n: u32 = 0;
        for (i, v) in chunk.iter().enumerate() {
            n |= (*v as u32) << (18 - 6 * i);
        }
        out.push((n >> 16) as u8);
        if chunk.len() > 2 {
            out.push((n >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(n as u8);
        }
    }
    Ok(out)
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Rendezvous bearer-token verification config: `secret` is
/// the HMAC key; `issuer`/`audience`, when set, must match the
/// token's iss/aud; `scopes` maps a method path to the scopes
/// it requires (no entry = any authenticated caller).
#[derive(Clone, Debug)]
pub struct RendezvousAuth {
    pub secret: Vec<u8>,
    pub issuer: String,
    pub audience: String,
    pub scopes: std::collections::HashMap<String, Vec<String>>,
}

impl RendezvousAuth {
    pub fn new(secret: impl Into<Vec<u8>>) -> Self {
        Self {
            secret: secret.into(),
            issuer: String::new(),
            audience: String::new(),
            scopes: std::collections::HashMap::new(),
        }
    }

    /// Verify a token and return its claims. `now_seconds`
    /// overrides the clock (tests).
    pub fn verify_token(
        &self,
        token: &str,
        now_seconds: Option<i64>,
    ) -> Result<RendezvousClaims, Status> {
        let mut parts = token.split('.');
        let (Some(body_part), Some(sig_part), None) =
            (parts.next(), parts.next(), parts.next())
        else {
            return Err(Status::new(Code::Unauthenticated, "malformed rendezvous token"));
        };
        let body = b64url_decode(body_part)
            .map_err(|_| Status::new(Code::Unauthenticated, "malformed rendezvous token"))?;
        let sig = b64url_decode(sig_part)
            .map_err(|_| Status::new(Code::Unauthenticated, "malformed rendezvous token"))?;
        let expected = hmac_sha256(&self.secret, &body);
        let mut diff = (sig.len() != expected.len()) as u8;
        for i in 0..expected.len() {
            diff |= sig.get(i).copied().unwrap_or(0) ^ expected[i];
        }
        if diff != 0 {
            return Err(Status::new(Code::Unauthenticated, "bad rendezvous token signature"));
        }
        let claims = decode_rendezvous_claims(&body)
            .map_err(|_| Status::new(Code::Unauthenticated, "malformed rendezvous claims"))?;
        let now = now_seconds.unwrap_or_else(unix_now);
        if claims.exp != 0 && now >= claims.exp {
            return Err(Status::new(Code::Unauthenticated, "rendezvous token expired"));
        }
        if claims.nbf != 0 && now < claims.nbf {
            return Err(Status::new(Code::Unauthenticated, "rendezvous token not yet valid"));
        }
        if !self.issuer.is_empty() && claims.iss != self.issuer {
            return Err(Status::new(Code::Unauthenticated, "rendezvous token issuer mismatch"));
        }
        if !self.audience.is_empty() && claims.aud != self.audience {
            return Err(Status::new(Code::Unauthenticated, "rendezvous token audience mismatch"));
        }
        Ok(claims)
    }

    /// Verify the `authorization` metadata for `path`:
    /// UNAUTHENTICATED for a bad/missing/expired token,
    /// PERMISSION_DENIED for a valid but under-scoped one.
    pub fn verify_metadata(
        &self,
        metadata: &Metadata,
        path: &str,
    ) -> Result<RendezvousClaims, Status> {
        let header = metadata.get("authorization").cloned().unwrap_or_default();
        let Some(token) = header.strip_prefix("Bearer ") else {
            return Err(Status::new(Code::Unauthenticated, "missing bearer token"));
        };
        if token.is_empty() {
            return Err(Status::new(Code::Unauthenticated, "missing bearer token"));
        }
        let claims = self.verify_token(token, None)?;
        if let Some(required) = self.scopes.get(path) {
            for scope in required {
                if !claims.scopes.iter().any(|s| s == scope) {
                    return Err(Status::new(
                        Code::PermissionDenied,
                        format!("missing required scope {scope}"),
                    ));
                }
            }
        }
        Ok(claims)
    }
}

/// Mint a rendezvous token for `claims` under `secret`.
pub fn issue_rendezvous_token(secret: &[u8], claims: &RendezvousClaims) -> String {
    let body = encode_rendezvous_claims(claims);
    let sig = hmac_sha256(secret, &body);
    format!("{}.{}", b64url_encode(&body), b64url_encode(&sig))
}

/// Per-call context handed to handlers.
#[derive(Clone, Debug)]
pub struct CallCtx {
    pub path: String,
    pub metadata: Metadata,
    /// Verified rendezvous claims (None when the call was not
    /// authenticated; see RendezvousAuth).
    pub claims: Option<RendezvousClaims>,
    /// This call's server span context (None when tracing is
    /// dormant). Pass it to outbound calls via
    /// CallOptions::trace_parent to join the same trace.
    pub trace_context: Option<crate::status::TraceContext>,
    pub stream_id: u32,
    /// Deadline propagated via grpc-timeout, when the client set one.
    pub deadline: Option<crate::platform_time::Instant>,
    pub(crate) response_meta: SharedMeta,
}

impl CallCtx {
    /// Context for a handler invoked in-process with no
    /// transport (embedded library use). Detached contexts
    /// have stream id 0 and no deadline.
    pub fn detached(path: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            metadata: Metadata::default(),
            claims: None,
            trace_context: None,
            stream_id: 0,
            deadline: None,
            response_meta: Arc::new(std::sync::Mutex::new(ResponseMeta::default())),
        }
    }

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

    /// Resolves once the endpoint has forgotten this stream
    /// (peer RST or transport loss), so a response pump can
    /// stop even while the handler's stream is idle: racing
    /// `send` alone only notices on the next produced item.
    pub fn cancelled(&self) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        let ep = self.ep.clone();
        let stream_id = self.stream_id;
        Box::pin(async move {
            while ep.has_stream(stream_id) {
                crate::sleep(std::time::Duration::from_millis(20)).await;
            }
        })
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
                // Race each response poll against cancellation:
                // a send-side failure alone only fires when the
                // next item is produced, so an idle producer
                // would never notice a peer RST. Returning drops
                // `responses`, which stops the handler's stream.
                loop {
                    match futures_util::future::select(responses.next(), sink.cancelled()).await {
                        futures_util::future::Either::Left((Some(item), _)) => {
                            sink.send(item?.encode()).await?;
                        }
                        futures_util::future::Either::Left((None, _)) => break,
                        futures_util::future::Either::Right(((), _)) => return Ok(()),
                    }
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
                // Same cancellation race as server-streaming:
                // stop when the peer RSTs, even if the
                // handler's stream is idle.
                loop {
                    match futures_util::future::select(responses.next(), sink.cancelled()).await {
                        futures_util::future::Either::Left((Some(item), _)) => {
                            sink.send(item?.encode()).await?;
                        }
                        futures_util::future::Either::Left((None, _)) => break,
                        futures_util::future::Either::Right(((), _)) => return Ok(()),
                    }
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

    /// Serve and return the endpoint handle immediately: the
    /// run loop is spawned, and the handle registers or
    /// unregisters services at runtime (host/plugin hosts).
    pub fn serve_handle(transport: Arc<dyn DcTransport>, services: Vec<ServiceDef>) -> Arc<Endpoint> {
        let ep = Endpoint::new(transport, crate::endpoint::StreamIdParity::Even);
        for service in services {
            ep.register_service(service);
        }
        let run_ep = ep.clone();
        crate::spawn_task(async move { run_ep.run().await });
        ep
    }

    /// Serve with rendezvous bearer auth required on every
    /// call (see RendezvousAuth).
    pub async fn serve_with_auth(
        transport: Arc<dyn DcTransport>,
        services: Vec<ServiceDef>,
        auth: Arc<RendezvousAuth>,
    ) {
        let ep = Endpoint::new(transport, crate::endpoint::StreamIdParity::Even);
        ep.set_rendezvous_auth(auth);
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
    endpoint: Arc<DcEndpoint>,
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
            endpoint,
        }
    }

    /// SCTP association counter snapshot for the endpoint
    /// carrying this channel (packet-loss instrumentation).
    pub fn stats(&self) -> Option<dc_webrtc::sctp::AssociationStats> {
        self.endpoint.stats()
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

(define rust-rendezvous-body
#<<GRPC_RUNTIME_EOF
//! Rendezvous server: one fixed, pre-published WebRTC
//! endpoint browsers dial with no signaling exchange. Wraps
//! the WebRTC stack's RendezvousListener: one UDP socket,
//! fixed ICE credentials and DTLS certificate. Publish the
//! returned listener's descriptor(host) wherever browsers
//! can find it; serve HTTP signaling instead when the server
//! address cannot be fixed in advance.

use crate::server::{MethodDef, RendezvousAuth, ServiceDef, Server};
use crate::status::Status;
use crate::transport::DcTransport;
use crate::webrtc_transport::WebRtcDc;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::rendezvous::{RendezvousListener, RendezvousOptions};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

fn clone_services(services: &[ServiceDef]) -> Vec<ServiceDef> {
    services
        .iter()
        .map(|s| ServiceDef {
            name: s.name.clone(),
            methods: s
                .methods
                .iter()
                .map(|m: &MethodDef| MethodDef {
                    name: m.name,
                    kind: m.kind,
                    handler: m.handler.clone(),
                })
                .collect(),
        })
        .collect()
}

fn serve_rendezvous_endpoint(
    endpoint: dc_webrtc::endpoint::DcEndpoint,
    services: Vec<ServiceDef>,
) {
    serve_rendezvous_endpoint_auth(endpoint, services, None)
}

fn serve_rendezvous_endpoint_auth(
    endpoint: dc_webrtc::endpoint::DcEndpoint,
    services: Vec<ServiceDef>,
    auth: Option<Arc<RendezvousAuth>>,
) {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(_) => return,
    };
    runtime.block_on(async move {
        let endpoint = Arc::new(endpoint);
        let ep = endpoint.clone();
        let channel = match tokio::task::spawn_blocking(move || loop {
            match ep.recv_event_timeout(Duration::from_secs(30)) {
                Some(EndpointEvent::ChannelOpened { channel })
                    if channel.label.is_empty() || channel.label == "grpc" =>
                {
                    break Some(channel)
                }
                Some(_) => continue,
                None => break None,
            }
        })
        .await
        {
            Ok(Some(ch)) => ch,
            _ => return,
        };
        let transport: Arc<dyn DcTransport> = Arc::new(WebRtcDc::new(endpoint, channel));
        match auth {
            Some(auth) => Server::serve_with_auth(transport, services, auth).await,
            None => Server::serve(transport, services).await,
        }
    });
}

/// Serve `services` to rendezvous browsers on `addr` and
/// return the listener: publish `listener.descriptor(host)`
/// and call `listener.close()` on shutdown. Ephemeral ICE
/// credentials/certificate rotate per process; use
/// serve_rendezvous_with to fix them.
pub fn serve_rendezvous(
    addr: &str,
    services: Vec<ServiceDef>,
) -> Result<RendezvousListener, Status> {
    serve_rendezvous_with(addr, services, RendezvousOptions::default)
}

/// serve_rendezvous with explicit listener options (fixed
/// ICE credentials/certificate, local IPs, error callback;
/// the endpoint callback is supplied by this adapter).
pub fn serve_rendezvous_with<F>(
    addr: &str,
    services: Vec<ServiceDef>,
    make_options: F,
) -> Result<RendezvousListener, Status>
where
    F: Fn() -> RendezvousOptions,
{
    let socket_addr: SocketAddr = addr
        .parse()
        .map_err(|_| Status::internal("invalid rendezvous address"))?;
    let services = Arc::new(services);
    let mut options = make_options();
    options.on_endpoint = Box::new(move |endpoint| {
        serve_rendezvous_endpoint(endpoint, clone_services(&services));
    });
    RendezvousListener::bind(socket_addr, options)
        .map_err(|e| Status::internal(format!("rendezvous bind: {e}")))
}

/// serve_rendezvous_with with rendezvous bearer auth required
/// on every call (see RendezvousAuth): a bad, missing or
/// expired token fails UNAUTHENTICATED, a valid but
/// under-scoped token fails PERMISSION_DENIED, and verified
/// claims land on CallCtx.claims.
pub fn serve_rendezvous_with_auth<F>(
    addr: &str,
    services: Vec<ServiceDef>,
    auth: RendezvousAuth,
    make_options: F,
) -> Result<RendezvousListener, Status>
where
    F: Fn() -> RendezvousOptions,
{
    let socket_addr: SocketAddr = addr
        .parse()
        .map_err(|_| Status::internal("invalid rendezvous address"))?;
    let services = Arc::new(services);
    let auth = Arc::new(auth);
    let mut options = make_options();
    options.on_endpoint = Box::new(move |endpoint| {
        serve_rendezvous_endpoint_auth(
            endpoint,
            clone_services(&services),
            Some(auth.clone()),
        );
    });
    RendezvousListener::bind(socket_addr, options)
        .map_err(|e| Status::internal(format!("rendezvous bind: {e}")))
}
GRPC_RUNTIME_EOF
)

(define rust-http-signaling-body
#<<GRPC_RUNTIME_EOF
//! HTTP/POST signaling server for browser clients: the server
//! half of the browser signaling contract (see the generated JS
//! `signaling.js`). Each POST creates a fresh `dc_webrtc` Peer,
//! answers the offer, returns the answer JSON immediately, then
//! connects on a background thread and serves the browser's
//! "grpc" channel with `Server::serve`. Non-trickle: the answer
//! carries the peer's host candidates as created; supply a
//! PeerConfig factory when those candidates are not reachable
//! as-is. Auth and CORS belong to the host application; this
//! std-only listener is the standalone no-auth shape.
//!
//! Contract:
//!   POST /grpc-dc/signal  {"type":"offer","sdp":"v=0\r\n..."}
//!   200                   {"type":"answer","sdp":"v=0\r\n..."}

use crate::server::{MethodDef, ServiceDef, Server};
use crate::status::Status;
use crate::transport::DcTransport;
use crate::webrtc_transport::WebRtcDc;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::mux::PeerMux;
use dc_webrtc::peer::{Peer, PeerConfig, RestartHandle};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const SIGNAL_PATH: &str = "/grpc-dc/signal";
const MAX_SIGNAL_BODY: usize = 1 << 20;

static SESSION_SEQ: AtomicU64 = AtomicU64::new(1);

/// One browser session: candidates trickle into the peer's
/// connect via a channel; after connect, the RestartHandle
/// answers ICE restart offers for the same session.
struct SignalingSession {
    trickle_tx: Mutex<Option<Sender<String>>>,
    restart: Mutex<Option<RestartHandle>>,
}

type SessionRegistry = Arc<Mutex<HashMap<String, Arc<SignalingSession>>>>;

fn clone_services(services: &[ServiceDef]) -> Vec<ServiceDef> {
    services
        .iter()
        .map(|s| ServiceDef {
            name: s.name.clone(),
            methods: s
                .methods
                .iter()
                .map(|m: &MethodDef| MethodDef {
                    name: m.name,
                    kind: m.kind,
                    handler: m.handler.clone(),
                })
                .collect(),
        })
        .collect()
}

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\r' => out.push_str("\\r"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Extract one string field from a flat JSON object. Returns
/// None on any malformed input (fail closed).
fn json_string_field(body: &str, field: &str) -> Option<String> {
    let needle = format!("\"{field}\"");
    let after_key = &body[body.find(&needle)? + needle.len()..];
    let after_colon = after_key.trim_start().strip_prefix(':')?.trim_start();
    let mut chars = after_colon.chars();
    if chars.next()? != '"' {
        return None;
    }
    let mut out = String::new();
    let mut rest = chars.as_str();
    loop {
        let mut it = rest.chars();
        match it.next()? {
            '"' => return Some(out),
            '\\' => {
                let esc = it.next()?;
                rest = it.as_str();
                match esc {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'b' => out.push('\u{0008}'),
                    'f' => out.push('\u{000C}'),
                    'u' => {
                        let hex = rest.get(..4)?;
                        out.push(char::from_u32(u32::from_str_radix(hex, 16).ok()?)?);
                        rest = &rest[4..];
                        continue;
                    }
                    _ => return None,
                }
            }
            c => {
                out.push(c);
                rest = it.as_str();
            }
        }
    }
}

fn write_response(stream: &mut TcpStream, status: u16, body: &str) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Internal Server Error",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())
}

fn error_body(message: &str) -> String {
    format!("{{\"error\":\"{}\"}}", json_escape(message))
}

fn serve_peer(
    peer: Peer,
    services: Vec<ServiceDef>,
    session: Arc<SignalingSession>,
    trickle_rx: Receiver<String>,
    registry: SessionRegistry,
    session_id: String,
) {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(_) => {
            registry.lock().unwrap().remove(&session_id);
            return;
        }
    };
    runtime.block_on(async move {
        let (endpoint, restart) =
            match tokio::task::spawn_blocking(move || peer.connect_trickled_with_handle(trickle_rx))
                .await
            {
                Ok(Ok(pair)) => pair,
                _ => {
                    registry.lock().unwrap().remove(&session_id);
                    return;
                }
            };
        *session.restart.lock().unwrap() = Some(restart);
        *session.trickle_tx.lock().unwrap() = None;
        let endpoint = Arc::new(endpoint);
        let ep = endpoint.clone();
        let channel = match tokio::task::spawn_blocking(move || loop {
            match ep.recv_event_timeout(Duration::from_secs(30)) {
                Some(EndpointEvent::ChannelOpened { channel })
                    if channel.label.is_empty() || channel.label == "grpc" =>
                {
                    break Some(channel)
                }
                Some(_) => continue,
                None => break None,
            }
        })
        .await
        {
            Ok(Some(ch)) => ch,
            _ => {
                registry.lock().unwrap().remove(&session_id);
                return;
            }
        };
        let transport: Arc<dyn DcTransport> = Arc::new(WebRtcDc::new(endpoint, channel));
        Server::serve(transport, services).await;
        registry.lock().unwrap().remove(&session_id);
    });
}

fn handle_connection<F>(
    mut stream: TcpStream,
    path: &str,
    services: &[ServiceDef],
    mux: &PeerMux,
    sessions: &SessionRegistry,
    make_peer_config: &F,
) where
    F: Fn() -> PeerConfig,
{
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let header_end = loop {
        if let Some(pos) = find_subslice(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > MAX_SIGNAL_BODY {
            let _ = write_response(&mut stream, 400, &error_body("headers too large"));
            return;
        }
        match stream.read(&mut chunk) {
            Ok(0) => return,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(_) => return,
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or("");
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let request_path = parts.next().unwrap_or("");
    let candidate_path = format!("{path}/candidate");
    let restart_path = format!("{path}/restart");
    let is_signal = request_path == path;
    let is_candidate = request_path == candidate_path;
    let is_restart = request_path == restart_path;
    if !is_signal && !is_candidate && !is_restart {
        let _ = write_response(&mut stream, 404, &error_body("not found"));
        return;
    }
    if method != "POST" {
        let _ = write_response(&mut stream, 405, &error_body("method not allowed"));
        return;
    }
    let content_length = lines
        .filter_map(|line| {
            let (name, value) = line.split_once(':')?;
            if name.trim().eq_ignore_ascii_case("content-length") {
                value.trim().parse::<usize>().ok()
            } else {
                None
            }
        })
        .next()
        .unwrap_or(0);
    if content_length > MAX_SIGNAL_BODY {
        let _ = write_response(&mut stream, 400, &error_body("signaling body too large"));
        return;
    }
    let mut body = buf.split_off(header_end);
    while body.len() < content_length {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => body.extend_from_slice(&chunk[..n]),
            Err(_) => return,
        }
    }
    body.truncate(content_length);
    let body_text = match String::from_utf8(body) {
        Ok(t) => t,
        Err(_) => {
            let _ = write_response(
                &mut stream,
                400,
                &error_body("expected {\"type\":\"offer\",\"sdp\":...}"),
            );
            return;
        }
    };
    if is_candidate || is_restart {
        let session_id = json_string_field(&body_text, "session").unwrap_or_default();
        let session = sessions.lock().unwrap().get(&session_id).cloned();
        let session = match session {
            Some(s) => s,
            None => {
                let _ = write_response(&mut stream, 404, &error_body("unknown session"));
                return;
            }
        };
        if is_candidate {
            let candidate = json_string_field(&body_text, "candidate").unwrap_or_default();
            if let Some(tx) = session.trickle_tx.lock().unwrap().as_ref() {
                let _ = tx.send(candidate);
            }
            let _ = write_response(&mut stream, 200, "{\"ok\":true}");
            return;
        }
        let restart_type = json_string_field(&body_text, "type");
        let restart_sdp = json_string_field(&body_text, "sdp");
        let restart_sdp = match (restart_type.as_deref(), restart_sdp) {
            (Some("offer"), Some(sdp)) if !sdp.is_empty() => sdp,
            _ => {
                let _ = write_response(
                    &mut stream,
                    400,
                    &error_body("expected {\"session\",\"type\":\"offer\",\"sdp\":...}"),
                );
                return;
            }
        };
        let answer = {
            let restart = session.restart.lock().unwrap();
            match restart.as_ref().map(|handle| handle.handle_restart_offer(&restart_sdp)) {
                Some(Ok(answer)) => answer,
                _ => {
                    let _ =
                        write_response(&mut stream, 400, &error_body("invalid restart offer SDP"));
                    return;
                }
            }
        };
        let response = format!(
            "{{\"type\":\"answer\",\"sdp\":\"{}\",\"session\":\"{}\"}}",
            json_escape(&answer),
            json_escape(&session_id)
        );
        let _ = write_response(&mut stream, 200, &response);
        return;
    }
    let offer_type = json_string_field(&body_text, "type");
    let offer_sdp = json_string_field(&body_text, "sdp");
    let offer_sdp = match (offer_type.as_deref(), offer_sdp) {
        (Some("offer"), Some(sdp)) if !sdp.is_empty() => sdp,
        _ => {
            let _ = write_response(
                &mut stream,
                400,
                &error_body("expected {\"type\":\"offer\",\"sdp\":...}"),
            );
            return;
        }
    };
    let mut peer = match mux.new_peer(make_peer_config()) {
        Ok(p) => p,
        Err(_) => {
            let _ = write_response(&mut stream, 500, &error_body("peer creation failed"));
            return;
        }
    };
    let answer = match peer.handle_offer(&offer_sdp) {
        Ok(a) => a,
        Err(_) => {
            let _ = write_response(&mut stream, 400, &error_body("invalid offer SDP"));
            return;
        }
    };
    let session_id = format!(
        "s{}-{}",
        std::process::id(),
        SESSION_SEQ.fetch_add(1, Ordering::Relaxed)
    );
    let (trickle_tx, trickle_rx) = channel();
    let session = Arc::new(SignalingSession {
        trickle_tx: Mutex::new(Some(trickle_tx)),
        restart: Mutex::new(None),
    });
    sessions
        .lock()
        .unwrap()
        .insert(session_id.clone(), session.clone());
    let response = format!(
        "{{\"type\":\"answer\",\"sdp\":\"{}\",\"session\":\"{}\"}}",
        json_escape(&answer),
        json_escape(&session_id)
    );
    if write_response(&mut stream, 200, &response).is_err() {
        sessions.lock().unwrap().remove(&session_id);
        return;
    }
    let services = clone_services(services);
    let registry = sessions.clone();
    std::thread::spawn(move || serve_peer(peer, services, session, trickle_rx, registry, session_id));
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// Start the standalone signaling HTTP listener on `addr`
/// (for example "127.0.0.1:8080") with a default PeerConfig per
/// POST, serving `services` on each browser's "grpc" channel.
/// Every session peer is created on one shared PeerMux bound
/// at the same address (one UDP socket for all sessions).
/// Returns the HTTP listener's bound address (useful with
/// port 0 in tests); the mux's UDP address is the same IP with
/// the mux's own port — use serve_http_signaling_with or
/// serve_http_signaling_muxed to learn it. The listener runs
/// on background threads for the life of the process. Host
/// applications that need auth/CORS should front this listener
/// or implement the same contract themselves.
pub fn serve_http_signaling(addr: &str, services: Vec<ServiceDef>) -> Result<SocketAddr, Status> {
    serve_http_signaling_with(addr, SIGNAL_PATH, services, PeerConfig::default)
}

/// `serve_http_signaling` with a custom path and a factory for
/// each connection's PeerConfig (STUN/TURN servers, local IPs,
/// a persistent DTLS certificate, and so on). Binds a fresh
/// PeerMux at `addr`'s IP with an ephemeral UDP port and
/// returns the HTTP listener's bound address.
pub fn serve_http_signaling_with<F>(
    addr: &str,
    path: &str,
    services: Vec<ServiceDef>,
    make_peer_config: F,
) -> Result<SocketAddr, Status>
where
    F: Fn() -> PeerConfig + Send + Sync + 'static,
{
    let http_addr: SocketAddr = addr
        .parse()
        .map_err(|_| Status::invalid_argument(format!("http-signaling addr: {addr}")))?;
    let mux = Arc::new(
        PeerMux::bind(SocketAddr::new(http_addr.ip(), 0))
            .map_err(|e| Status::unavailable(format!("http-signaling mux: {e}")))?,
    );
    serve_http_signaling_muxed(mux, addr, path, services, make_peer_config)
}

/// Serve signaling on a host-supplied shared PeerMux: several
/// signaling servers in one process can share one mux (one UDP
/// socket). The mux stays caller-owned. Returns the HTTP
/// listener's bound address; the UDP address every session
/// advertises is `mux.local_addr()`.
pub fn serve_http_signaling_muxed<F>(
    mux: Arc<PeerMux>,
    addr: &str,
    path: &str,
    services: Vec<ServiceDef>,
    make_peer_config: F,
) -> Result<SocketAddr, Status>
where
    F: Fn() -> PeerConfig + Send + Sync + 'static,
{
    let listener = TcpListener::bind(addr)
        .map_err(|e| Status::unavailable(format!("http-signaling listen: {e}")))?;
    let bound = listener
        .local_addr()
        .map_err(|e| Status::unavailable(format!("http-signaling addr: {e}")))?;
    let services = Arc::new(services);
    let make_peer_config = Arc::new(make_peer_config);
    let path = path.to_string();
    let sessions: SessionRegistry = Arc::new(Mutex::new(HashMap::new()));
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    let services = services.clone();
                    let make_peer_config = make_peer_config.clone();
                    let path = path.clone();
                    let mux = mux.clone();
                    let sessions = sessions.clone();
                    std::thread::spawn(move || {
                        handle_connection(
                            stream,
                            &path,
                            &services,
                            &mux,
                            &sessions,
                            &*make_peer_config,
                        )
                    });
                }
                Err(_) => break,
            }
        }
    });
    Ok(bound)
}
GRPC_RUNTIME_EOF
)

(define rust-link-stats-body
#<<GRPC_RUNTIME_EOF
//! Unified link statistics for the native wrapper
//! (`dc <-> http2 <-> stock server`): one snapshot shape over
//! the three legs, so packet-loss instrumentation reads the
//! same in every deployment. Each leg is optional — a plain
//! DataChannel call has only SCTP; a stock-server call routed
//! through the wrapper adds the TCP leg (kernel counters are
//! the caller's to fill where the OS leg is used; the smoltcp
//! sidecar reports its own TcpStats) and the HTTP/2 leg.

/// HTTP/2-leg counters (field-for-field mirror of
/// crate::http2::H2Stats, duplicated here so this module
/// builds on wasm32 where the http2 module is absent).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct H2Stats {
    pub frames_sent: u64,
    pub frames_received: u64,
    pub streams_opened: u64,
}

#[cfg(not(target_arch = "wasm32"))]
impl From<crate::http2::H2Stats> for H2Stats {
    fn from(s: crate::http2::H2Stats) -> Self {
        Self {
            frames_sent: s.frames_sent,
            frames_received: s.frames_received,
            streams_opened: s.streams_opened,
        }
    }
}

/// SCTP-leg counters (field-for-field mirror of
/// dc_webrtc::sctp::AssociationStats, duplicated here so
/// this module builds without the webrtc feature).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SctpStats {
    pub packets_sent: u64,
    pub packets_received: u64,
    pub chunks_sent: u64,
    pub chunks_received: u64,
    pub retransmits: u64,
    pub fast_retransmits: u64,
    pub dup_chunks: u64,
}

#[cfg(feature = "webrtc")]
impl From<dc_webrtc::sctp::AssociationStats> for SctpStats {
    fn from(s: dc_webrtc::sctp::AssociationStats) -> Self {
        Self {
            packets_sent: s.packets_sent,
            packets_received: s.packets_received,
            chunks_sent: s.chunks_sent,
            chunks_received: s.chunks_received,
            retransmits: s.retransmits,
            fast_retransmits: s.fast_retransmits,
            dup_chunks: s.dup_chunks,
        }
    }
}

/// TCP-leg counters (same field shape as the smoltcp
/// sidecar's TcpStats; kernel legs may fill what they can).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TcpStats {
    pub frames_sent: u64,
    pub frames_received: u64,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    pub tcp_retransmits: u64,
    pub tcp_retransmit_bytes: u64,
    pub fast_retransmits: u64,
    pub timeout_retransmits: u64,
    pub handshake_rtt_ms: u64,
    pub rtt_samples: u64,
    pub syn_count: u64,
    pub fin_count: u64,
    pub rst_count: u64,
}

/// One link snapshot: SCTP (DataChannel leg), TCP (stock
/// server leg), HTTP/2 (wrapper leg).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LinkStats {
    pub sctp: Option<SctpStats>,
    pub tcp: Option<TcpStats>,
    pub http2: Option<H2Stats>,
}

impl LinkStats {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_sctp(mut self, stats: SctpStats) -> Self {
        self.sctp = Some(stats);
        self
    }

    pub fn with_tcp(mut self, stats: TcpStats) -> Self {
        self.tcp = Some(stats);
        self
    }

    pub fn with_http2(mut self, stats: H2Stats) -> Self {
        self.http2 = Some(stats);
        self
    }

    /// Total retransmitted units across legs that count them
    /// (SCTP chunks + TCP segments); legs without counters
    /// contribute zero.
    pub fn retransmits(&self) -> u64 {
        self.sctp.map_or(0, |s| s.retransmits)
            + self.tcp.map_or(0, |s| s.tcp_retransmits)
    }
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
   (cons "http2.rs"
         (string-replace rust-http2-body "@@H2_TABLES@@" (emit-http2-tables-rust)))
   (cons "link_stats.rs" rust-link-stats-body)
   (cons "server.rs" rust-server-body)
   (cons "dynamic.rs" rust-dynamic-body)
   (cons "webrtc_transport.rs" rust-webrtc-transport-body)
   (cons "webrtc_direct.rs" rust-webrtc-direct-body)
   (cons "http_signaling.rs" rust-http-signaling-body)
   (cons "rendezvous.rs" rust-rendezvous-body)))
