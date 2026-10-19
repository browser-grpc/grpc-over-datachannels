//! Trickle ICE (RFC 8445 section 4.1.1): candidates are removed
//! from the SDP and delivered incrementally through
//! add_remote_candidate / set_on_local_candidate, or through the
//! connect_trickled channel while ICE runs. The peers here can
//! only connect because the trickled candidates arrive.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::mpsc::channel;
use std::time::Duration;

fn loopback_peer() -> Peer {
    Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
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

fn strip_candidate_lines(sdp: &str) -> String {
    sdp.lines()
        .filter(|line| !line.starts_with("a=candidate:"))
        .collect::<Vec<_>>()
        .join("\r\n")
        + "\r\n"
}

fn candidate_lines_of(sdp: &str) -> Vec<String> {
    sdp.lines()
        .filter(|line| line.starts_with("a=candidate:"))
        .map(|line| line.to_string())
        .collect()
}

#[test]
fn add_remote_candidate_parsing() {
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();
    let offer = offerer.create_offer();
    let lines = candidate_lines_of(&offer);
    assert!(!lines.is_empty(), "offer has no candidates to trickle");
    answerer.handle_offer(&strip_candidate_lines(&offer)).unwrap();
    // End-of-candidates, empty, and malformed lines are no-ops.
    assert!(!answerer.add_remote_candidate(""));
    assert!(!answerer.add_remote_candidate("a=end-of-candidates"));
    assert!(!answerer.add_remote_candidate("not a candidate"));
    for line in &lines {
        assert!(answerer.add_remote_candidate(line), "not added: {line}");
    }
    // Duplicates (either spelling) are no-ops.
    assert!(!answerer.add_remote_candidate(&lines[0]));
    assert!(!answerer.add_remote_candidate(lines[0].strip_prefix("a=").unwrap()));
}

#[test]
fn local_candidate_callback_replay_and_gather() {
    use dc_webrtc::proto_gen::{stun_attr, stun_msg};
    use dc_webrtc::stun::Message;
    // Fake STUN server with a fixed mapped address (mirrors srflx.rs).
    let fixed: SocketAddr = "203.0.113.9:54321".parse().unwrap();
    let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let server = socket.local_addr().unwrap().to_string();
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 2048];
        while let Ok((n, src)) = socket.recv_from(&mut buf) {
            if let Some(request) = Message::decode(&buf[..n]) {
                if request.msg_type != stun_msg::BINDING_REQUEST {
                    continue;
                }
                let mut resp = Message::new(stun_msg::BINDING_SUCCESS);
                resp.transaction_id = request.transaction_id;
                resp.attrs.push((
                    stun_attr::XOR_MAPPED_ADDRESS,
                    dc_webrtc::stun::xor_mapped_address(&fixed, &request.transaction_id),
                ));
                let _ = socket.send_to(&resp.encode(None), src);
            }
        }
    });

    let mut peer = loopback_peer();
    let (tx, rx) = channel::<String>();
    peer.set_on_local_candidate(move |line| {
        let _ = tx.send(line.to_string());
    });
    // Registration replays the host candidate.
    let first = rx.try_recv().unwrap();
    assert!(first.contains("typ host"), "replay: {first}");
    // A later srflx gathering fires as the candidate is added.
    assert!(peer.gather_srflx(&server, Duration::from_secs(2)).unwrap());
    let second = rx.try_recv().unwrap();
    assert!(second.contains("typ srflx"), "gathered: {second}");
    assert_eq!(peer.local_candidate_lines().len(), 2);
}

fn echo_roundtrip(
    offerer_ep: &dc_webrtc::endpoint::DcEndpoint,
    answerer_ep: &dc_webrtc::endpoint::DcEndpoint,
) {
    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"via-trickle").unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut answerer_channel = None;
    let mut echoed = false;
    while std::time::Instant::now() < deadline && !echoed {
        match answerer_ep.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::ChannelOpened { channel }) => {
                answerer_channel = Some(channel);
            }
            Some(EndpointEvent::Message { data, .. }) => {
                assert_eq!(data, b"via-trickle");
                let ch = answerer_channel.as_ref().unwrap();
                let mut reply = b"echo:".to_vec();
                reply.extend_from_slice(&data);
                ch.send_binary(&reply).unwrap();
                echoed = true;
            }
            _ => {}
        }
    }
    assert!(echoed, "answerer never got the message");

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut got_reply = false;
    while std::time::Instant::now() < deadline && !got_reply {
        match offerer_ep.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::Message { data, .. }) => {
                assert_eq!(data, b"echo:via-trickle");
                got_reply = true;
            }
            _ => {}
        }
    }
    assert!(got_reply, "offerer never got the echo");
}

#[test]
fn peers_connect_over_trickled_candidates_only() {
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();

    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&strip_candidate_lines(&offer)).unwrap();
    offerer.handle_answer(&strip_candidate_lines(&answer)).unwrap();

    for line in candidate_lines_of(&offer) {
        assert!(answerer.add_remote_candidate(&line));
    }
    answerer.add_remote_candidate("a=end-of-candidates");
    for line in candidate_lines_of(&answer) {
        assert!(offerer.add_remote_candidate(&line));
    }
    offerer.add_remote_candidate("a=end-of-candidates");

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");
    echo_roundtrip(&offerer_ep, &answerer_ep);
}

#[test]
fn candidates_trickled_during_connect_still_connect() {
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();

    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&strip_candidate_lines(&offer)).unwrap();
    offerer.handle_answer(&strip_candidate_lines(&answer)).unwrap();

    // Answerer's candidates are trickled before its connect; the
    // offerer's arrive over the channel while its ICE is running.
    for line in candidate_lines_of(&offer) {
        assert!(answerer.add_remote_candidate(&line));
    }
    let (tx, rx) = channel::<String>();
    let offerer_thread = std::thread::spawn(move || offerer.connect_trickled(rx));
    let answerer_thread = std::thread::spawn(move || answerer.connect());

    // Let the offerer's ICE start with zero candidates, then
    // trickle the answer's candidates in.
    std::thread::sleep(Duration::from_millis(200));
    for line in candidate_lines_of(&answer) {
        tx.send(line).unwrap();
    }
    tx.send("a=end-of-candidates".to_string()).unwrap();
    drop(tx);

    let offerer_ep = offerer_thread.join().unwrap().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");
    echo_roundtrip(&offerer_ep, &answerer_ep);
}
