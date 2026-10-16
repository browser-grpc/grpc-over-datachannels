//! dc-webrtc: a WebRTC datachannel stack with zero external crates.
//!
//! Layers (SPEC-WEBRTC.md): STUN/ICE (host candidates), DTLS 1.2
//! (ECDHE-ECDSA AES-128-GCM-SHA256, certificates pinned by SDP
//! fingerprint), SCTP, and DCEP — enough for a browser-grade
//! `RTCDataChannel` with no WebRTC library underneath. Protocol number
//! tables and crypto constants live in `proto_gen`, computed and stamped
//! by the Racket metaprogram (`racket/webrtc-gen.rkt`).

pub mod crypto;
pub mod dcep;
pub mod dtls;
pub mod endpoint;
pub mod ice;
pub mod mdns;
pub mod p256;
pub mod p384;
pub mod peer;
pub mod proto_gen;
pub mod sctp;
pub mod sdp;
pub mod stun;
pub mod tls12;
pub mod turn;
pub mod x509;

pub fn sha256_hex_label() -> &'static str {
    "dc-webrtc"
}
