//! Peer-level DTLS resumption: persistent certificates, ticket
//! capture from the endpoint, and an abbreviated reconnect whose
//! identity comes from the sealed ticket — proven by pinning the
//! round-1 fingerprint in round 2's offer while the (DTLS-server)
//! offerer presents a different certificate. A full handshake
//! would fail that check; resumption passes it.
//!
//! Role note: in this stack the SDP offerer is the DTLS server
//! (it issues tickets); the answerer is the DTLS client (it
//! captures and resumes sessions).

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::{DcEndpoint, EndpointEvent};
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::x509::Certificate;
use std::net::{IpAddr, Ipv4Addr};
use std::time::{Duration, Instant};

const TICKET_KEY: [u8; 32] = [3u8; 32];

fn config(cert: Certificate, dtls_server: bool) -> PeerConfig {
    PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: Some(cert),
        session_resumption: true,
        session_ticket_key: if dtls_server { Some(TICKET_KEY) } else { None },
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: Vec::new(),
    }
}

fn with_fingerprint(sdp: &str, fingerprint: &str) -> String {
    let mut lines: Vec<String> = sdp.lines().map(|l| l.to_string()).collect();
    for line in &mut lines {
        if line.starts_with("a=fingerprint:") {
            *line = format!("a=fingerprint:{}", fingerprint);
        }
    }
    lines.join("\r\n") + "\r\n"
}

fn echo_once(client_ep: &DcEndpoint, server_ep: &DcEndpoint, msg: &[u8]) {
    let channel = client_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(msg).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut server_channel = None;
    let mut echoed = false;
    while Instant::now() < deadline && !echoed {
        if let Some(event) = server_ep.recv_event_timeout(Duration::from_millis(100)) {
            match event {
                EndpointEvent::ChannelOpened { channel } => server_channel = Some(channel),
                EndpointEvent::Message { data, .. } => {
                    assert_eq!(data, msg);
                    let mut reply = b"echo:".to_vec();
                    reply.extend_from_slice(&data);
                    server_channel.as_ref().unwrap().send_binary(&reply).unwrap();
                    echoed = true;
                }
                _ => {}
            }
        }
    }
    assert!(echoed, "server never saw the message");
    let mut expected = b"echo:".to_vec();
    expected.extend_from_slice(msg);
    let mut got = false;
    while Instant::now() < deadline && !got {
        if let Some(EndpointEvent::Message { data, .. }) =
            client_ep.recv_event_timeout(Duration::from_millis(100))
        {
            assert_eq!(data, expected);
            got = true;
        }
    }
    assert!(got, "client never saw the echo");
}

/// Connect offerer (DTLS server) + answerer (DTLS client).
/// `offer_fingerprint_override` rewrites the fingerprint the
/// answerer will pin for the offerer.
fn connect(
    mut offerer: Peer,
    mut answerer: Peer,
    offer_fingerprint_override: Option<String>,
) -> (DcEndpoint, DcEndpoint) {
    let mut offer = offerer.create_offer();
    if let Some(fp) = &offer_fingerprint_override {
        offer = with_fingerprint(&offer, fp);
    }
    let answer = answerer.handle_offer(&offer).expect("handle offer");
    offerer.handle_answer(&answer).expect("handle answer");
    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");
    (offerer_ep, answerer_ep)
}

#[test]
fn peer_reconnect_resumes_dtls_session() {
    let offerer_cert_v1 = Certificate::generate_self_signed("offerer-v1");
    let offerer_fp_v1 = offerer_cert_v1.fingerprint();
    let answerer_cert = Certificate::generate_self_signed("answerer");

    // Round 1: full handshake; the DTLS server (offerer) issues
    // a ticket, the client (answerer) captures it.
    let (offerer_ep, answerer_ep) = connect(
        Peer::new(config(offerer_cert_v1, true)).unwrap(),
        Peer::new(config(answerer_cert.clone(), false)).unwrap(),
        None,
    );
    echo_once(&answerer_ep, &offerer_ep, b"round-1");
    let session = answerer_ep
        .take_dtls_session()
        .expect("endpoint captured a DTLS session ticket");
    offerer_ep.shutdown();
    answerer_ep.shutdown();

    // Round 2: the offerer presents a DIFFERENT certificate, but
    // its offer pins round 1's fingerprint. Only a resumed
    // handshake (identity from the sealed ticket) can pass; a
    // full handshake would fail the fingerprint check.
    let offerer_cert_v2 = Certificate::generate_self_signed("offerer-v2");
    assert_ne!(offerer_cert_v2.fingerprint(), offerer_fp_v1);
    let mut answerer_cfg = config(answerer_cert.clone(), false);
    answerer_cfg.resume_session = Some(session);
    let (offerer_ep2, answerer_ep2) = connect(
        Peer::new(config(offerer_cert_v2, true)).unwrap(),
        Peer::new(answerer_cfg).unwrap(),
        Some(offerer_fp_v1.clone()),
    );
    echo_once(&answerer_ep2, &offerer_ep2, b"round-2-resumed");
    // The resumed connection rotates a fresh ticket too.
    assert!(answerer_ep2.take_dtls_session().is_some());
    offerer_ep2.shutdown();
    answerer_ep2.shutdown();

    // Sanity: the fingerprint pin is real — without a session to
    // resume, the same mismatched pin must fail the DTLS client's
    // connect (the answerer side errors).
    let mut offerer = Peer::new(config(
        Certificate::generate_self_signed("offerer-v3"),
        true,
    ))
    .unwrap();
    let mut answerer = Peer::new(config(answerer_cert, false)).unwrap();
    let offer = with_fingerprint(&offerer.create_offer(), &offerer_fp_v1);
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();
    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let _offerer_attempt = std::thread::spawn(move || offerer.connect());
    let answerer_result = answerer_thread.join().unwrap();
    assert!(
        answerer_result.is_err(),
        "full handshake with a mismatched fingerprint pin must fail"
    );
}
