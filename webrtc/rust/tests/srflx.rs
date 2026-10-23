//! Server-reflexive (srflx) ICE candidates: a fake STUN server on
//! loopback answers Binding requests; peers must learn srflx
//! candidates from XOR-MAPPED-ADDRESS, advertise them in SDP with
//! the RFC 8445 srflx priority, and connect using them (the host
//! address advertised in the e2e is deliberately unreachable, so a
//! working connection proves the srflx pair carried it).

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::proto_gen::{stun_attr, stun_msg};
use dc_webrtc::stun::Message;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::time::Duration;

/// Fake STUN server: fixed mapped address when given, else echoes
/// the requester's source address (real srflx-on-loopback semantics).
fn fake_stun_server(fixed: Option<SocketAddr>) -> String {
    let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let addr = socket.local_addr().unwrap();
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 2048];
        while let Ok((n, src)) = socket.recv_from(&mut buf) {
            if let Some(request) = Message::decode(&buf[..n]) {
                if request.msg_type != stun_msg::BINDING_REQUEST {
                    continue;
                }
                let mapped = fixed.unwrap_or(src);
                let mut resp = Message::new(stun_msg::BINDING_SUCCESS);
                resp.transaction_id = request.transaction_id;
                resp.attrs.push((
                    stun_attr::XOR_MAPPED_ADDRESS,
                    dc_webrtc::stun::xor_mapped_address(&mapped, &request.transaction_id),
                ));
                let _ = socket.send_to(&resp.encode(None), src);
            }
        }
    });
    addr.to_string()
}

fn srflx_peer(stun: &str) -> Peer {
    Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::new(10, 11, 12, 13))],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: vec![stun.to_string()],
        turn_servers: Vec::new(),
    })
    .unwrap()
}

#[test]
fn gather_srflx_candidate() {
    let fixed: SocketAddr = "203.0.113.9:54321".parse().unwrap();
    let server = fake_stun_server(Some(fixed));
    let mut peer = Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: Vec::new(),
    })
    .unwrap();
    assert!(peer.gather_srflx(&server, Duration::from_secs(2)).unwrap());
    let offer = peer.create_offer();
    let line = offer
        .lines()
        .find(|l| l.contains("typ srflx"))
        .unwrap_or_else(|| panic!("no srflx candidate in offer:\n{offer}"));
    assert!(
        line.contains("203.0.113.9 54321 typ srflx raddr 127.0.0.1 rport "),
        "srflx line: {line}"
    );
    let priority: u32 = line.split_whitespace().nth(3).unwrap().parse().unwrap();
    assert_eq!(priority >> 24, 100, "srflx priority type bits");
}

#[test]
fn peers_connect_over_srflx() {
    let server = fake_stun_server(None);
    let mut offerer = srflx_peer(&server);
    let mut answerer = srflx_peer(&server);

    let offer = offerer.create_offer();
    assert!(offer.contains("typ srflx"), "offer:\n{offer}");
    let answer = answerer.handle_offer(&offer).unwrap();
    assert!(answer.contains("typ srflx"), "answer:\n{answer}");
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"via-srflx").unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while std::time::Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"via-srflx");
            received = true;
        }
    }
    assert!(received, "no message arrived over the srflx-connected peers");
}
