//! Native WASM Rust client: the actual `grpc_dc` Rust runtime
//! (frame codec, endpoint multiplexer, generated Echo stub) compiled
//! to wasm32 and driven by the browser event loop through
//! `grpc_dc::spawn_task`. The only JS touchpoints are the
//! RTCDataChannel send/receive pair below — unlike wasm/go (a facade
//! over the JS implementation), every gRPC byte here is produced and
//! consumed by Rust code.

use bytes::Bytes;
use futures_channel::mpsc;
use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{CallCtx, CallOptions, Channel, DcTransport, RequestStream, ResponseStream, Server, Status};
use serde::Serialize;
use std::sync::Arc;
use tokio::sync::Mutex;
use wasm_bindgen::prelude::*;

#[path = "../../../rust/gen/echo_pb.rs"]
mod pb;

#[path = "../../../rust/examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../../../rust/gen/echo_grpc_dc.rs"]
mod stub;

use stub::{echo_service, Echo, EchoClient};

/// JS-side transport hooks: the page hands us an object with
/// `send(Uint8Array)` and lets us register the inbound callback.
#[wasm_bindgen]
extern "C" {
    pub type JsTransport;

    #[wasm_bindgen(method)]
    fn send(this: &JsTransport, data: &[u8]);

    #[wasm_bindgen(method, js_name = setOnMessage)]
    fn set_on_message(this: &JsTransport, callback: &Closure<dyn FnMut(Box<[u8]>)>);
}

/// DcTransport over the JS hooks. Inbound messages arrive through an
/// mpsc fed by the JS callback; send is a direct JS call.
///
/// Safety: wasm32 is single-threaded, so the !Send JS handles never
/// cross a thread boundary; the unsafe Send/Sync impls record that.
struct WasmTransport {
    #[allow(dead_code)]
    js: JsTransport,
    inbox: Mutex<mpsc::UnboundedReceiver<Vec<u8>>>,
    _callback: Closure<dyn FnMut(Box<[u8]>)>,
}

unsafe impl Send for WasmTransport {}
unsafe impl Sync for WasmTransport {}

#[grpc_dc::async_trait]
impl DcTransport for WasmTransport {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        self.js.send(&msg);
        Ok(())
    }

    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut inbox = self.inbox.lock().await;
        inbox.next().await.map(|data| Ok(Bytes::from(data)))
    }
}

#[derive(Serialize)]
struct EchoResults {
    unary: String,
    ticks: Vec<String>,
    joined: String,
    echoed: Vec<String>,
    #[serde(rename = "deadlineCode")]
    deadline_code: i32,
    #[serde(rename = "unaryFailureCode")]
    unary_failure_code: i32,
    #[serde(rename = "metadataMessage")]
    metadata_message: String,
    #[serde(rename = "serverStreamFailureCode")]
    server_stream_failure_code: i32,
    #[serde(rename = "bidiFailureCode")]
    bidi_failure_code: i32,
    #[serde(rename = "unknownMethodCode")]
    unknown_method_code: i32,
    #[serde(rename = "cancelTerminated")]
    cancel_terminated: bool,
}

fn req(message: &str, count: i32) -> pb::EchoRequest {
    pb::EchoRequest { message: message.into(), count, delay_ms: 0, ..Default::default() }
}

fn wasm_transport(transport: JsTransport) -> Arc<WasmTransport> {
    let (tx, rx) = mpsc::unbounded::<Vec<u8>>();
    let callback = Closure::wrap(Box::new(move |data: Box<[u8]>| {
        let _ = tx.unbounded_send(data.into_vec());
    }) as Box<dyn FnMut(Box<[u8]>)>);
    transport.set_on_message(&callback);
    Arc::new(WasmTransport {
        js: transport,
        inbox: Mutex::new(rx),
        _callback: callback,
    })
}

