//! DtlsCore (sans-io established phase): after a driven
//! handshake, both sides convert to cores and exchange app
//! data by pumping datagrams by hand — no DtlsIo anywhere.

use dc_webrtc::dtls::{Dtls, DtlsConfig, DtlsIo};
use dc_webrtc::x509::Certificate;
use std::io;
use std::sync::mpsc;
use std::time::Duration;

struct MemoryIo {
    tx: mpsc::Sender<Vec<u8>>,
    rx: mpsc::Receiver<Vec<u8>>,
}

fn io_pair() -> (MemoryIo, MemoryIo) {
    let (tx1, rx1) = mpsc::channel();
    let (tx2, rx2) = mpsc::channel();
    (
        MemoryIo { tx: tx1, rx: rx2 },
        MemoryIo { tx: tx2, rx: rx1 },
    )
}

impl DtlsIo for MemoryIo {
    fn send_packet(&mut self, packet: &[u8]) -> io::Result<()> {
        self.tx
            .send(packet.to_vec())
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "peer gone"))
    }

    fn recv_packet(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        match self.rx.recv_timeout(timeout) {
            Ok(packet) => Ok(Some(packet)),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                Err(io::Error::new(io::ErrorKind::BrokenPipe, "peer gone"))
            }
        }
    }
}

fn config(cert: Certificate) -> DtlsConfig {
    DtlsConfig {
        certificate: cert,
        expected_peer_fingerprint: None,
        require_peer_certificate: false,
        session_resumption: false,
        session_ticket_key: None,
        connection_id: None,
        pair_hint: None,
    }
}

#[test]
fn cores_exchange_app_data_sans_io() {
    let (client_io, server_io) = io_pair();
    let server = std::thread::spawn(move || {
        Dtls::accept(server_io, &config(Certificate::generate_self_signed("server")))
            .expect("server handshake")
            .into_core()
    });
    let client = Dtls::connect(
        client_io,
        &config(Certificate::generate_self_signed("client")),
    )
    .expect("client handshake");
    assert!(client.peer_fingerprint().is_some(), "driven accessor");
    let mut client = client.into_core();
    let mut server = server.join().unwrap();

    // Fingerprint + SRTP accessors live on the core now.
    assert!(client.peer_fingerprint().is_some());
    assert!(server.peer_fingerprint().is_some());

    // Client -> server, pumped by hand.
    let packet = client.encrypt_app(b"ping").expect("encrypt");
    let got = server
        .handle_datagram(&packet)
        .expect("handle")
        .expect("app data");
    assert_eq!(got, b"ping");

    // Replay of the same datagram must not deliver twice.
    let replayed = server.handle_datagram(&packet).expect("replay handle");
    assert!(replayed.is_none(), "replay window rejects duplicate");

    // Server -> client reply.
    let reply = server.encrypt_app(b"pong").expect("encrypt reply");
    let got = client
        .handle_datagram(&reply)
        .expect("handle reply")
        .expect("app data");
    assert_eq!(got, b"pong");

    // Keying material export works sans-io.
    let a = client.export_keying_material("test", b"", 16);
    let b = server.export_keying_material("test", b"", 16);
    assert_eq!(a, b, "exporter agrees on both cores");
    assert_eq!(a.len(), 16);
}
