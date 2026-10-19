//! DataChannel end-to-end over DTLS+UDP loopback (no ICE yet): the
//! DTLS client opens a channel, the server echoes binary and text.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::dtls::{Dtls, DtlsConfig, Role, UdpDtlsIo};
use dc_webrtc::endpoint::{DcEndpoint, EndpointEvent};
use dc_webrtc::x509::Certificate;
use std::net::UdpSocket;
use std::time::Duration;

fn config() -> DtlsConfig {
    DtlsConfig {
        certificate: Certificate::generate_self_signed("dc-webrtc"),
        expected_peer_fingerprint: None,
        require_peer_certificate: false,
        session_resumption: false,
        session_ticket_key: None,
    }
}

#[test]
fn datachannel_echo_rust_rust() {
    let client_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    let server_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    let client_addr = client_socket.local_addr().unwrap();
    let server_addr = server_socket.local_addr().unwrap();

    let server_thread = std::thread::spawn(move || {
        let io = UdpDtlsIo { socket: server_socket, peer: client_addr };
        let dtls = Dtls::accept(io, &config()).expect("server handshake");
        DcEndpoint::spawn(dtls, Role::Server, 5000)
    });
    let client_io = UdpDtlsIo { socket: client_socket, peer: server_addr };
    let client_dtls = Dtls::connect(client_io, &config()).expect("client handshake");
    let client_ep = DcEndpoint::spawn(client_dtls, Role::Client, 5000);
    let server_ep = server_thread.join().unwrap();

    let channel = client_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    assert_eq!(channel.stream, 0, "DTLS client must use even streams");

    // Server learns of the channel.
    let server_channel = match server_ep.recv_event_timeout(Duration::from_secs(5)) {
        Some(EndpointEvent::ChannelOpened { channel }) => channel,
        other => panic!("expected ChannelOpened, got {:?}", other.map(|_| "other")),
    };
    assert_eq!(server_channel.stream, 0);
    assert_eq!(server_channel.label, "echo");

    channel.send_binary(b"ping-binary").unwrap();
    channel.send_text("ping-text").unwrap();

    let mut got_binary = false;
    let mut got_text = false;
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !(got_binary && got_text) && std::time::Instant::now() < deadline {
        match server_ep.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::Message { stream, text, data }) => {
                assert_eq!(stream, 0);
                if text {
                    got_text = true;
                    assert_eq!(data, b"ping-text");
                } else {
                    got_binary = true;
                    assert_eq!(data, b"ping-binary");
                }
                server_channel
                    .send_binary(&[b"re:".as_slice(), &data].concat())
                    .unwrap();
            }
            Some(_) => {}
            None => {}
        }
    }
    assert!(got_binary && got_text);

    let mut replies = Vec::new();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while replies.len() < 2 && std::time::Instant::now() < deadline {
        match client_ep.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::Message { data, .. }) => replies.push(data),
            Some(_) => {}
            None => {}
        }
    }
    assert_eq!(replies.len(), 2);
    assert!(replies.iter().any(|r| r == b"re:ping-binary"));
    assert!(replies.iter().any(|r| r == b"re:ping-text"));

    client_ep.shutdown();
    server_ep.shutdown();
}