/// Run the generated Echo client over the given JS transport and
/// resolve with a JSON summary (same shape the Go WASM facade and
/// the JS client produce, so one Node test can assert all three).
#[wasm_bindgen]
pub async fn echo_client(transport: JsTransport) -> Result<String, JsValue> {
    let channel = Channel::new(wasm_transport(transport));
    let client = EchoClient::new(channel.clone());

    let run = async {
        let unary = client.unary(req("hello", 0)).await?;
        let mut stream = client.server_stream(req("tick", 3)).await?;
        let mut ticks = Vec::new();
        while let Some(resp) = stream.next().await {
            let resp = resp?;
            ticks.push(format!("{}#{}", resp.message, resp.index));
        }
        let reqs = futures_util::stream::iter(vec![req("a", 0), req("b", 0), req("c", 0)]);
        let joined = client.client_stream(reqs).await?;
        let reqs = futures_util::stream::iter(vec![req("x", 0), req("y", 0)]);
        let mut bidi = client.bidi(reqs).await?;
        let mut echoed = Vec::new();
        while let Some(resp) = bidi.try_next().await? {
            echoed.push(resp.message);
        }
        // BDD deepening: failure, metadata, unknown-method, and
        // cancellation scenarios executed by this module.
        let unary_failure_code = match client.unary(req("fail", 0)).await {
            Ok(_) => 0,
            Err(status) => status.code as i32,
        };
        let mut md: std::collections::HashMap<String, String> = Default::default();
        md.insert("x-echo".to_string(), "meta".to_string());
        let metadata_resp: pb::EchoResponse = channel
            .unary_with("/echo.Echo/Unary", req("hello", 0), md)
            .await?;
        let metadata_message = metadata_resp.message;
        let server_stream_failure_code = {
            let mut stream = client.server_stream(req("fail", 3)).await?;
            let mut code = 0;
            while let Some(item) = stream.next().await {
                if let Err(status) = item {
                    code = status.code as i32;
                    break;
                }
            }
            code
        };
        let bidi_failure_code = {
            let reqs = futures_util::stream::iter(vec![req("fail", 0)]);
            let mut stream = client.bidi(reqs).await?;
            let mut code = 0;
            while let Some(item) = stream.next().await {
                if let Err(status) = item {
                    code = status.code as i32;
                    break;
                }
            }
            code
        };
        let unknown_method_code = {
            let result: Result<pb::EchoResponse, Status> =
                channel.unary("/echo.Echo/Nope", req("hello", 0)).await;
            match result {
                Ok(_) => 0,
                Err(status) => status.code as i32,
            }
        };
        let cancel_terminated = {
            let mut stream = client.server_stream(req("tick", 5)).await?;
            let first = stream.next().await;
            drop(stream);
            matches!(first, Some(Ok(_)))
        };

        let mut slow = req("slow", 0);
        slow.delay_ms = 400;
        let deadline_code = match client
            .unary_with_options(
                slow,
                CallOptions::with_timeout(std::time::Duration::from_millis(50)),
            )
            .await
        {
            Ok(_) => 0,
            Err(status) => status.code as i32,
        };
        Ok::<EchoResults, Status>(EchoResults {
            unary: unary.message,
            ticks,
            joined: joined.message,
            echoed,
            deadline_code,
            unary_failure_code,
            metadata_message,
            server_stream_failure_code,
            bidi_failure_code,
            unknown_method_code,
            cancel_terminated,
        })
    };
    match run.await {
        Ok(results) => {
            serde_json::to_string(&results).map_err(|e| JsValue::from_str(&e.to_string()))
        }
        Err(status) => Err(JsValue::from_str(&format!("{status}"))),
    }
}

// ---------------------------------------------------------------------------
// Server (browser-as-server): the generated Echo service over the
// same JS transport, event-driven on the page thread (no worker
// or blocking mailbox — the Rust runtime is async throughout).
// The Node test's JS client drives the four call shapes plus a
// deadline the slow handler must miss.
// ---------------------------------------------------------------------------

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(&self, req: pb::EchoRequest, ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        if req.delay_ms > 0 {
            grpc_dc::sleep(std::time::Duration::from_millis(req.delay_ms as u64)).await;
        }
        if req.message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        let suffix =
            ctx.metadata.get("x-echo").map(|v| format!(" [{v}]")).unwrap_or_default();
        Ok(pb::EchoResponse { message: format!("echo: {}{}", req.message, suffix), index: 0, ..Default::default() })
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        if req.message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        let responses = (0..req.count.max(0))
            .map(move |i| Ok(pb::EchoResponse { message: req.message.clone(), index: i, ..Default::default() }));
        Ok(Box::pin(futures_util::stream::iter(responses)))
    }

    async fn client_stream(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let mut parts: Vec<String> = Vec::new();
        let mut reqs = reqs;
        while let Some(req) = reqs.next().await {
            let req = req?;
            if req.message == "fail" {
                return Err(Status::invalid_argument("asked to fail"));
            }
            parts.push(req.message);
        }
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32, ..Default::default() })
    }

    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream =
            futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut index)| async move {
                match reqs.next().await {
                    Some(Ok(req)) => {
                        if req.message == "fail" {
                            return Some((Err(Status::invalid_argument("asked to fail")), (reqs, index)));
                        }
                        let resp = pb::EchoResponse { message: req.message, index, ..Default::default() };
                        index += 1;
                        Some((Ok(resp), (reqs, index)))
                    }
                    Some(Err(e)) => Some((Err(e), (reqs, index))),
                    None => None,
                }
            });
        Ok(Box::pin(stream))
    }
}

