//! Wasm bridge over the REAL grpc_dc Rust runtime: the same
//! byte-level surface the generated Wasm facades call today
//! (js/src/wasm_bridge.js — unary/serverStream/clientStream/
//! bidi by path, protobuf bytes in/out), implemented by the
//! Rust runtime compiled to wasm32 instead of the JS runtime.
//! The only JS touchpoints are the DcTransport send/receive
//! pair (an RTCDataChannel or any message pipe), exactly as
//! in wasm/rust. Facades keep their JS-facing shape; the wire
//! changes owner underneath them.

use bytes::Bytes;
use futures_channel::mpsc;
use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{CallOptions, Channel, DcTransport, Metadata, Status};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use wasm_bindgen::prelude::*;

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

/// DcTransport over the JS hooks (pattern from wasm/rust).
/// Safety: wasm32 is single-threaded, so the !Send JS handles
/// never cross a thread boundary.
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

fn status_error(status: &Status) -> JsValue {
    let obj = js_sys::Object::new();
    let _ = js_sys::Reflect::set(
        &obj,
        &JsValue::from_str("code"),
        &JsValue::from_f64(status.code as i32 as f64),
    );
    let _ = js_sys::Reflect::set(
        &obj,
        &JsValue::from_str("message"),
        &JsValue::from_str(&status.message),
    );
    obj.into()
}

fn options_of(metadata: JsValue, timeout_ms: JsValue) -> CallOptions {
    let mut md: Metadata = HashMap::new();
    if metadata.is_object() {
        let obj = js_sys::Object::from(metadata);
        for entry in js_sys::Object::entries(&obj).iter() {
            let pair = js_sys::Array::from(&entry);
            if pair.length() == 2 {
                md.insert(
                    pair.get(0).as_string().unwrap_or_default(),
                    pair.get(1).as_string().unwrap_or_default(),
                );
            }
        }
    }
    let timeout = if timeout_ms.is_undefined() || timeout_ms.is_null() {
        None
    } else {
        timeout_ms
            .as_f64()
            .map(|ms| std::time::Duration::from_millis(ms as u64))
    };
    CallOptions {
        metadata: md,
        timeout,
        ..Default::default()
    }
}

fn payloads_of(list: JsValue) -> Vec<Vec<u8>> {
    let arr = js_sys::Array::from(&list);
    let mut out = Vec::with_capacity(arr.length() as usize);
    for item in arr.iter() {
        out.push(js_sys::Uint8Array::from(item).to_vec());
    }
    out
}

fn emit(on_message: &js_sys::Function, payload: &[u8]) {
    let view = js_sys::Uint8Array::from(payload);
    let _ = on_message.call1(&JsValue::NULL, &view.into());
}

// ---------------------------------------------------------------------
// Server bridge: JS handlers by path, Rust runtime owns the
// wire — the mirror of js/src/wasm_bridge.js's server bridge
// (registerUnary / registerServerStream / registerClientStream
// / registerBidi / start). Method handler futures capture JS
// values (!Send); wasm32 is single-threaded, so SendFuture
// records that they never cross a thread boundary.

