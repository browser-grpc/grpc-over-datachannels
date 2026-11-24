//! Rendezvous end to end: a native peer plays the browser
//! dialer — it synthesizes the listener's description locally
//! (handle_answer on the descriptor-rendered answer), runs ICE
//! as controlling agent, and opens a channel. The listener
//! must spawn a session peer from the first Binding request's
//! ufrag, answer DTLS as server with the fixed certificate,
//! and echo on the channel. Two sequential dialers prove
//! per-ufrag session demux on the one listener socket.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::{DcEndpoint, EndpointEvent};
use dc_webrtc::ice::Candidate;
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::rendezvous::{RendezvousListener, RendezvousOptions};
use dc_webrtc::sdp::{generate, SessionDescription};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::mpsc::channel;
use std::sync::Arc;
use std::time::Duration;

fn echo_endpoint(endpoint: DcEndpoint) {
    std::thread::spawn(move || {
        let mut channel = None;
        loop {
            match endpoint.recv_event_timeout(Duration::from_secs(30)) {
                Some(EndpointEvent::ChannelOpened { channel: opened }) => {
                    channel = Some(opened);
                }
                Some(EndpointEvent::Message { text, data, .. }) => {
                    let Some(channel) = &channel else { continue };
                    let mut reply = b"re:".to_vec();
                    reply.extend_from_slice(&data);
                    if text {
                        let _ = channel.send_text(std::str::from_utf8(&reply).unwrap());
                    } else {
                        let _ = channel.send_binary(&reply);
                    }
                }
                Some(_) => continue,
                None => return,
            }
        }
    });
}

#[test]
fn rendezvous_dial_and_echo() {
    let (endpoint_tx, endpoint_rx) = channel::<DcEndpoint>();
    let listener = RendezvousListener::bind(
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        RendezvousOptions {
            on_endpoint: Box::new(move |endpoint| {
                let _ = endpoint_tx.send(endpoint);
            }),
            on_error: Box::new(|e| eprintln!("rendezvous: {e}")),
            ..Default::default()
        },
    )
    .unwrap();
    let desc = listener.descriptor("127.0.0.1");
    assert!(!desc.ice_ufrag.is_empty() && !desc.ice_pwd.is_empty());
    assert!(!desc.fingerprint.is_empty() && desc.setup == "passive");
    assert!(desc.to_json().contains("\"iceUfrag\""));

    // Long-lived leg on a second listener: with a 6 s consent
    // expiry, the session must still answer after 9 s. The
    // dialer's password is never learned by the listener, so
    // its consent checks can never be answered — the session
    // survives only because the dialer's own Binding requests
    // refresh server-side consent (RFC 7675).
    {
        let (tx2, rx2) = channel::<DcEndpoint>();
        let short = RendezvousListener::bind(
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
            RendezvousOptions {
                consent_interval: Some(Duration::from_millis(500)),
                consent_expiry: Some(Duration::from_secs(6)),
                on_endpoint: Box::new(move |endpoint| {
                    let _ = tx2.send(endpoint);
                }),
                on_error: Box::new(|e| eprintln!("rendezvous: {e}")),
                ..Default::default()
            },
        )
        .unwrap();
        let sdesc = short.descriptor("127.0.0.1");
        let mut dialer = Peer::new(PeerConfig::default()).unwrap();
        dialer.set_consent(Some(Duration::from_secs(1)), Duration::from_secs(30), || {});
        let remote = SessionDescription {
            ufrag: sdesc.ice_ufrag.clone(),
            pwd: sdesc.ice_pwd.clone(),
            fingerprint: sdesc.fingerprint.clone(),
            setup: "passive".to_string(),
            candidates: vec![Candidate::host(
                SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), sdesc.port),
                "1",
            )],
            sctp_port: 5000,
        };
        dialer.handle_answer(&generate(&remote, false)).unwrap();
        let endpoint = dialer.connect().expect("dialer connect");
        let server_endpoint = rx2
            .recv_timeout(Duration::from_secs(15))
            .expect("listener endpoint");
        echo_endpoint(server_endpoint);
        let channel = endpoint
            .open_channel(ChannelParams { label: "grpc".into(), ..Default::default() })
            .unwrap();
        let roundtrip = |endpoint: &DcEndpoint, want: &str| {
            channel.send_binary(want.as_bytes()).unwrap();
            let deadline = std::time::Instant::now() + Duration::from_secs(15);
            while std::time::Instant::now() < deadline {
                match endpoint.recv_event_timeout(Duration::from_millis(500)) {
                    Some(EndpointEvent::Message { data, .. }) => {
                        assert_eq!(String::from_utf8(data).unwrap(), format!("re:{want}"));
                        return;
                    }
                    Some(_) => continue,
                    None => continue,
                }
            }
            panic!("no reply for {want}");
        };
        roundtrip(&endpoint, "before");
        std::thread::sleep(Duration::from_secs(9));
        roundtrip(&endpoint, "after");
        endpoint.shutdown();
        short.close();
    }

    for dial in 0..2 {
        let mut dialer = Peer::new(PeerConfig::default()).unwrap();
        let remote = SessionDescription {
            ufrag: desc.ice_ufrag.clone(),
            pwd: desc.ice_pwd.clone(),
            fingerprint: desc.fingerprint.clone(),
            setup: "passive".to_string(),
            candidates: vec![Candidate::host(
                SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), desc.port),
                "1",
            )],
            sctp_port: 5000,
        };
        dialer.handle_answer(&generate(&remote, false)).unwrap();
        let endpoint = dialer.connect().expect("dialer connect");
        let server_endpoint = endpoint_rx
            .recv_timeout(Duration::from_secs(15))
            .expect("listener endpoint");
        echo_endpoint(server_endpoint);

        let channel = endpoint
            .open_channel(ChannelParams { label: "grpc".into(), ..Default::default() })
            .unwrap();
        let want = format!("hello-rendezvous-{dial}");
        channel.send_binary(want.as_bytes()).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        let mut reply = None;
        while std::time::Instant::now() < deadline {
            match endpoint.recv_event_timeout(Duration::from_millis(500)) {
                Some(EndpointEvent::Message { data, .. }) => {
                    reply = Some(String::from_utf8(data).unwrap());
                    break;
                }
                Some(_) => continue,
                None => continue,
            }
        }
        assert_eq!(reply.as_deref(), Some(format!("re:{want}").as_str()));
        endpoint.shutdown();
    }
    listener.close();
}