// ---------------------------------------------------------------------------
// Nested tracing (browser): client -> front callee -> downstream
// service over loopback transports, entirely in this module, with
// a recording span observer. Asserts (in the Node driver) one
// shared trace id and the full client/server parent chain.
// ---------------------------------------------------------------------------

#[derive(Default)]
struct TracingRecorder {
    starts: std::sync::Mutex<Vec<[String; 5]>>,
    ends: std::sync::Mutex<Vec<String>>,
}

impl grpc_dc::status::Tracer for TracingRecorder {
    fn on_start(&self, kind: &str, _method: &str, trace_id: &str, span_id: &str, parent_span_id: &str) {
        self.starts.lock().unwrap().push([
            kind.into(),
            trace_id.into(),
            span_id.into(),
            parent_span_id.into(),
            String::new(),
        ]);
    }
    fn on_end(&self, kind: &str, _method: &str, _trace_id: &str, _span_id: &str, _status: &str, _duration_ms: f64) {
        self.ends.lock().unwrap().push(kind.into());
    }
}

struct FrontService {
    downstream: EchoClient,
    seen_span: Arc<std::sync::Mutex<String>>,
}

#[grpc_dc::async_trait]
impl Echo for FrontService {
    async fn unary(&self, _req: pb::EchoRequest, ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        if let Some(trace) = &ctx.trace_context {
            *self.seen_span.lock().unwrap() = trace.span_id.clone();
        }
        let options = match &ctx.trace_context {
            Some(trace) => CallOptions::new().trace_parent(trace),
            None => CallOptions::new(),
        };
        self.downstream.unary_with_options(req("nested", 0), options).await
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let responses = (0..req.count.max(0))
            .map(move |i| Ok(pb::EchoResponse { message: req.message.clone(), index: i, ..Default::default() }));
        Ok(Box::pin(futures_util::stream::iter(responses)))
    }

    async fn client_stream(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let parts: Vec<String> = reqs.map_ok(|r| r.message).try_collect().await?;
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32, ..Default::default() })
    }

    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream = futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut index)| async move {
            match reqs.next().await {
                Some(Ok(req)) => {
                    let resp = pb::EchoResponse { message: req.message, index, ..Default::default() };
                    index += 1;
                    Some((Ok(resp), (reqs, index)))
                }
                Some(Err(e)) => Some((Err(e), (reqs, index))),
                None => None,
            }
        });
        Ok(Box::pin(stream))
    }
}

#[derive(Serialize)]
struct TracingResults {
    message: String,
    #[serde(rename = "seenSpan")]
    seen_span: String,
    starts: Vec<[String; 5]>,
    ends: Vec<String>,
}

/// Run the nested tracing scenario and resolve with its JSON.
#[wasm_bindgen]
pub async fn echo_tracing() -> Result<String, JsValue> {
    let recorder = Arc::new(TracingRecorder::default());
    grpc_dc::status::set_tracer(Some(recorder.clone()));
    let seen_span = Arc::new(std::sync::Mutex::new(String::new()));

    let (down_a, down_b) = grpc_dc::loopback_pair();
    wasm_bindgen_futures::spawn_local(async move {
        Server::serve(Arc::new(down_b), vec![echo_service(Arc::new(EchoService))]).await;
    });
    let downstream = EchoClient::new(Channel::new(Arc::new(down_a)));

    let (front_a, front_b) = grpc_dc::loopback_pair();
    let front = FrontService { downstream, seen_span: seen_span.clone() };
    wasm_bindgen_futures::spawn_local(async move {
        Server::serve(Arc::new(front_b), vec![echo_service(Arc::new(front))]).await;
    });
    let client = EchoClient::new(Channel::new(Arc::new(front_a)));

    let result = client.unary(req("hello", 0)).await;
    grpc_dc::status::set_tracer(None);
    match result {
        Ok(resp) => {
            let results = TracingResults {
                message: resp.message,
                seen_span: seen_span.lock().unwrap().clone(),
                starts: recorder.starts.lock().unwrap().clone(),
                ends: recorder.ends.lock().unwrap().clone(),
            };
            serde_json::to_string(&results).map_err(|e| JsValue::from_str(&e.to_string()))
        }
        Err(status) => Err(JsValue::from_str(&format!("{status}"))),
    }
}