struct SendFuture<F>(F);
unsafe impl<F> Send for SendFuture<F> {}
impl<F: std::future::Future> std::future::Future for SendFuture<F> {
    type Output = F::Output;
    fn poll(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<F::Output> {
        unsafe { self.map_unchecked_mut(|s| &mut s.0) }.poll(cx)
    }
}

struct JsHandler(js_sys::Function);
unsafe impl Send for JsHandler {}
unsafe impl Sync for JsHandler {}

fn js_status(err: JsValue) -> Status {
    let code = js_sys::Reflect::get(&err, &JsValue::from_str("code"))
        .ok()
        .and_then(|v| v.as_f64())
        .map(|n| grpc_dc::Code::from_u32(n as u32).unwrap_or(grpc_dc::Code::Unknown))
        .unwrap_or(grpc_dc::Code::Internal);
    let message = js_sys::Reflect::get(&err, &JsValue::from_str("message"))
        .ok()
        .and_then(|v| v.as_string())
        .unwrap_or_else(|| format!("{err:?}"));
    Status::new(code, message)
}

async fn await_js(value: JsValue) -> Result<JsValue, Status> {
    wasm_bindgen_futures::JsFuture::from(js_sys::Promise::from(value))
        .await
        .map_err(js_status)
}

fn meta_pairs(metadata: &Metadata) -> js_sys::Array {
    let out = js_sys::Array::new();
    for (k, v) in metadata.iter() {
        out.push(&JsValue::from_str(k));
        out.push(&JsValue::from_str(v));
    }
    out
}

fn bytes_arg(payload: &[u8]) -> JsValue {
    js_sys::Uint8Array::from(payload).into()
}

async fn next_request(
    call: &mut ServerCall,
) -> Option<Result<Vec<u8>, Status>> {
    use futures_util::StreamExt;
    call.requests
        .next()
        .await
        .map(|r| r.map(|b| b.to_vec()))
}

use grpc_dc::server::{MethodHandler, ServerCall};
use grpc_dc::{MethodDef, MethodKind, Server, ServiceDef};

fn make_handler(
    kind: MethodKind,
    handler: js_sys::Function,
) -> MethodHandler {
    let handler = std::sync::Arc::new(JsHandler(handler));
    std::sync::Arc::new(move |mut call: ServerCall| {
        let handler = handler.clone();
        let fut = SendFuture(async move {
            let meta = meta_pairs(&call.ctx.metadata);
            match kind {
                MethodKind::Unary => {
                    let req = next_request(&mut call).await;
                    let req = match req {
                        Some(Ok(b)) => b,
                        Some(Err(s)) => return Err(s),
                        None => Vec::new(),
                    };
                    let promise = handler
                        .0
                        .call2(&JsValue::NULL, &bytes_arg(&req), &meta.into())
                        .map_err(js_status)?;
                    let resp = await_js(promise).await?;
                    let bytes = js_sys::Uint8Array::from(resp).to_vec();
                    call.sink.send(bytes).await
                }
                MethodKind::ServerStreaming => {
                    let req = next_request(&mut call).await;
                    let req = match req {
                        Some(Ok(b)) => b,
                        Some(Err(s)) => return Err(s),
                        None => Vec::new(),
                    };
                    let sink = call.sink.clone();
                    let on_message = Closure::wrap(Box::new(move |data: JsValue| {
                        let bytes = js_sys::Uint8Array::from(data).to_vec();
                        let sink = sink.clone();
                        wasm_bindgen_futures::spawn_local(async move {
                            let _ = sink.send(bytes).await;
                        });
                    })
                        as Box<dyn FnMut(JsValue)>);
                    let promise = handler
                        .0
                        .call3(
                            &JsValue::NULL,
                            &bytes_arg(&req),
                            &meta.into(),
                            on_message.as_ref().unchecked_ref(),
                        )
                        .map_err(js_status)?;
                    let result = await_js(promise).await;
                    on_message.forget();
                    result.map(|_| ())
                }
                MethodKind::ClientStreaming => {
                    let mut payloads = Vec::new();
                    while let Some(item) = next_request(&mut call).await {
                        payloads.push(item?);
                    }
                    let list = js_sys::Array::new();
                    for p in &payloads {
                        list.push(&bytes_arg(p));
                    }
                    let promise = handler
                        .0
                        .call2(&JsValue::NULL, &list.into(), &meta.into())
                        .map_err(js_status)?;
                    let resp = await_js(promise).await?;
                    let bytes = js_sys::Uint8Array::from(resp).to_vec();
                    call.sink.send(bytes).await
                }
                MethodKind::BidiStreaming => {
                    let mut payloads = Vec::new();
                    while let Some(item) = next_request(&mut call).await {
                        payloads.push(item?);
                    }
                    let list = js_sys::Array::new();
                    for p in &payloads {
                        list.push(&bytes_arg(p));
                    }
                    let sink = call.sink.clone();
                    let on_message = Closure::wrap(Box::new(move |data: JsValue| {
                        let bytes = js_sys::Uint8Array::from(data).to_vec();
                        let sink = sink.clone();
                        wasm_bindgen_futures::spawn_local(async move {
                            let _ = sink.send(bytes).await;
                        });
                    })
                        as Box<dyn FnMut(JsValue)>);
                    let promise = handler
                        .0
                        .call3(
                            &JsValue::NULL,
                            &list.into(),
                            &meta.into(),
                            on_message.as_ref().unchecked_ref(),
                        )
                        .map_err(js_status)?;
                    let result = await_js(promise).await;
                    on_message.forget();
                    result.map(|_| ())
                }
            }
        });
        Box::pin(fut) as grpc_dc::BoxFuture<'static, Result<(), Status>>
    })
}

/// The server bridge object: register handlers by path,
/// then start() serves them on the transport.
#[wasm_bindgen]
pub struct BridgeServer {
    transport: Arc<WasmTransport>,
    handlers: Vec<(String, MethodKind, js_sys::Function)>,
    started: bool,
}

#[wasm_bindgen]
impl BridgeServer {
    #[wasm_bindgen(constructor)]
    pub fn new(transport: JsTransport) -> BridgeServer {
        let (tx, rx) = mpsc::unbounded::<Vec<u8>>();
        let callback = Closure::wrap(Box::new(move |data: Box<[u8]>| {
            let _ = tx.unbounded_send(data.into_vec());
        }) as Box<dyn FnMut(Box<[u8]>)>);
        transport.set_on_message(&callback);
        BridgeServer {
            transport: Arc::new(WasmTransport {
                js: transport,
                inbox: Mutex::new(rx),
                _callback: callback,
            }),
            handlers: Vec::new(),
            started: false,
        }
    }

