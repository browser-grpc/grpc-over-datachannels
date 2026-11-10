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
