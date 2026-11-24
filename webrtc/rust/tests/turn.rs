//! TURN relay (RFC 5766) ICE candidates: a fake TURN server on
//! loopback runs the Allocate 401 dance; peers must learn relay
//! candidates, advertise them with type preference 0, and connect
//! through the relay (the host address advertised in the e2e is
//! deliberately unreachable, so a working connection proves the
//! relayed pair carried ICE + DTLS + data).

use dc_webrtc::crypto::md5;
use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::proto_gen::{stun_attr, stun_msg};
use dc_webrtc::stun::Message;
use dc_webrtc::turn::TurnServerConfig;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

mod turn_fixture;
use turn_fixture::*;

// ---------------------------------------------------------------------------
// Fake TURN server (fixture): Allocate with long-term credential
// auth, CreatePermission, Send/Data-indication relaying between
// allocations, plus direct delivery to relayed ports.
// ---------------------------------------------------------------------------

fn turn_peer6(server: &str) -> Peer {
    let mut cfg = TurnServerConfig::new(server, USER, PASS);
    cfg.request_ipv6_relay = true;
    Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: vec![cfg],
    })
    .unwrap()
}

fn turn_peer(server: &str) -> Peer {
    Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::new(10, 11, 12, 13))],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: vec![TurnServerConfig::new(server, USER, PASS)],
    })
    .unwrap()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn allocate_gathers_relay_candidate() {
    let server = fake_turn_server();
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
    let cfg = TurnServerConfig::new(&server, USER, PASS);
    assert!(peer.allocate_turn(&cfg, Duration::from_secs(2)).unwrap());
    let offer = peer.create_offer();
    let line = offer
        .lines()
        .find(|l| l.contains("typ relay"))
        .unwrap_or_else(|| panic!("no relay candidate in offer:\n{offer}"));
    assert!(
        line.contains("typ relay raddr 127.0.0.1 rport "),
        "relay line: {line}"
    );
    let priority: u32 = line.split_whitespace().nth(3).unwrap().parse().unwrap();
    assert_eq!(priority >> 24, 0, "relay priority type bits");
}

#[test]
fn allocate_gathers_ipv6_relay_candidate() {
    let server = fake_turn_server6();
    let mut peer = turn_peer6(&server);
    let offer = peer.create_offer();
    let line = offer
        .lines()
        .find(|l| l.contains("typ relay"))
        .unwrap_or_else(|| panic!("no relay candidate in offer:\n{offer}"));
    assert!(
        line.contains("::1") || line.contains("raddr ::1"),
        "IPv6 relay line: {line}"
    );
}

#[test]
fn peers_connect_over_turn_relay_ipv6() {
    let server = fake_turn_server6();
    let mut offerer = turn_peer6(&server);
    let mut answerer = turn_peer6(&server);

    let offer = offerer.create_offer();
    assert!(offer.contains("typ relay"), "offer:\n{offer}");
    let answer = answerer.handle_offer(&offer).unwrap();
    assert!(answer.contains("typ relay"), "answer:\n{answer}");
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"via-relay-v6").unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while std::time::Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"via-relay-v6");
            received = true;
        }
    }
    assert!(received, "no message arrived over the IPv6 TURN-relayed peers");
}

#[test]
fn allocate_bad_password_adds_no_candidate() {
    let server = fake_turn_server();
    let mut peer = Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: vec![TurnServerConfig::new(&server, USER, "wrong")],
    })
    .unwrap();
    let offer = peer.create_offer();
    assert!(!offer.contains("typ relay"), "unexpected relay candidate:\n{offer}");
}

#[test]
fn peers_connect_over_turn_relay() {
    let server = fake_turn_server();
    let mut offerer = turn_peer(&server);
    let mut answerer = turn_peer(&server);

    let offer = offerer.create_offer();
    assert!(offer.contains("typ relay"), "offer:\n{offer}");
    let answer = answerer.handle_offer(&offer).unwrap();
    assert!(answer.contains("typ relay"), "answer:\n{answer}");
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"via-relay").unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while std::time::Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"via-relay");
            received = true;
        }
    }
    assert!(received, "no message arrived over the TURN-relayed peers");
}

