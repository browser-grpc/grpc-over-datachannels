//! Direct DTLS connection-id check: two stacks negotiate
//! RFC 9146 cids (different lengths per direction) and move
//! data over the resulting channel.
use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::dtls::{Dtls, DtlsConfig, Role, UdpDtlsIo};
use dc_webrtc::endpoint::{DcEndpoint, EndpointEvent};
use dc_webrtc::x509::Certificate;
use std::net::UdpSocket;
use std::time::Duration;

fn config(cid: Option<Vec<u8>>) -> DtlsConfig {
    DtlsConfig {
        certificate: Certificate::generate_self_signed("cid-test"),
        expected_peer_fingerprint: None,
        require_peer_certificate: false,
        session_resumption: false,
        session_ticket_key: None,
        connection_id: cid,
        pair_hint: None,
    }
}

#[test]
fn dtls_with_connection_ids() {
    let client_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    let server_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    let client_addr = client_socket.local_addr().unwrap();
    let server_addr = server_socket.local_addr().unwrap();
    let server = std::thread::spawn(move || {
        let io = UdpDtlsIo { socket: server_socket, peer: client_addr };
        let dtls = Dtls::accept(io, &config(Some(vec![9u8; 6]))).unwrap();
        DcEndpoint::spawn(dtls, Role::Server, 5000)
    });
    let io = UdpDtlsIo { socket: client_socket, peer: server_addr };
    let dtls = Dtls::connect(io, &config(Some(vec![7u8; 4]))).unwrap();
    let client_ep = DcEndpoint::spawn(dtls, Role::Client, 5000);
    let server_ep = server.join().unwrap();

    let channel = client_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    let server_channel = match server_ep.recv_event_timeout(Duration::from_secs(5)) {
        Some(EndpointEvent::ChannelOpened { channel }) => channel,
        _ => panic!("no channel"),
    };
    channel.send_text("ping").unwrap();
    match server_ep.recv_event_timeout(Duration::from_secs(5)) {
        Some(EndpointEvent::Message { data, .. }) => {
            server_channel.send_binary(&data).unwrap();
        }
        _ => panic!("no message"),
    }
    match client_ep.recv_event_timeout(Duration::from_secs(5)) {
        Some(EndpointEvent::Message { data, .. }) => {
            assert_eq!(&data, b"ping");
        }
        _ => panic!("no echo"),
    }
    client_ep.shutdown();
    server_ep.shutdown();
}
