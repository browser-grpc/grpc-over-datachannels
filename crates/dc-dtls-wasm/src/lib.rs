//! The dc-webrtc DTLS handshake (DtlsHandshake) and
//! established core compiled to wasm32, with the surface
//! the JS adapter (webrtc/js/dtls_wasm.js) pumps like
//! ./dtls.js's DtlsConnection: feed datagrams, tick at
//! next_timeout, encrypt/decrypt app records. Sans-io in
//! the core; this crate is only the language boundary.

use dc_webrtc::dtls::{DtlsConfig, DtlsHandshake};
use dc_webrtc::p256::PrivateKey;
use dc_webrtc::platform::Rng;
use dc_webrtc::x509::Certificate;
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

fn packets_out(packets: &[Vec<u8>]) -> js_sys::Array {
    let arr = js_sys::Array::new();
    for p in packets {
        arr.push(&js_sys::Uint8Array::from(&p[..]).into());
    }
    arr
}

fn build_config(
    cert_der: &[u8],
    key_scalar: &[u8],
    expected_fingerprint: Option<String>,
    require_peer_certificate: bool,
    connection_id: Option<Vec<u8>>,
    pair_hint: Option<Vec<u8>>,
) -> Result<DtlsConfig, JsError> {
    let scalar: [u8; 32] = key_scalar
        .try_into()
        .map_err(|_| JsError::new("key scalar must be 32 bytes"))?;
    let private = PrivateKey::from_bytes(&scalar)
        .ok_or_else(|| JsError::new("invalid P-256 key scalar"))?;
    let public = private.public_key();
    Ok(DtlsConfig {
        certificate: Certificate {
            der: cert_der.to_vec(),
            private,
            public,
        },
        expected_peer_fingerprint: expected_fingerprint,
        require_peer_certificate,
        session_resumption: false,
        session_ticket_key: None,
        connection_id,
        pair_hint,
    })
}

#[wasm_bindgen]
pub struct Dtls {
    machine: DtlsHandshake,
    initial: Vec<Vec<u8>>,
}

#[wasm_bindgen]
impl Dtls {
    #[wasm_bindgen(js_name = newClient)]
    #[allow(clippy::too_many_arguments)]
    pub fn new_client(
        cert_der: &[u8],
        key_scalar: &[u8],
        expected_fingerprint: Option<String>,
        require_peer_certificate: bool,
        connection_id: Option<Vec<u8>>,
        pair_hint: Option<Vec<u8>>,
        now_ms: f64,
    ) -> Result<Dtls, JsError> {
        ensure_entropy();
        let cfg = build_config(
            cert_der,
            key_scalar,
            expected_fingerprint,
            require_peer_certificate,
            connection_id,
            pair_hint,
        )?;
        let (machine, flight) = DtlsHandshake::new_client(&cfg, None, now_ms as u64)
            .map_err(|e| JsError::new(&e.to_string()))?;
        Ok(Dtls {
            machine,
            initial: flight,
        })
    }

    #[wasm_bindgen(js_name = newServer)]
    #[allow(clippy::too_many_arguments)]
    pub fn new_server(
        cert_der: &[u8],
        key_scalar: &[u8],
        expected_fingerprint: Option<String>,
        require_peer_certificate: bool,
        connection_id: Option<Vec<u8>>,
        pair_hint: Option<Vec<u8>>,
        now_ms: f64,
    ) -> Result<Dtls, JsError> {
        ensure_entropy();
        let cfg = build_config(
            cert_der,
            key_scalar,
            expected_fingerprint,
            require_peer_certificate,
            connection_id,
            pair_hint,
        )?;
        Ok(Dtls {
            machine: DtlsHandshake::new_server(&cfg, now_ms as u64),
            initial: Vec::new(),
        })
    }

    /// Initial client flight (empty for a server).
    pub fn start(&mut self) -> js_sys::Array {
        packets_out(&std::mem::take(&mut self.initial))
    }

    #[wasm_bindgen(js_name = handleDatagram)]
    pub fn handle_datagram(&mut self, packet: &[u8], now_ms: f64) -> js_sys::Array {
        packets_out(&self.machine.handle_datagram(packet, now_ms as u64))
    }

    pub fn tick(&mut self, now_ms: f64) -> js_sys::Array {
        packets_out(&self.machine.tick(now_ms as u64))
    }

    #[wasm_bindgen(js_name = nextTimeout)]
    pub fn next_timeout(&self, now_ms: f64) -> f64 {
        self.machine
            .next_timeout(now_ms as u64)
            .map(|v| v as f64)
            .unwrap_or(-1.0)
    }

    #[wasm_bindgen(getter, js_name = isEstablished)]
    pub fn is_established(&self) -> bool {
        self.machine.established()
    }

    #[wasm_bindgen(getter, js_name = wasResumed)]
    pub fn was_resumed(&self) -> bool {
        self.machine.was_resumed()
    }

    pub fn failure(&self) -> String {
        self.machine.failure().map(str::to_string).unwrap_or_default()
    }

    #[wasm_bindgen(js_name = encryptApp)]
    pub fn encrypt_app(&mut self, data: &[u8]) -> Result<Vec<u8>, JsError> {
        self.machine
            .encrypt_app(data)
            .ok_or_else(|| JsError::new("not established"))
    }

    /// One inbound datagram: payload bytes, null when the
    /// datagram carried no app data, throw on a bad record.
    #[wasm_bindgen(js_name = handleApp)]
    pub fn handle_app(&mut self, packet: &[u8]) -> Result<Option<Vec<u8>>, JsError> {
        match self.machine.handle_app_datagram(packet) {
            Some(Ok(payload)) => Ok(payload),
            Some(Err(e)) => Err(JsError::new(&e.to_string())),
            None => Err(JsError::new("not established")),
        }
    }

    #[wasm_bindgen(js_name = peerFingerprint)]
    pub fn peer_fingerprint(&self) -> Option<String> {
        self.machine.peer_fingerprint()
    }
}
