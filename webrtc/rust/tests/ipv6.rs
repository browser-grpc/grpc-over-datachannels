//! IPv6 ICE candidates: XOR address helpers are family-aware
//! (RFC 5389: the IPv6 mask is magic cookie + transaction ID),
//! candidates round-trip through SDP in canonical form, and
//! two peers connect over ::1 host candidates only.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::ice::Candidate;
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::stun::{decode_xor_mapped, xor_mapped_address, Message};
use dc_webrtc::proto_gen::stun_msg;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::time::{Duration, Instant};

#[test]
fn xor_address_ipv6_round_trip() {
    let req = Message::new(stun_msg::BINDING_REQUEST);
    let addr: SocketAddr = "[2001:db8::42]:51234".parse().unwrap();
    let value = xor_mapped_address(&addr, &req.transaction_id);
    assert_eq!(value.len(), 20);
    assert_eq!(value[1], 2);
    assert_eq!(decode_xor_mapped(&value, &req.transaction_id), Some(addr));

    // IPv4-mapped input encodes as IPv4 and decodes to dotted.
    let mapped: SocketAddr = "[::ffff:203.0.113.9]:7".parse().unwrap();
    let v4 = xor_mapped_address(&mapped, &req.transaction_id);
    assert_eq!(v4.len(), 8);
    assert_eq!(v4[1], 1);
    assert_eq!(
        decode_xor_mapped(&v4, &req.transaction_id).map(|a| a.to_string()),
        Some("203.0.113.9:7".to_string())
    );
}

#[test]
fn candidate_ipv6_sdp_round_trip() {
    let line = "candidate:1 1 udp 2130706431 2001:0db8:0000:0000:0000:0000:0000:0001 54321 typ host generation 0";
    let cand = Candidate::from_sdp(line).expect("parse");
    assert_eq!(cand.addr.ip(), IpAddr::V6("2001:db8::1".parse::<Ipv6Addr>().unwrap()));
    assert_eq!(cand.addr.port(), 54321);
    assert!(cand.to_sdp().contains("2001:db8::1 54321 typ host"), "{}", cand.to_sdp());
}

fn wait_message(ep: &dc_webrtc::endpoint::DcEndpoint, want: &[u8]) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(EndpointEvent::Message { data, .. }) =
            ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, want);
            return;
        }
    }
    panic!("message {:?} never arrived", String::from_utf8_lossy(want));
}

fn connect_pair(ips_a: Vec<IpAddr>, ips_b: Vec<IpAddr>, forward: &[u8], back: &[u8]) {
    fn peer_with(ips: Vec<IpAddr>) -> Peer {
        Peer::new(PeerConfig {
            local_ips: ips,
            require_peer_certificate: true,
            certificate: None,
            session_resumption: false,
            session_ticket_key: None,
            resume_session: None,
            stun_servers: Vec::new(),
            turn_servers: Vec::new(),
        })
        .unwrap()
    }
    let mut offerer = peer_with(ips_a);
    let mut answerer = peer_with(ips_b);
    let offer = offerer.create_offer();
    assert!(offer.contains("::1 "), "offer lacks ::1 candidate:\n{offer}");
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();
    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let ch = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    ch.send_binary(forward).unwrap();
    wait_message(&answerer_ep, forward);

    let back_ch = answerer_ep
        .open_channel(ChannelParams { label: "back".into(), ..Default::default() })
        .unwrap();
    back_ch.send_binary(back).unwrap();
    wait_message(&offerer_ep, back);
}

#[test]
fn peers_connect_over_ipv6_loopback() {
    connect_pair(
        vec![IpAddr::V6(Ipv6Addr::LOCALHOST)],
        vec![IpAddr::V6(Ipv6Addr::LOCALHOST)],
        b"over-v6",
        b"back-over-v6",
    );
}

/// A dual-stack peer (IPv6 socket) still pairs with an IPv4-only
/// peer; IPv4 packets arrive mapped and are normalized.
#[test]
fn dual_stack_peer_connects_to_ipv4_peer() {
    use std::net::Ipv4Addr;
    connect_pair(
        vec![IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST)],
        vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        b"dual-stack",
        b"back-dual-stack",
    );
}