    #[wasm_bindgen(js_name = registerUnary)]
    pub fn register_unary(&mut self, path: String, handler: js_sys::Function) {
        self.handlers.push((path, MethodKind::Unary, handler));
    }

    #[wasm_bindgen(js_name = registerServerStream)]
    pub fn register_server_stream(&mut self, path: String, handler: js_sys::Function) {
        self.handlers
            .push((path, MethodKind::ServerStreaming, handler));
    }

    #[wasm_bindgen(js_name = registerClientStream)]
    pub fn register_client_stream(&mut self, path: String, handler: js_sys::Function) {
        self.handlers
            .push((path, MethodKind::ClientStreaming, handler));
    }

    #[wasm_bindgen(js_name = registerBidi)]
    pub fn register_bidi(&mut self, path: String, handler: js_sys::Function) {
        self.handlers.push((path, MethodKind::BidiStreaming, handler));
    }

    /// Group registered paths by service ("/svc/Method") and
    /// serve. Mirrors the JS bridge's start(serviceName);
    /// dispatch is by path, so grouping follows the paths
    /// (the name is accepted for signature parity, unused).
    pub fn start(&mut self, _service_name: Option<String>) {
        if self.started {
            return;
        }
        self.started = true;
        let mut services: Vec<(String, Vec<MethodDef>)> = Vec::new();
        for (path, kind, handler) in std::mem::take(&mut self.handlers) {
            let trimmed = path.trim_start_matches('/');
            let (service, method) = match trimmed.rsplit_once('/') {
                Some((s, m)) => (s.to_string(), m.to_string()),
                None => ("grpc-dc-bridge".to_string(), trimmed.to_string()),
            };
            // MethodDef.name is &'static str; registrations
            // are bounded and process-lifetime, so leak the
            // method segment (documented, tiny).
            let name: &'static str = Box::leak(method.into_boxed_str());
            let def = MethodDef {
                name,
                kind,
                handler: make_handler(kind, handler),
            };
            match services.iter_mut().find(|(n, _)| *n == service) {
                Some((_, methods)) => methods.push(def),
                None => services.push((service, vec![def])),
            }
        }
        let defs: Vec<ServiceDef> = services
            .into_iter()
            .map(|(name, methods)| ServiceDef { name, methods })
            .collect();
        let transport = self.transport.clone();
        wasm_bindgen_futures::spawn_local(async move {
            Server::serve(transport, defs).await;
        });
    }
}

/// The bridge object: one Rust-runtime Channel over one JS
/// transport. Method shapes mirror js/src/wasm_bridge.js.
#[wasm_bindgen]
pub struct BridgeCore {
    channel: Channel,
}

#[wasm_bindgen]
impl BridgeCore {
    #[wasm_bindgen(constructor)]
    pub fn new(transport: JsTransport) -> BridgeCore {
        let (tx, rx) = mpsc::unbounded::<Vec<u8>>();
        let callback = Closure::wrap(Box::new(move |data: Box<[u8]>| {
            let _ = tx.unbounded_send(data.into_vec());
        }) as Box<dyn FnMut(Box<[u8]>)>);
        transport.set_on_message(&callback);
        let wasm_transport = Arc::new(WasmTransport {
            js: transport,
            inbox: Mutex::new(rx),
            _callback: callback,
        });
        BridgeCore {
            channel: Channel::new(wasm_transport),
        }
    }

