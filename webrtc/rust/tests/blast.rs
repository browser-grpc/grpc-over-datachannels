//! Probe: many small messages in rapid succession over one channel.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
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
fn blast_20_messages() {
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();
    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = Arc::new(offerer.connect().expect("offerer connect"));
    let answerer_ep = Arc::new(answerer_thread.join().unwrap().expect("answerer connect"));

    let client_channel = offerer_ep
        .open_channel(ChannelParams { label: "blast".into(), ..Default::default() })
        .unwrap();

    // Echo server on the answerer: separate consumer thread per role.
    let server_ep = answerer_ep.clone();
    std::thread::spawn(move || {
        let mut server_channel = None;
        while let Some(event) = server_ep.recv_event() {
            match event {
                EndpointEvent::ChannelOpened { channel } => server_channel = Some(channel),
                EndpointEvent::Message { data, .. } => {
                    if let Some(ch) = &server_channel {
                        let mut reply = b"re:".to_vec();
                        reply.extend_from_slice(&data);
                        ch.send_binary(&reply).unwrap();
                    }
                }
                _ => {}
            }
        }
    });

    for i in 0..20 {
        client_channel.send_binary(format!("msg-{i}").as_bytes()).unwrap();
    }

    let mut replies = 0;
    while replies < 20 {
        match offerer_ep.recv_event_timeout(Duration::from_secs(10)) {
            Some(EndpointEvent::Message { data, .. }) => {
                assert_eq!(&data[..3], b"re:");
                replies += 1;
            }
            Some(_) => {}
            None => panic!("timed out after {replies} replies"),
        }
    }
}
