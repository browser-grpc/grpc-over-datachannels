//! DTLS session resumption (RFC 5077 tickets) and the pluggable
//! crypto backend seam.

use dc_webrtc::crypto::{install_backend, CryptoBackend, HandRolledBackend};
use dc_webrtc::dtls::{Dtls, DtlsConfig, DtlsIo, DtlsSession};
use dc_webrtc::x509::Certificate;
use std::io;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
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

const TICKET_KEY: [u8; 32] = [7u8; 32];

fn config(cert: Certificate, server: bool, expected: Option<String>) -> DtlsConfig {
    DtlsConfig {
        certificate: cert,
        expected_peer_fingerprint: expected,
        require_peer_certificate: false,
        session_resumption: true,
        session_ticket_key: if server { Some(TICKET_KEY) } else { None },
        connection_id: None,
        pair_hint: None,
    }
}

/// Full handshake, then echo one app message server->client.
fn full_connect(
    server_cert: Certificate,
    client_cert: Certificate,
    expected: Option<String>,
) -> (DtlsSession, String) {
    let server_fingerprint = server_cert.fingerprint();
    let (client_io, server_io) = io_pair();
    let server = std::thread::spawn(move || {
        let mut dtls = Dtls::accept(server_io, &config(server_cert, true, None))
            .expect("server handshake");
        let msg = dtls
            .recv_app_timeout(Duration::from_secs(5))
            .expect("server recv")
            .expect("server message");
        dtls.send_app(&msg).expect("server echo");
        dtls
    });
    let mut client =
        Dtls::connect(client_io, &config(client_cert, false, expected)).expect("client handshake");
    client.send_app(b"ping").expect("client send");
    let echoed = client
        .recv_app_timeout(Duration::from_secs(5))
        .expect("client recv")
        .expect("client message");
    assert_eq!(echoed, b"ping");
    let _server = server.join().unwrap();
    (
        client.take_session().expect("client captured a session ticket"),
        server_fingerprint,
    )
}

#[test]
fn resumed_handshake_skips_certificates_but_keeps_identity() {
    let server_cert = Certificate::generate_self_signed("server-one");
    let original_fingerprint = server_cert.fingerprint();
    let client_cert = Certificate::generate_self_signed("client");
    let (session, _) = full_connect(server_cert, Certificate::generate_self_signed("client"), None);

    // Reconnect against a server presenting a DIFFERENT
    // certificate. A full handshake would fail the fingerprint
    // check (expects the original); resumption must succeed
    // because identity comes from the sealed ticket.
    let (client_io, server_io) = io_pair();
    let other_cert = Certificate::generate_self_signed("server-two");
    let server = std::thread::spawn(move || {
        let mut dtls = Dtls::accept(server_io, &config(other_cert, true, None))
            .expect("server resumed handshake");
        let msg = dtls
            .recv_app_timeout(Duration::from_secs(5))
            .expect("server recv")
            .expect("server message");
        dtls.send_app(&msg).expect("server echo");
    });
    let mut client = Dtls::connect_resumed(
        client_io,
        &config(client_cert, false, Some(original_fingerprint)),
        &session,
    )
    .expect("resumed handshake keeps ticket identity");
    assert_eq!(
        client.peer_fingerprint().as_deref(),
        Some(session_fingerprint(&session).as_str()),
        "peer identity reported from the ticket"
    );
    client.send_app(b"again").expect("client send");
    let echoed = client
        .recv_app_timeout(Duration::from_secs(5))
        .expect("client recv")
        .expect("client message");
    assert_eq!(echoed, b"again");
    server.join().unwrap();
}

fn session_fingerprint(session: &DtlsSession) -> String {
    dc_webrtc::x509::fingerprint_of_der(&session.peer_certificate)
}

