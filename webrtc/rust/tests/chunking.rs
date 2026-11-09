//! DC message chunking end-to-end (DcEndpoint::set_chunk_messages):
//! a 1 MiB binary message crosses as [0xF0, flags] chunks and
//! reassembles whole — the path that lets browser peers (256 KiB
//! RTCDataChannel message cap) exchange multi-MB grpc-dc frames.
//! Mirrors webrtc/js/test/chunking.test.js.

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
        connection_id: None,
        pair_hint: None,
    }
}

#[test]
fn chunked_peers_echo_one_mib() {
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
    client_ep.set_chunk_messages(true);
    server_ep.set_chunk_messages(true);

    let channel = client_ep
        .open_channel(ChannelParams { label: "chunk".into(), ..Default::default() })
        .unwrap();
    let server_channel = match server_ep.recv_event_timeout(Duration::from_secs(5)) {
        Some(EndpointEvent::ChannelOpened { channel }) => channel,
        _ => panic!("expected ChannelOpened"),
    };

    // Server echo loop (bounded; runs until both asserts are done).
    let server_done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let server_flag = server_done.clone();
    let server_thread2 = std::thread::spawn(move || {
        let big = vec![65u8; 1024 * 1024];
        let deadline = std::time::Instant::now() + Duration::from_secs(30);
        while std::time::Instant::now() < deadline {
            match server_ep.recv_event_timeout(Duration::from_millis(200)) {
                Some(EndpointEvent::Message { stream, text: false, data }) => {
                    assert_eq!(data.len(), big.len(), "server must see the whole 1 MiB message");
                    assert!(data == big);
                    server_channel.send_binary(&data).unwrap();
                    let _ = stream;
                    break;
                }
                Some(_) => continue,
                None => continue,
            }
        }
        while !server_flag.load(std::sync::atomic::Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(10));
        }
    });

    let big = vec![65u8; 1024 * 1024];
    channel.send_binary(&big).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    let mut echoed = false;
    while std::time::Instant::now() < deadline {
        match client_ep.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::Message { text: false, data, .. }) => {
                assert!(data == big, "echo must be the whole 1 MiB message");
                echoed = true;
                break;
            }
            Some(_) => continue,
            None => continue,
        }
    }
    server_done.store(true, std::sync::atomic::Ordering::SeqCst);
    let _ = server_thread2.join();
    assert!(echoed, "no 1 MiB echo within deadline");
}