/// Serve the generated Echo service over the given JS transport.
/// Returns immediately; serving runs as a local task until the
/// transport closes.
#[wasm_bindgen]
pub fn echo_server(transport: JsTransport) {
    let transport = wasm_transport(transport);
    wasm_bindgen_futures::spawn_local(async move {
        Server::serve(transport, vec![echo_service(Arc::new(EchoService))]).await;
    });
}

// ---------------------------------------------------------------------------
// Matrix tracing entries: single-unary tracing client and a
// tracing server whose spans the page can read back, so the
// Wasm matrix test can assert span parenting across the
// native/facade boundary in both directions.
// ---------------------------------------------------------------------------

static MATRIX_RECORDER: std::sync::OnceLock<Arc<TracingRecorder>> = std::sync::OnceLock::new();

fn matrix_recorder() -> Arc<TracingRecorder> {
    MATRIX_RECORDER.get_or_init(|| Arc::new(TracingRecorder::default())).clone()
}

#[derive(Serialize)]
struct MatrixClientResults {
    message: String,
    starts: Vec<[String; 5]>,
    ends: Vec<String>,
    #[serde(rename = "largeBytes")]
    large_bytes: usize,
}

#[derive(Serialize)]
struct MatrixSpans {
    starts: Vec<[String; 5]>,
    ends: Vec<String>,
}

/// One unary call over the JS transport with the recorder
/// registered; resolves with the response plus recorded spans.
#[wasm_bindgen]
pub async fn echo_client_tracing(transport: JsTransport) -> Result<String, JsValue> {
    let recorder = Arc::new(TracingRecorder::default());
    grpc_dc::status::set_tracer(Some(recorder.clone()));
    let client = EchoClient::new(Channel::new(wasm_transport(transport)));
    let result = client.unary(req("hello", 0)).await;
    grpc_dc::status::set_tracer(None);
    // Large-message leg on the same endpoint: 512 KiB unary,
    // twice the browser RTCDataChannel single-message cap
    // (256 KiB), so the frame crosses as DC chunks (0xF0 shim
    // in the page glue + relay); the endpoint sees one whole
    // frame. 512 KiB is the matrix echo size for every
    // server (Swift facade included; multi-MiB Swift facade
    // calls are covered in wasm_swift_facade_server.test.mjs
    // after its allocator gained a real free list); the
    // stacks and JS runtime move 1 MiB+ in their own
    // chunking tests. The multi-MB stall class must stay
    // dead in browsers too.
    let large = client.unary(req(&"x".repeat(512 * 1024), 0)).await;
    match (result, large) {
        (Ok(resp), Ok(big)) => {
            let results = MatrixClientResults {
                message: resp.message,
                starts: recorder.starts.lock().unwrap().clone(),
                ends: recorder.ends.lock().unwrap().clone(),
                large_bytes: big.message.len(),
            };
            serde_json::to_string(&results).map_err(|e| JsValue::from_str(&e.to_string()))
        }
        (Err(status), _) | (_, Err(status)) => {
            Err(JsValue::from_str(&format!("{status}")))
        }
    }
}

/// Serve Echo over the JS transport with the matrix recorder
/// registered (spans readable via echo_tracing_spans).
#[wasm_bindgen]
pub fn echo_server_tracing(transport: JsTransport) {
    grpc_dc::status::set_tracer(Some(matrix_recorder()));
    let transport = wasm_transport(transport);
    wasm_bindgen_futures::spawn_local(async move {
        Server::serve(transport, vec![echo_service(Arc::new(EchoService))]).await;
    });
}

/// JSON snapshot of the matrix recorder's spans.
#[wasm_bindgen]
pub fn echo_tracing_spans() -> String {
    let spans = MatrixSpans {
        starts: matrix_recorder().starts.lock().unwrap().clone(),
        ends: matrix_recorder().ends.lock().unwrap().clone(),
    };
    serde_json::to_string(&spans).unwrap_or_else(|_| "{\"starts\":[],\"ends\":[]}".into())
}
