//! The dc-webrtc SCTP association compiled to wasm32, with
//! the same surface as webrtc/js/sctp.js's Association
//! (sans-io pump: packets and events cross as Uint8Array /
//! plain objects). Lets the JS stack run the shared Rust
//! core instead of the mirrored JS stack; conformance is
//! the shared fixtures/sctp_vectors.json scenarios, run
//! through this module by webrtc/js tests.

use dc_webrtc::platform::Rng;
use dc_webrtc::sctp::{Association, Event, SendOptions};
use std::sync::Arc;
use wasm_bindgen::prelude::*;

/// Entropy from JS crypto.getRandomValues: dc-webrtc's
/// default RNG reads /dev/urandom, which does not exist on
/// wasm32, so the core installs this source on first use.
struct JsRng;

impl Rng for JsRng {
    fn fill(&self, dest: &mut [u8]) {
        let global = js_sys::global();
        let crypto = js_sys::Reflect::get(&global, &JsValue::from_str("crypto"))
            .expect("crypto global");
        let get_random = js_sys::Reflect::get(&crypto, &JsValue::from_str("getRandomValues"))
            .expect("crypto.getRandomValues");
        let get_random: &js_sys::Function = get_random.unchecked_ref();
        for chunk in dest.chunks_mut(65536) {
            let arr = js_sys::Uint8Array::new_with_length(chunk.len() as u32);
            get_random
                .call1(&crypto, &JsValue::from(arr.clone()))
                .expect("getRandomValues call");
            arr.copy_to(chunk);
        }
    }
}

fn ensure_entropy() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        dc_webrtc::platform::install_rng(Arc::new(JsRng));
    });
}

#[wasm_bindgen]
pub struct SctpAssoc {
    inner: Association,
}

fn packets_out(packets: &[Vec<u8>]) -> Vec<js_sys::Uint8Array> {
    packets.iter().map(|p| js_sys::Uint8Array::from(&p[..])).collect()
}

fn events_out(events: &[Event]) -> Vec<JsValue> {
    events
        .iter()
        .map(|e| {
            let obj = js_sys::Object::new();
            let set = |k: &str, v: JsValue| {
                let _ = js_sys::Reflect::set(&obj, &JsValue::from_str(k), &v);
            };
            match e {
                Event::Connected => set("type", JsValue::from_str("connected")),
                Event::Data {
                    stream,
                    ppid,
                    payload,
                } => {
                    set("type", JsValue::from_str("data"));
                    set("stream", JsValue::from_f64(*stream as f64));
                    set("ppid", JsValue::from_f64(*ppid as f64));
                    set(
                        "payload",
                        js_sys::Uint8Array::from(&payload[..]).into(),
                    );
                }
                Event::StreamReset { stream } => {
                    set("type", JsValue::from_str("stream-reset"));
                    set("stream", JsValue::from_f64(*stream as f64));
                }
                Event::Closed => set("type", JsValue::from_str("closed")),
            }
            obj.into()
        })
        .collect()
}

fn result_out(packets: Vec<Vec<u8>>, events: Vec<Event>) -> JsValue {
    let obj = js_sys::Object::new();
    let packets_js = js_sys::Array::new();
    for p in packets_out(&packets) {
        packets_js.push(&p);
    }
    let events_js = js_sys::Array::new();
    for e in events_out(&events) {
        events_js.push(&e);
    }
    let _ = js_sys::Reflect::set(&obj, &JsValue::from_str("packets"), &packets_js.into());
    let _ = js_sys::Reflect::set(&obj, &JsValue::from_str("events"), &events_js.into());
    obj.into()
}

#[wasm_bindgen]
impl SctpAssoc {
    #[wasm_bindgen(js_name = newClient)]
    pub fn new_client(local_port: u16, peer_port: u16) -> SctpAssoc {
        ensure_entropy();
        SctpAssoc {
            inner: Association::new_client(local_port, peer_port),
        }
    }

    #[wasm_bindgen(js_name = newServer)]
    pub fn new_server(local_port: u16, peer_port: u16) -> SctpAssoc {
        ensure_entropy();
        SctpAssoc {
            inner: Association::new_server(local_port, peer_port),
        }
    }

    #[wasm_bindgen(getter, js_name = isEstablished)]
    pub fn is_established(&self) -> bool {
        self.inner.is_established()
    }

    pub fn connect(&mut self, now_ms: f64) -> Vec<u8> {
        self.inner.connect(now_ms as u64)
    }

    #[wasm_bindgen(js_name = sendData)]
    pub fn send_data(
        &mut self,
        stream: u16,
        ppid: u32,
        payload: &[u8],
        unordered: bool,
        max_retransmits: i32,
        max_lifetime_ms: f64,
        now_ms: f64,
    ) -> Vec<js_sys::Uint8Array> {
        let opts = SendOptions {
            unordered,
            max_retransmits: if max_retransmits < 0 {
                None
            } else {
                Some(max_retransmits as u32)
            },
            max_lifetime_ms: if max_lifetime_ms < 0.0 {
                None
            } else {
                Some(max_lifetime_ms as u64)
            },
        };
        packets_out(&self.inner.send_data(stream, ppid, payload, opts, now_ms as u64))
    }

    #[wasm_bindgen(js_name = handlePacket)]
    pub fn handle_packet(&mut self, packet: &[u8], now_ms: f64) -> JsValue {
        let (packets, events) = self.inner.handle_packet(packet, now_ms as u64);
        result_out(packets, events)
    }

    pub fn tick(&mut self, now_ms: f64) -> JsValue {
        let (packets, events) = self.inner.tick(now_ms as u64);
        result_out(packets, events)
    }

    pub fn stats(&self) -> Vec<f64> {
        let s = self.inner.stats();
        vec![
            s.packets_sent as f64,
            s.packets_received as f64,
            s.chunks_sent as f64,
            s.chunks_received as f64,
            s.retransmits as f64,
            s.fast_retransmits as f64,
            s.dup_chunks as f64,
        ]
    }

    #[wasm_bindgen(js_name = closeStream)]
    pub fn close_stream(&mut self, stream: u16) -> Vec<js_sys::Uint8Array> {
        packets_out(&self.inner.close_stream(stream))
    }

    pub fn close(&mut self, now_ms: f64) -> Vec<js_sys::Uint8Array> {
        packets_out(&self.inner.close(now_ms as u64))
    }
}