#[test]
fn tampered_ticket_falls_back_to_full_handshake() {
    let server_cert = Certificate::generate_self_signed("server-one");
    let client_cert = Certificate::generate_self_signed("client");
    let (mut session, _) =
        full_connect(server_cert, Certificate::generate_self_signed("client"), None);
    // Corrupt the sealed ticket: the server cannot open it and
    // must fall back to a full handshake (presenting its real
    // certificate, pinned by fingerprint).
    let len = session.ticket.len();
    session.ticket[len - 1] ^= 0xff;

    let server_cert = Certificate::generate_self_signed("server-one");
    let fingerprint = server_cert.fingerprint();
    let (client_io, server_io) = io_pair();
    let server = std::thread::spawn(move || {
        Dtls::accept(server_io, &config(server_cert, true, None)).expect("server fallback")
    });
    let client = Dtls::connect_resumed(
        client_io,
        &config(client_cert, false, Some(fingerprint)),
        &session,
    )
    .expect("fallback full handshake succeeds");
    drop(client);
    let _ = server.join().unwrap();
}

#[test]
fn wrong_ticket_key_falls_back_to_full_handshake() {
    let server_cert = Certificate::generate_self_signed("server-one");
    let client_cert = Certificate::generate_self_signed("client");
    let (session, _) =
        full_connect(server_cert, Certificate::generate_self_signed("client"), None);
    let server_cert = Certificate::generate_self_signed("server-one");
    let fingerprint = server_cert.fingerprint();
    let (client_io, server_io) = io_pair();
    let server = std::thread::spawn(move || {
        let mut cfg = config(server_cert, true, None);
        cfg.session_ticket_key = Some([9u8; 32]);
        Dtls::accept(server_io, &cfg).expect("server fallback")
    });
    let client = Dtls::connect_resumed(
        client_io,
        &config(client_cert, false, Some(fingerprint)),
        &session,
    )
    .expect("fallback full handshake succeeds");
    drop(client);
    let _ = server.join().unwrap();
}

struct CountingBackend {
    inner: HandRolledBackend,
    sha256_calls: AtomicUsize,
}

impl CryptoBackend for CountingBackend {
    fn sha256(&self, data: &[u8]) -> [u8; 32] {
        self.sha256_calls.fetch_add(1, Ordering::SeqCst);
        self.inner.sha256(data)
    }

    fn hmac_sha256(&self, key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
        self.inner.hmac_sha256(key, parts)
    }

    fn prf(&self, secret: &[u8], label: &str, seed: &[u8], out_len: usize) -> Vec<u8> {
        self.inner.prf(secret, label, seed, out_len)
    }

    fn aes128_gcm_encrypt(
        &self,
        key: &[u8; 16],
        nonce: &[u8; 12],
        plaintext: &[u8],
        aad: &[u8],
    ) -> (Vec<u8>, [u8; 16]) {
        self.inner.aes128_gcm_encrypt(key, nonce, plaintext, aad)
    }

    fn aes128_gcm_decrypt(
        &self,
        key: &[u8; 16],
        nonce: &[u8; 12],
        ciphertext: &[u8],
        aad: &[u8],
        tag: &[u8; 16],
    ) -> Option<Vec<u8>> {
        self.inner.aes128_gcm_decrypt(key, nonce, ciphertext, aad, tag)
    }
}

#[test]
fn installed_backend_serves_handshake_crypto() {
    let backend = Arc::new(CountingBackend {
        inner: HandRolledBackend,
        sha256_calls: AtomicUsize::new(0),
    });
    // Process-global one-way install; if another test in this
    // binary installed first, the handshake still works through
    // whatever is installed — only assert our counter when ours won.
    let ours = install_backend(backend.clone());

    let server_cert = Certificate::generate_self_signed("server");
    let client_cert = Certificate::generate_self_signed("client");
    let (client_io, server_io) = io_pair();
    let server = std::thread::spawn(move || {
        Dtls::accept(server_io, &config(server_cert, true, None)).expect("server handshake")
    });
    let client =
        Dtls::connect(client_io, &config(client_cert, false, None)).expect("client handshake");
    drop(client);
    let _ = server.join().unwrap();

    if ours {
        assert!(
            backend.sha256_calls.load(Ordering::SeqCst) > 0,
            "handshake crypto routed through the installed backend"
        );
    }
}