// With a 3 s allocation/permission lifetime enforced by the fake,
// the relayed channel must still work after 5 s — only possible
// if both peers refresh their allocations and permissions.
#[test]
fn refresh_keeps_relay_alive() {
    let (server, state) = fake_turn_server_with(3, 3);
    let mut offerer = turn_peer(&server);
    let mut answerer = turn_peer(&server);

    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"before-expiry").unwrap();

    fn await_message(ep: &dc_webrtc::endpoint::DcEndpoint, want: &[u8]) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if let Some(EndpointEvent::Message { data, .. }) =
                ep.recv_event_timeout(Duration::from_millis(200))
            {
                assert_eq!(data, want);
                return;
            }
        }
        panic!("message {want:?} never arrived over the relay");
    }
    await_message(&answerer_ep, b"before-expiry");

    // Both allocations and all permissions would have expired by
    // now without refresh.
    std::thread::sleep(Duration::from_secs(5));
    channel.send_binary(b"after-expiry").unwrap();
    await_message(&answerer_ep, b"after-expiry");

    let st = state.lock().unwrap();
    assert!(st.refresh_count >= 2, "refreshes={}", st.refresh_count);
    assert!(st.perm_count >= 4, "permissions={}", st.perm_count);
}

#[test]
fn channel_bind_carries_traffic() {
    let (server, state) = fake_turn_server_with(600, 300);
    let mut offerer = turn_peer(&server);
    let mut answerer = turn_peer(&server);

    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"via-channel").unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"via-channel");
            received = true;
        }
    }
    assert!(received, "no message arrived over the channel-bound relay");
    let st = state.lock().unwrap();
    assert!(st.bind_count >= 2, "binds={}", st.bind_count);
    assert!(st.chan_data > 0, "no ChannelData relayed");
}

// Candidates trickled in after the connect-time snapshot must
// still get TURN permissions and channel bindings. The only
// reachable candidate on each side is the relay candidate,
// withheld from the SDP and trickled over the connect_trickled
// channel while ICE runs; the fake enforces permissions, so
// the message only flows if trickle created them.
#[test]
fn relay_with_trickled_relay_candidates() {
    let (server, state) = fake_turn_server_with(600, 300);
    let mut offerer = turn_peer(&server);
    let mut answerer = turn_peer(&server);

    fn relay_line_of(sdp: &str) -> String {
        sdp.lines()
            .find(|line| line.contains("typ relay"))
            .expect("no relay candidate")
            .to_string()
    }
    fn strip_relay(sdp: &str) -> String {
        sdp.lines()
            .filter(|line| !line.contains("typ relay"))
            .collect::<Vec<_>>()
            .join("\r\n")
            + "\r\n"
    }

    let offer = offerer.create_offer();
    let offer_relay = relay_line_of(&offer);
    let answer = answerer.handle_offer(&strip_relay(&offer)).unwrap();
    let answer_relay = relay_line_of(&answer);
    offerer.handle_answer(&strip_relay(&answer)).unwrap();

    let (offerer_tx, offerer_rx) = std::sync::mpsc::channel::<String>();
    let (answerer_tx, answerer_rx) = std::sync::mpsc::channel::<String>();
    let offerer_thread = std::thread::spawn(move || offerer.connect_trickled(offerer_rx));
    let answerer_thread = std::thread::spawn(move || answerer.connect_trickled(answerer_rx));

    // Trickle only after both connects have snapshotted the
    // SDP-carried candidates.
    std::thread::sleep(Duration::from_millis(250));
    answerer_tx.send(offer_relay).unwrap();
    offerer_tx.send(answer_relay).unwrap();
    drop(offerer_tx);
    drop(answerer_tx);

    let offerer_ep = offerer_thread.join().unwrap().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"trickled-relay").unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"trickled-relay");
            received = true;
        }
    }
    assert!(received, "no message arrived over the trickled relay");
    let st = state.lock().unwrap();
    assert!(st.perm_count >= 2, "permissions={}", st.perm_count);
    assert!(st.bind_count >= 2, "binds={}", st.bind_count);
}