    /// unary(path, payload, metadata?, timeoutMs?) -> Promise<Uint8Array>
    pub async fn unary(
        &self,
        path: String,
        payload: Vec<u8>,
        metadata: JsValue,
        timeout_ms: JsValue,
    ) -> Result<Vec<u8>, JsValue> {
        self.channel
            .unary_with_options::<Vec<u8>, Vec<u8>>(&path, payload, options_of(metadata, timeout_ms))
            .await
            .map_err(|s| status_error(&s))
    }

    /// serverStream(path, payload, onMessage, metadata?,
    /// timeoutMs?, cancelAfter?) -> Promise<void>.
    /// cancelAfter > 0 stops after that many responses (the
    /// stream is dropped, tearing the call down) and resolves.
    pub async fn server_stream(
        &self,
        path: String,
        payload: Vec<u8>,
        on_message: js_sys::Function,
        metadata: JsValue,
        timeout_ms: JsValue,
        cancel_after: u32,
    ) -> Result<(), JsValue> {
        let mut stream = self
            .channel
            .server_stream_with_options::<Vec<u8>, Vec<u8>>(
                &path,
                payload,
                options_of(metadata, timeout_ms),
            )
            .await
            .map_err(|s| status_error(&s))?;
        let mut seen = 0u32;
        while let Some(item) = stream.next().await {
            match item {
                Ok(resp) => {
                    emit(&on_message, &resp);
                    seen += 1;
                    if cancel_after > 0 && seen >= cancel_after {
                        break;
                    }
                }
                Err(s) => return Err(status_error(&s)),
            }
        }
        Ok(())
    }

    /// clientStream(path, payloads, metadata?, timeoutMs?) -> Promise<Uint8Array>
    pub async fn client_stream(
        &self,
        path: String,
        payloads: JsValue,
        metadata: JsValue,
        timeout_ms: JsValue,
    ) -> Result<Vec<u8>, JsValue> {
        let reqs = futures_util::stream::iter(payloads_of(payloads));
        self.channel
            .client_stream_with_options::<Vec<u8>, Vec<u8>, _>(
                &path,
                reqs,
                options_of(metadata, timeout_ms),
            )
            .await
            .map_err(|s| status_error(&s))
    }

    /// bidi(path, payloads, onMessage, metadata?,
    /// timeoutMs?, cancelAfter?) -> Promise<void>
    pub async fn bidi(
        &self,
        path: String,
        payloads: JsValue,
        on_message: js_sys::Function,
        metadata: JsValue,
        timeout_ms: JsValue,
        cancel_after: u32,
    ) -> Result<(), JsValue> {
        let reqs = futures_util::stream::iter(payloads_of(payloads));
        let mut stream = self
            .channel
            .bidi_with_options::<Vec<u8>, Vec<u8>, _>(
                &path,
                reqs,
                options_of(metadata, timeout_ms),
            )
            .await
            .map_err(|s| status_error(&s))?;
        let mut seen = 0u32;
        while let Some(item) = stream.try_next().await.map_err(|s| status_error(&s))? {
            emit(&on_message, &item);
            seen += 1;
            if cancel_after > 0 && seen >= cancel_after {
                break;
            }
        }
        Ok(())
    }
}
