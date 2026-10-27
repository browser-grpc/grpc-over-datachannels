//! Live STUN smoke test (opt-in): every other STUN test runs
//! against an in-process fake on loopback, so nothing exercised
//! a real public STUN server, real NAT mapping, or real UDP
//! egress. This test gathers a server-reflexive candidate from
//! Google's public STUN server. It is OUT of the default gate
//! (CI stays hermetic): run via `make test-live-stun` or with
//! GRPC_DC_LIVE_STUN=1 in the environment.

use dc_webrtc::peer::{Peer, PeerConfig};
use std::net::IpAddr;
use std::time::Duration;

#[test]
fn gather_srflx_from_google_stun_live() {
    if std::env::var_os("GRPC_DC_LIVE_STUN").is_none() {
        eprintln!("GRPC_DC_LIVE_STUN not set; live STUN smoke test skipped");
        return;
    }
    let mut peer = Peer::new(PeerConfig {
        local_ips: Vec::new(),
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: Vec::new(),
    })
    .unwrap();
    let gathered = peer
        .gather_srflx("stun.l.google.com:19302", Duration::from_secs(5))
        .expect("gather_srflx against Google STUN");
    assert!(gathered, "STUN server answered but produced no srflx");
    let offer = peer.create_offer();
    let line = offer
        .lines()
        .find(|l| l.contains("typ srflx"))
        .unwrap_or_else(|| panic!("no srflx candidate in offer:\n{offer}"));
    let address = line.split_whitespace().nth(4).unwrap_or("");
    assert!(
        !matches!(address.parse::<IpAddr>(), Ok(IpAddr::V4(ip)) if ip.is_loopback()),
        "srflx is loopback, want public egress mapping: {line}"
    );
    println!("live srflx: {line}");
}
