//! SDP (RFC 8866) offer/answer subset for one datachannel m-section:
//! ice-ufrag/pwd, DTLS fingerprint + setup, host candidates, sctp-port.

use alloc::string::{String, ToString};
use alloc::vec::Vec;
use crate::ice::Candidate;

#[derive(Clone, Debug, PartialEq)]
pub struct SessionDescription {
    pub ufrag: String,
    pub pwd: String,
    pub fingerprint: String,
    pub setup: String, // actpass | active | passive
    pub candidates: Vec<Candidate>,
    pub sctp_port: u16,
}

pub fn generate(desc: &SessionDescription, is_offer: bool) -> String {
    let mut lines = vec![
        "v=0".to_string(),
        "o=- 4611733050420606744 2 IN IP4 127.0.0.1".to_string(),
        "s=-".to_string(),
        "t=0 0".to_string(),
        "a=group:BUNDLE 0".to_string(),
        "a=extmap-allow-mixed".to_string(),
        "a=msid-semantic: WMS".to_string(),
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel".to_string(),
        "c=IN IP4 0.0.0.0".to_string(),
    ];
    for cand in &desc.candidates {
        lines.push(cand.to_sdp());
    }
    lines.push("a=end-of-candidates".to_string());
    lines.push(format!("a=ice-ufrag:{}", desc.ufrag));
    lines.push(format!("a=ice-pwd:{}", desc.pwd));
    lines.push("a=ice-options:trickle".to_string());
    lines.push(format!("a=fingerprint:sha-256 {}", desc.fingerprint));
    lines.push(format!("a=setup:{}", if is_offer { "actpass" } else { &desc.setup }));
    lines.push("a=mid:0".to_string());
    lines.push(format!("a=sctp-port:{}", desc.sctp_port));
    lines.push("a=max-message-size:262144".to_string());
    let mut out = lines.join("\r\n");
    out.push_str("\r\n");
    out
}

pub fn parse(text: &str) -> Result<SessionDescription, String> {
    let mut desc = SessionDescription {
        ufrag: String::new(),
        pwd: String::new(),
        fingerprint: String::new(),
        setup: String::new(),
        candidates: Vec::new(),
        sctp_port: 5000,
    };
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if let Some(v) = line.strip_prefix("a=ice-ufrag:") {
            desc.ufrag = v.to_string();
        } else if let Some(v) = line.strip_prefix("a=ice-pwd:") {
            desc.pwd = v.to_string();
        } else if let Some(v) = line.strip_prefix("a=fingerprint:") {
            desc.fingerprint = v
                .strip_prefix("sha-256 ")
                .or_else(|| v.strip_prefix("sha-256\t"))
                .unwrap_or(v)
                .to_string();
        } else if let Some(v) = line.strip_prefix("a=setup:") {
            desc.setup = v.to_string();
        } else if let Some(v) = line.strip_prefix("a=candidate:") {
            if let Some(cand) = Candidate::from_sdp(&format!("candidate:{v}")) {
                desc.candidates.push(cand);
            } else if let Some(cand) = Candidate::from_sdp(v) {
                desc.candidates.push(cand);
            }
        } else if let Some(v) = line.strip_prefix("a=sctp-port:") {
            desc.sctp_port = v.parse().map_err(|_| "bad sctp-port")?;
        }
    }
    if desc.ufrag.is_empty() || desc.pwd.is_empty() || desc.fingerprint.is_empty() {
        return Err("incomplete SDP: missing ice credentials or fingerprint".into());
    }
    Ok(desc)
}
