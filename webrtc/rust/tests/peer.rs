//! Full stack: ICE + DTLS + SCTP + DCEP between two Rust peers with
//! SDP exchanged in-process, host candidates on loopback only.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use std::net::{IpAddr, Ipv4Addr};
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

#[test]
fn full_peer_datachannel_echo() {
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();

    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"over the full stack").unwrap();

    // Answerer receives the channel and the message, echoes back.
    let mut echoed = false;
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut answerer_channel = None;
    while std::time::Instant::now() < deadline && !echoed {
        match answerer_ep.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::ChannelOpened { channel }) => {
                answerer_channel = Some(channel);
            }
            Some(EndpointEvent::Message { data, .. }) => {
                assert_eq!(data, b"over the full stack");
                let ch = answerer_channel.as_ref().unwrap();
                let mut reply = b"re:".to_vec();
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
                assert_eq!(data, b"re:over the full stack");
                got_reply = true;
            }
            _ => {}
        }
    }
    assert!(got_reply, "offerer never got the echo");
}
