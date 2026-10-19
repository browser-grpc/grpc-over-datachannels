//! ICE restart (RFC 8445 section 5.1): fresh credentials and
//! a new nomination underneath the live DTLS/SCTP association,
//! driven through RestartHandle (Peer is consumed by connect).
//! Media keeps flowing on the same channel, either side may
//! initiate, and consent stays healthy on the new pair.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::{ChannelHandle, DcEndpoint, EndpointEvent};
use dc_webrtc::peer::{Peer, PeerConfig, RestartHandle};
use dc_webrtc::sdp::parse;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

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

fn echo_roundtrip(
    offerer_ep: &DcEndpoint,
    answerer_ep: &DcEndpoint,
    channel: &ChannelHandle,
    answerer_channel: &mut Option<ChannelHandle>,
    msg: &[u8],
) {
    channel.send_binary(msg).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    // Answerer: accept the channel once, echo every message.
    let mut echoed = false;
    while Instant::now() < deadline && !echoed {
        if let Some(event) = answerer_ep.recv_event_timeout(Duration::from_millis(100)) {
            match event {
                EndpointEvent::ChannelOpened { channel, .. } => {
                    *answerer_channel = Some(channel);
                }
                EndpointEvent::Message { data, .. } => {
                    assert_eq!(data, msg);
                    let mut reply = b"echo:".to_vec();
                    reply.extend_from_slice(&data);
                    answerer_channel.as_ref().unwrap().send_binary(&reply).unwrap();
                    echoed = true;
                }
                _ => {}
            }
        }
    }
    assert!(echoed, "answerer never saw {:?}", String::from_utf8_lossy(msg));

    let expected = {
        let mut v = b"echo:".to_vec();
        v.extend_from_slice(msg);
        v
    };
    let mut got = false;
    while Instant::now() < deadline && !got {
        if let Some(EndpointEvent::Message { data, .. }) =
            offerer_ep.recv_event_timeout(Duration::from_millis(100))
        {
            assert_eq!(data, expected);
            got = true;
        }
    }
    assert!(got, "offerer never saw the echo");
}

fn do_restart(
    initiator: &RestartHandle,
    responder: &RestartHandle,
    prev_initiator_ufrag: &str,
    prev_responder_ufrag: &str,
) -> (String, String) {
    let offer = initiator.create_restart_offer();
    let offer_ufrag = parse(&offer).unwrap().ufrag;
    assert_ne!(offer_ufrag, prev_initiator_ufrag, "initiator ufrag must rotate");
    let answer = responder.handle_restart_offer(&offer).unwrap();
    let answer_ufrag = parse(&answer).unwrap().ufrag;
    assert_ne!(answer_ufrag, prev_responder_ufrag, "responder ufrag must rotate");
    initiator.handle_restart_answer(&answer).unwrap();
    assert!(initiator.wait_renominated(Duration::from_secs(10)), "initiator never renominated");
    assert!(responder.wait_renominated(Duration::from_secs(10)), "responder never renominated");
    (offer_ufrag, answer_ufrag)
}

#[test]
fn ice_restart_renominates_on_live_peer() {
    let (fail_tx, fail_rx) = channel::<()>();
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();
    let fail_tx2 = fail_tx.clone();
    offerer.set_consent(
        Some(Duration::from_millis(100)),
        Duration::from_millis(800),
        move || {
            let _ = fail_tx.send(());
        },
    );
    answerer.set_consent(
        Some(Duration::from_millis(100)),
        Duration::from_millis(800),
        move || {
            let _ = fail_tx2.send(());
        },
    );
    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();
    let answerer_thread = std::thread::spawn(move || answerer.connect_with_handle());
    let (offerer_ep, offerer_handle) = offerer.connect_with_handle().expect("offerer connect");
    let (answerer_ep, answerer_handle) =
        answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    let mut answerer_channel = None;
    echo_roundtrip(&offerer_ep, &answerer_ep, &channel, &mut answerer_channel, b"before-restart");

    let mut ufrags = (parse(&offer).unwrap().ufrag, parse(&answer).unwrap().ufrag);
    ufrags = do_restart(&offerer_handle, &answerer_handle, &ufrags.0, &ufrags.1);
    echo_roundtrip(&offerer_ep, &answerer_ep, &channel, &mut answerer_channel, b"after-restart-1");
    assert_eq!(offerer_handle.generation(), 1);
    assert_eq!(answerer_handle.generation(), 1);

    // The other side may initiate the next restart.
    do_restart(&answerer_handle, &offerer_handle, &ufrags.1, &ufrags.0);
    echo_roundtrip(&offerer_ep, &answerer_ep, &channel, &mut answerer_channel, b"after-restart-2");
    assert_eq!(offerer_handle.generation(), 2);

    // Consent keeps passing on the new pairs, well past expiry.
    assert!(
        fail_rx.recv_timeout(Duration::from_millis(1800)).is_err(),
        "consent failure fired after restart"
    );
}
