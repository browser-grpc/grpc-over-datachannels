//! The dc-webrtc ICE agent compiled to wasm32, with the
//! same surface the JS adapter (webrtc/js/ice_wasm.js)
//! presents as ./ice.js's IceAgent: candidates cross as
//! SDP lines, checks/responses as {bytes, addr} objects,
//! events as {kind, addr}. The agent is sans-io in the
//! core; this crate is only the language boundary.

use dc_webrtc::ice::{Candidate, IceAgent, IceEvent};
use dc_webrtc::platform::{ManualClock, Rng};
use std::net::SocketAddr;
use std::sync::Arc;
use wasm_bindgen::prelude::*;

/// Entropy from JS crypto.getRandomValues (same pattern
/// as dc-sctp-wasm): /dev/urandom does not exist on wasm32.
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

fn packet_obj(bytes: &[u8], addr: &SocketAddr) -> JsValue {
    let obj = js_sys::Object::new();
    let _ = js_sys::Reflect::set(
        &obj,
        &JsValue::from_str("bytes"),
        &js_sys::Uint8Array::from(bytes).into(),
    );
    let _ = js_sys::Reflect::set(&obj, &JsValue::from_str("addr"), &JsValue::from_str(&addr.to_string()));
    obj.into()
}

fn packets_out(packets: &[(Vec<u8>, SocketAddr)]) -> js_sys::Array {
    let arr = js_sys::Array::new();
    for (bytes, addr) in packets {
        arr.push(&packet_obj(bytes, addr));
    }
    arr
}

#[wasm_bindgen]
pub struct Ice {
    agent: IceAgent,
    clock: Arc<ManualClock>,
}

#[wasm_bindgen]
impl Ice {
    #[wasm_bindgen(constructor)]
    pub fn new(controlling: bool) -> Ice {
        ensure_entropy();
        // std::time::Instant panics on wasm32, so the agent
        // gets the manual clock; the JS adapter drives it
        // with Date.now() via setTime on every entry point.
        let clock = Arc::new(ManualClock::new(0));
        Ice {
            agent: IceAgent::new_with_clock(controlling, clock.clone()),
            clock,
        }
    }

    /// Set the agent clock (host monotonic milliseconds).
    #[wasm_bindgen(js_name = setTime)]
    pub fn set_time(&self, now_ms: f64) {
        self.clock.set(now_ms as u64);
    }

    #[wasm_bindgen(getter, js_name = localUfrag)]
    pub fn local_ufrag(&self) -> String {
        self.agent.local_ufrag.clone()
    }

    #[wasm_bindgen(getter, js_name = localPwd)]
    pub fn local_pwd(&self) -> String {
        self.agent.local_pwd.clone()
    }

    #[wasm_bindgen(js_name = setLocalCredentials)]
    pub fn set_local_credentials(&mut self, ufrag: &str, pwd: &str) {
        self.agent.local_ufrag = ufrag.to_string();
        self.agent.local_pwd = pwd.to_string();
    }

    #[wasm_bindgen(js_name = addLocalCandidate)]
    pub fn add_local_candidate(&mut self, sdp_line: &str) -> bool {
        let line = sdp_line.strip_prefix("a=").unwrap_or(sdp_line);
        match Candidate::from_sdp(line) {
            Some(cand) => {
                self.agent.local_candidates.push(cand);
                true
            }
            None => false,
        }
    }

    #[wasm_bindgen(js_name = setControlling)]
    pub fn set_controlling(&mut self, controlling: bool) {
        self.agent.controlling = controlling;
    }

    #[wasm_bindgen(getter)]
    pub fn controlling(&self) -> bool {
        self.agent.controlling
    }

    pub fn restart(&mut self) {
        self.agent.restart();
    }

    #[wasm_bindgen(getter)]
    pub fn generation(&self) -> f64 {
        self.agent.generation() as f64
    }

    #[wasm_bindgen(getter)]
    pub fn renominated(&self) -> bool {
        self.agent.renominated()
    }

    #[wasm_bindgen(js_name = setRemote)]
    pub fn set_remote(&mut self, ufrag: &str, pwd: &str) {
        self.agent.set_remote(ufrag, pwd, Vec::new());
    }

    #[wasm_bindgen(js_name = addRemoteCandidate)]
    pub fn add_remote_candidate(&mut self, sdp_line: &str) -> bool {
        let line = sdp_line.strip_prefix("a=").unwrap_or(sdp_line);
        match Candidate::from_sdp(line) {
            Some(cand) => self.agent.add_remote_candidate(cand),
            None => false,
        }
    }

    #[wasm_bindgen(js_name = dueChecks)]
    pub fn due_checks(&mut self) -> js_sys::Array {
        packets_out(&self.agent.due_checks())
    }

    #[wasm_bindgen(js_name = handleStun)]
    pub fn handle_stun(&mut self, packet: &[u8], src: &str) -> JsValue {
        let obj = js_sys::Object::new();
        let Ok(src_addr) = src.parse::<SocketAddr>() else {
            let _ = js_sys::Reflect::set(&obj, &JsValue::from_str("responses"), &js_sys::Array::new().into());
            let _ = js_sys::Reflect::set(&obj, &JsValue::from_str("events"), &js_sys::Array::new().into());
            return obj.into();
        };
        let (responses, events) = self.agent.handle_stun(packet, src_addr);
        let _ = js_sys::Reflect::set(
            &obj,
            &JsValue::from_str("responses"),
            &packets_out(&responses).into(),
        );
        let events_js = js_sys::Array::new();
        for ev in &events {
            let (kind, remote) = match ev {
                IceEvent::PairValid { remote } => (1u32, remote),
                IceEvent::Nominated { remote } => (2u32, remote),
            };
            let e = js_sys::Object::new();
            let _ = js_sys::Reflect::set(&e, &JsValue::from_str("kind"), &JsValue::from_f64(kind as f64));
            let _ = js_sys::Reflect::set(&e, &JsValue::from_str("addr"), &JsValue::from_str(&remote.to_string()));
            events_js.push(&e.into());
        }
        let _ = js_sys::Reflect::set(&obj, &JsValue::from_str("events"), &events_js.into());
        obj.into()
    }

    #[wasm_bindgen(js_name = consentCheck)]
    pub fn consent_check(&mut self) -> JsValue {
        match self.agent.consent_check() {
            Some((bytes, addr)) => packet_obj(&bytes, &addr),
            None => JsValue::NULL,
        }
    }

    #[wasm_bindgen(js_name = touchConsent)]
    pub fn touch_consent(&mut self) {
        self.agent.touch_consent();
    }

    #[wasm_bindgen(js_name = consentExpired)]
    pub fn consent_expired(&self, expiry_ms: f64) -> bool {
        self.agent
            .consent_expired(core::time::Duration::from_millis(expiry_ms as u64))
    }

    #[wasm_bindgen(getter)]
    pub fn nominated(&self) -> Option<String> {
        self.agent.nominated.map(|a| a.to_string())
    }
}