fn dial_and_echo(listener: &RendezvousListener, tag: &str) {
    let desc = listener.descriptor("127.0.0.1");
    let mut dialer = Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        require_peer_certificate: true,
        ..Default::default()
    })
    .unwrap();
    let remote = SessionDescription {
        ufrag: desc.ice_ufrag.clone(),
        pwd: desc.ice_pwd.clone(),
        fingerprint: desc.fingerprint.clone(),
        setup: "passive".to_string(),
        candidates: vec![Candidate::host(
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), desc.port),
            "1",
        )],
        sctp_port: 5000,
    };
    dialer.handle_answer(&generate(&remote, false)).unwrap();
    let endpoint = dialer.connect().expect("dialer connect");
    let channel = endpoint
        .open_channel(ChannelParams { label: "grpc".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(tag.as_bytes()).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        match endpoint.recv_event_timeout(Duration::from_secs(1)) {
            Some(EndpointEvent::Message { data, .. }) => {
                assert_eq!(data, format!("re:{tag}").into_bytes());
                return;
            }
            Some(_) => {
                assert!(std::time::Instant::now() < deadline, "echo timeout for {tag}");
            }
            None => panic!("echo timeout for {tag}"),
        }
    }
}

#[test]
fn rendezvous_survives_garbage_then_serves() {
    // Malformed traffic at the listener socket (random bytes,
    // truncated STUN, a Binding request with a wrong password,
    // an oversized datagram) must not kill or wedge the
    // listener: a legitimate dialer still connects afterwards.
    let (endpoint_tx, endpoint_rx) = channel::<DcEndpoint>();
    let listener = RendezvousListener::bind(
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        RendezvousOptions {
            on_endpoint: Box::new(move |endpoint| {
                let _ = endpoint_tx.send(endpoint);
            }),
            on_error: Box::new(|_| {}),
            ..Default::default()
        },
    )
    .unwrap();
    let port = listener.descriptor("127.0.0.1").port;
    let attacker = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let target = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
    let mut junk: Vec<Vec<u8>> = vec![
        vec![0xFF; 1],
        vec![0x00, 0x01, 0x00, 0x00], // truncated STUN header
        b"not a stun packet at all, just text".to_vec(),
        vec![0xAB; 65507], // max-size garbage datagram
    ];
    // A syntactically plausible Binding request with a wrong
    // ICE password for the listener's ufrag.
    {
        let desc = listener.descriptor("127.0.0.1");
        let mut req = dc_webrtc::stun::Message::new(0x0001);
        req.attrs.push((0x0006, format!("{}:x", desc.ice_ufrag).into_bytes()));
        req.attrs.push((0x0025, Vec::new())); // USE-CANDIDATE
        junk.push(req.encode(Some(b"wrong-password-wrong")));
    }
    for packet in &junk {
        let _ = attacker.send_to(packet, target);
    }
    std::thread::sleep(Duration::from_millis(300));

    // Spawn the echo handler for whatever endpoint arrives.
    std::thread::spawn(move || {
        if let Ok(endpoint) = endpoint_rx.recv_timeout(Duration::from_secs(20)) {
            echo_endpoint(endpoint);
        }
    });
    dial_and_echo(&listener, "after-garbage");
}

