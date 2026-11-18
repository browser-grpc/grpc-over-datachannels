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
