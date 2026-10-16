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
use grpc_dc::{CallOptions, Channel, DcTransport, Status};
use serde::Serialize;
use std::sync::Arc;
use tokio::sync::Mutex;
use wasm_bindgen::prelude::*;

#[path = "../../../rust/examples/echo_demo/pb.rs"]
mod pb;

#[path = "../../../rust/gen/echo_grpc_dc.rs"]
mod stub;

use stub::EchoClient;

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
}

fn req(message: &str, count: i32) -> pb::EchoRequest {
    pb::EchoRequest { message: message.into(), count, delay_ms: 0 }
}

/// Run the generated Echo client over the given JS transport and
/// resolve with a JSON summary (same shape the Go WASM facade and
/// the JS client produce, so one Node test can assert all three).
#[wasm_bindgen]
pub async fn echo_client(transport: JsTransport) -> Result<String, JsValue> {
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
    let client = EchoClient::new(Channel::new(wasm_transport));

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
        })
    };
    match run.await {
        Ok(results) => {
            serde_json::to_string(&results).map_err(|e| JsValue::from_str(&e.to_string()))
        }
        Err(status) => Err(JsValue::from_str(&format!("{status}"))),
    }
}