#[test]
fn rendezvous_stun_servers_are_consulted() {
    // A session peer spawned for a listener configured with
    // stun_servers must actually send a STUN Binding request
    // to that server while gathering (issue #3: rendezvous
    // sessions used to offer host candidates only). The fake
    // STUN server answers with a documentation-range mapped
    // address; the echo round-trip then proves the session
    // still connects on its host candidate.
    let stun_socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let stun_addr = stun_socket.local_addr().unwrap();
    let (hit_tx, hit_rx) = channel::<()>();
    std::thread::spawn(move || {
        let mut buf = [0u8; 2048];
        stun_socket
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        if let Ok((n, src)) = stun_socket.recv_from(&mut buf) {
            if let Some(msg) = dc_webrtc::stun::Message::decode(&buf[..n]) {
                let mapped =
                    SocketAddr::new(IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9)), src.port());
                let resp = dc_webrtc::stun::binding_success(&msg, &mapped, b"");
                let _ = stun_socket.send_to(&resp, src);
                let _ = hit_tx.send(());
            }
        }
    });

    let (endpoint_tx, endpoint_rx) = channel::<DcEndpoint>();
    let listener = RendezvousListener::bind(
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        RendezvousOptions {
            stun_servers: vec![stun_addr.to_string()],
            on_endpoint: Box::new(move |endpoint| {
                let _ = endpoint_tx.send(endpoint);
            }),
            on_error: Box::new(|_| {}),
            ..Default::default()
        },
    )
    .unwrap();
    std::thread::spawn(move || {
        if let Ok(endpoint) = endpoint_rx.recv_timeout(Duration::from_secs(20)) {
            echo_endpoint(endpoint);
        }
    });
    dial_and_echo(&listener, "via-stun-config");
    hit_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("session peer never queried the configured STUN server");
    listener.close();
}

#[test]
fn rendezvous_many_peers_demux() {
    // 8 concurrent dialers, unique messages each: sessions
    // must stay apart on the one listener socket (no
    // cross-talk, no lost echoes).
    let (endpoint_tx, endpoint_rx) = channel::<DcEndpoint>();
    let listener = RendezvousListener::bind(
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        RendezvousOptions {
            on_endpoint: Box::new(move |endpoint| {
                let _ = endpoint_tx.send(endpoint);
            }),
            on_error: Box::new(|_| {}),
            ..Default::default()
        },
    )
    .unwrap();
    let listener = Arc::new(listener);
    std::thread::spawn(move || {
        while let Ok(endpoint) = endpoint_rx.recv_timeout(Duration::from_secs(60)) {
            echo_endpoint(endpoint);
        }
    });
    let mut handles = Vec::new();
    for i in 0..8 {
        let listener = listener.clone();
        handles.push(std::thread::spawn(move || {
            dial_and_echo(&listener, &format!("peer-{i}"));
        }));
        // Stagger starts: simultaneous DTLS handshakes
        // retransmitting on the same 1s boundaries collapse
        // into each other on small CI runners (all dialers
        // time out together, seen on GitHub's 2-core runners
        // with 12 peers at 150ms); 8 peers at 350ms keeps the
        // demux pressure without the thundering herd.
        std::thread::sleep(Duration::from_millis(350));
    }
    for h in handles {
        h.join().unwrap();
    }
}

