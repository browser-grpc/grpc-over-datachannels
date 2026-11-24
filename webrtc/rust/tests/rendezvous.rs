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
use dc_webrtc::turn::TurnServerConfig;

mod turn_fixture;
use turn_fixture::*;
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
fn rendezvous_turn_relay_only_echo() {
    // Relay-only rendezvous (issue #3): the dialer sits
    // behind a NAT proxy socket. The proxy forwards exactly
    // the dialer's first Binding request to the listener
    // (the rendezvous bootstrap: that packet is what spawns
    // the session), then switches: every later dialer packet
    // goes to the session's TURN relayed address, and only
    // relay-originated packets come back. Nothing after the
    // first packet touches the listener socket, and the
    // session relays all of its pair traffic once it holds
    // an allocation, so ICE, DTLS, and the echo below can
    // only have crossed the TURN relay.
    use std::sync::atomic::{AtomicUsize, Ordering};
    let (server, state) = fake_turn_server_with(600, 300);
    let (endpoint_tx, endpoint_rx) = channel::<DcEndpoint>();
    let listener = RendezvousListener::bind(
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        RendezvousOptions {
            turn_servers: vec![TurnServerConfig::new(&server, USER, PASS)],
            on_endpoint: Box::new(move |endpoint| {
                let _ = endpoint_tx.send(endpoint);
            }),
            on_error: Box::new(|e| eprintln!("rendezvous: {e}")),
            ..Default::default()
        },
    )
    .unwrap();
    let desc = listener.descriptor("127.0.0.1");
    let listener_addr =
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), desc.port);

    // NAT proxy: learns the dialer's address from its first
    // packet, forwards that packet to the listener, then
    // re-targets the dialer's flow at the relayed address as
    // soon as the fake TURN server records the allocation.
    let proxy = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    proxy
        .set_read_timeout(Some(Duration::from_millis(20)))
        .unwrap();
    let proxy_addr = proxy.local_addr().unwrap();
    let relayed_seen = Arc::new(AtomicUsize::new(0));
    let relayed_seen2 = relayed_seen.clone();
    let proxy_state = state.clone();
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 65536];
        let mut dialer: Option<SocketAddr> = None;
        let mut relayed: Option<SocketAddr> = None;
        let mut bootstrapped = false;
        loop {
            if relayed.is_none() {
                let st = proxy_state.lock().unwrap();
                relayed = st.by_relay.keys().next().copied();
            }
            match proxy.recv_from(&mut buf) {
                Ok((n, src)) => {
                    let data = &buf[..n];
                    if Some(src) == relayed {
                        relayed_seen2.fetch_add(1, Ordering::SeqCst);
                        if let Some(d) = dialer {
                            let _ = proxy.send_to(data, d);
                        }
                    } else if dialer.is_none() || Some(src) == dialer {
                        dialer = Some(src);
                        if !bootstrapped {
                            bootstrapped = true;
                            let _ = proxy.send_to(data, listener_addr);
                        } else if let Some(r) = relayed {
                            let _ = proxy.send_to(data, r);
                        } else {
                            // Allocation not recorded yet;
                            // drop: ICE retransmits.
                        }
                    } else if Some(src) == Some(listener_addr) {
                        if let Some(d) = dialer {
                            let _ = proxy.send_to(data, d);
                        }
                    }
                }
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => return,
            }
        }
    });

    std::thread::spawn(move || {
        if let Ok(endpoint) = endpoint_rx.recv_timeout(Duration::from_secs(30)) {
            echo_endpoint(endpoint);
        }
    });

    // Dialer whose only remote candidate is the NAT proxy
    // address: it has no route to the listener at all.
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
        candidates: vec![Candidate::host(proxy_addr, "1")],
        sctp_port: 5000,
    };
    dialer.handle_answer(&generate(&remote, false)).unwrap();
    let endpoint = dialer.connect().expect("dialer connect over relay only");
    let channel = endpoint
        .open_channel(ChannelParams { label: "grpc".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"relay-only").unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        match endpoint.recv_event_timeout(Duration::from_secs(1)) {
            Some(EndpointEvent::Message { data, .. }) => {
                assert_eq!(data, b"re:relay-only".to_vec());
                break;
            }
            Some(_) => {
                assert!(std::time::Instant::now() < deadline, "echo timeout over relay");
            }
            None => panic!("echo timeout over relay"),
        }
    }
    // The relay really carried it: the session allocated,
    // the TURN server forwarded session traffic directly to
    // the proxy (the dialer's reflexive address), and the
    // proxy saw relay-originated packets come back.
    let st = state.lock().unwrap();
    assert!(st.alloc_count >= 1, "no TURN allocation for the session");
    assert!(st.direct_count >= 1, "TURN server never forwarded session traffic");
    drop(st);
    assert!(
        relayed_seen.load(Ordering::SeqCst) >= 1,
        "proxy never saw a relay-originated packet"
    );
    endpoint.shutdown();
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