// ---------------------------------------------------------------------------
// TURN on muxed peers: two PeerMuxes whose peers also allocate.
// The advertised host addresses are deliberately unreachable,
// so a working echo proves the relayed pairs carried the
// traffic while the mux demuxed by connection id. The
// allocation's UDP leg rides a dedicated per-peer socket;
// TURN traffic never touches the shared socket.
// ---------------------------------------------------------------------------

fn mux_turn_config(server: &str) -> PeerConfig {
    PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::new(10, 11, 12, 13))],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: vec![TurnServerConfig::new(server, USER, PASS)],
    }
}

/// Drive one endpoint: answerers echo ("re:" prefix on the
/// opened channel), offerers return the first message seen.
fn mux_turn_echo(endpoint: &dc_webrtc::endpoint::DcEndpoint, echo: bool) -> String {
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut channel = None;
    while Instant::now() < deadline {
        match endpoint.recv_event_timeout(Duration::from_millis(250)) {
            Some(EndpointEvent::ChannelOpened { channel: ch }) => {
                channel = Some(ch);
            }
            Some(EndpointEvent::Message { data, .. }) => {
                let text = String::from_utf8_lossy(&data).into_owned();
                if echo {
                    if let Some(ch) = &channel {
                        ch.send_text(&format!("re:{text}")).unwrap();
                    }
                }
                return text;
            }
            Some(_) | None => {}
        }
    }
    panic!("timed out waiting for channel/message");
}

#[test]
fn turn_mux_to_mux_two_pairs() {
    use dc_webrtc::mux::PeerMux;
    use std::sync::mpsc::channel;
    let server = fake_turn_server();
    let mux_a = PeerMux::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)).unwrap();
    let mux_b = PeerMux::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)).unwrap();

    let (result_tx, result_rx) = channel::<(usize, String)>();
    let mut joins = Vec::new();
    for pair in 0..2usize {
        let mut offerer = mux_a.new_peer(mux_turn_config(&server)).unwrap();
        let mut answerer = mux_b.new_peer(mux_turn_config(&server)).unwrap();
        let offer = offerer.create_offer();
        assert!(offer.contains("typ relay"), "muxed offerer offer:\n{offer}");
        let answer = answerer.handle_offer(&offer).unwrap();
        offerer.handle_answer(&answer).unwrap();

        let tx = result_tx.clone();
        joins.push(std::thread::spawn(move || {
            let endpoint = answerer.connect().expect("answerer connect");
            let got = mux_turn_echo(&endpoint, true);
            tx.send((pair, format!("answerer saw: {got}"))).unwrap();
            endpoint.shutdown();
        }));
        let tx = result_tx.clone();
        joins.push(std::thread::spawn(move || {
            let endpoint = offerer.connect().expect("offerer connect");
            let channel = endpoint
                .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
                .unwrap();
            channel.send_text(&format!("hello-from-pair-{pair}")).unwrap();
            let reply = mux_turn_echo(&endpoint, false);
            tx.send((pair, format!("offerer reply: {reply}"))).unwrap();
            endpoint.shutdown();
        }));
    }

    let mut results: Vec<(usize, String)> = Vec::new();
    for _ in 0..4 {
        results.push(result_rx.recv_timeout(Duration::from_secs(30)).expect("pair result"));
    }
    for j in joins {
        j.join().unwrap();
    }
    for pair in 0..2usize {
        let want_heard = format!("answerer saw: hello-from-pair-{pair}");
        let want_reply = format!("offerer reply: re:hello-from-pair-{pair}");
        assert!(
            results.iter().any(|(p, s)| *p == pair && *s == want_heard),
            "pair {pair}: answerer must hear its own payload; got {results:?}"
        );
        assert!(
            results.iter().any(|(p, s)| *p == pair && *s == want_reply),
            "pair {pair}: offerer must get its own reply; got {results:?}"
        );
    }
}
