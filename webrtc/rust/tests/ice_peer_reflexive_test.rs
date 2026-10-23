//! Peer-reflexive mDNS learning (mirrors ice.js / ice.go): an SDP
//! candidate whose address is an unresolvable ".local" name is kept
//! as an unspecified-IP placeholder rather than dropped; the first
//! integrity-valid check from that port rewrites it to the real
//! source address, so a controlling agent with no resolved remote
//! candidates can still check and nominate the pair. (Browsers
//! advertise only mDNS candidates when host IPs are obfuscated.)
use dc_webrtc::ice::{Candidate, IceAgent};
use dc_webrtc::proto_gen::stun_attr;
use dc_webrtc::stun::Message;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

#[test]
fn unresolvable_mdns_candidate_is_learned_peer_reflexively() {
    // Parse like the peer does: the .local candidate is retained.
    let cand = Candidate::from_sdp(
        "candidate:1 1 udp 2122252543 18424c98-e33d-446f-98d5-d16fc2fba34b.local 43004 typ host",
    )
    .expect("mDNS candidate must be retained");
    assert!(cand.addr.ip().is_unspecified());
    assert_eq!(cand.addr.port(), 43004);
    assert!(cand.mdns_name.is_some());

    let mut agent = IceAgent::new(true);
    agent.local_candidates = vec![Candidate::host(
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 5000),
        "1",
    )];
    agent.set_remote("ffufrag", "ffpassword", vec![cand]);

    // Nothing addressable yet: no checks can be emitted.
    assert!(agent.due_checks().is_empty());

    // A Firefox-style check arrives from the real address, same port.
    let mut req = Message::new(dc_webrtc::proto_gen::stun_msg::BINDING_REQUEST);
    req.attrs.push((
        stun_attr::USERNAME,
        format!("{}:ffufrag", agent.local_ufrag).into_bytes(),
    ));
    req.attrs
        .push((stun_attr::PRIORITY, 0x6e7f00ffu32.to_be_bytes().to_vec()));
    req.attrs
        .push((stun_attr::ICE_CONTROLLED, 42u64.to_be_bytes().to_vec()));
    let raw = req.encode(Some(agent.local_pwd.as_bytes()));
    let src = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 168, 68, 114)), 43004);
    let (responses, _events) = agent.handle_stun(&raw, src);
    assert_eq!(responses.len(), 1);
    assert_eq!(
        u16::from_be_bytes([responses[0].0[0], responses[0].0[1]]),
        0x0101,
        "check must be answered with Binding Success"
    );

    // The candidate was rewritten to the real address, and the
    // controlling agent now emits checks (incl. nomination) to it.
    let checks = agent.due_checks();
    assert!(!checks.is_empty(), "agent must check the learned pair");
    assert!(checks.iter().all(|(_, dest)| *dest == src));
}
