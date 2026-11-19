//! dc-dtls-ffi interop: FFI<->FFI handshake pumped by
//! hand, and FFI client <-> driven Dtls server (the real
//! engine on both sides of the ABI).

use dc_dtls_ffi::*;
use dc_webrtc::dtls::{Dtls, DtlsConfig, DtlsIo};
use dc_webrtc::x509::Certificate;
use std::io;
use std::sync::mpsc;
use std::time::{Duration, Instant};

const CAP: usize = 1 << 20;

const TICKET_KEY: [u8; 32] = [7u8; 32];

fn key_scalar(cert: &Certificate) -> [u8; 32] {
    cert.private.to_bytes()
}

fn split_frames(buf: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < buf.len() {
        let len = u32::from_be_bytes(buf[pos..pos + 4].try_into().unwrap()) as usize;
        pos += 4;
        out.push(buf[pos..pos + len].to_vec());
        pos += len;
    }
    out
}

struct Handle(*mut GrpcdcDtls);

impl Handle {
    fn start(&self) -> Vec<Vec<u8>> {
        let mut buf = vec![0u8; CAP];
        let n = grpcdc_dtls_start(self.0, buf.as_mut_ptr(), CAP);
        assert!(n >= 0, "start rc={n}");
        buf.truncate(n as usize);
        split_frames(&buf)
    }
    fn handle(&self, packet: &[u8], now: u64) -> Vec<Vec<u8>> {
        let mut buf = vec![0u8; CAP];
        let n = grpcdc_dtls_handle_datagram(
            self.0,
            packet.as_ptr(),
            packet.len(),
            now,
            buf.as_mut_ptr(),
            CAP,
        );
        assert!(n >= 0, "handle rc={n}");
        buf.truncate(n as usize);
        split_frames(&buf)
    }
    fn tick(&self, now: u64) -> Vec<Vec<u8>> {
        let mut buf = vec![0u8; CAP];
        let n = grpcdc_dtls_tick(self.0, now, buf.as_mut_ptr(), CAP);
        assert!(n >= 0, "tick rc={n}");
        buf.truncate(n as usize);
        split_frames(&buf)
    }
    fn established(&self) -> bool {
        grpcdc_dtls_is_established(self.0) != 0
    }
    fn failure(&self) -> String {
        let mut buf = vec![0u8; 256];
        let n = grpcdc_dtls_failure(self.0, buf.as_mut_ptr() as *mut std::ffi::c_char, buf.len());
        if n <= 0 {
            return String::new();
        }
        String::from_utf8_lossy(&buf[..n as usize]).into_owned()
    }
    fn next_timeout(&self, now: u64) -> Option<u64> {
        let v = grpcdc_dtls_next_timeout(self.0, now);
        if v < 0 {
            None
        } else {
            Some(v as u64)
        }
    }
    fn app_echo_roundtrip(&self, peer: &Handle) {
        let mut out = vec![0u8; 4096];
        let n = grpcdc_dtls_encrypt_app(
            self.0,
            b"ping".as_ptr(),
            4,
            out.as_mut_ptr(),
            out.len(),
        );
        assert!(n > 0, "encrypt rc={n}");
        out.truncate(n as usize);
        let mut plain = vec![0u8; 4096];
        let m = grpcdc_dtls_handle_app(
            peer.0,
            out.as_ptr(),
            out.len(),
            plain.as_mut_ptr(),
            plain.len(),
        );
        assert_eq!(m, 4, "handle_app rc={m}");
        plain.truncate(m as usize);
        assert_eq!(plain, b"ping");
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        grpcdc_dtls_free(self.0);
    }
}

fn cfg_for(cert: &Certificate, resumption: bool) -> GrpcdcDtlsConfig {
    // NOTE: key_scalar must outlive the call only (copied
    // into the core config), so a leaked-static style temp
    // is fine in tests via thread_local-free approach: the
    // caller keeps cert alive; scalar pointer is into a
    // fresh allocation the caller also keeps. Here we leak
    // deliberately per test (process-lifetime).
    let scalar = Box::leak(Box::new(key_scalar(cert)));
    GrpcdcDtlsConfig {
        cert_der: cert.der.as_ptr(),
        cert_der_len: cert.der.len(),
        key_scalar: scalar.as_ptr(),
        expected_fingerprint: std::ptr::null(),
        require_peer_certificate: 0,
        session_resumption: resumption as u8,
        ticket_key: if resumption {
            TICKET_KEY.as_ptr()
        } else {
            std::ptr::null()
        },
        connection_id: std::ptr::null(),
        connection_id_len: 0,
        pair_hint: std::ptr::null(),
        pair_hint_len: 0,
    }
}

fn pump_pair(client: &Handle, server: &Handle) {
    let mut now = 0u64;
    let mut c2s = client.start();
    let mut s2c: Vec<Vec<u8>> = Vec::new();
    for _ in 0..100_000 {
        if client.established() && server.established() {
            return;
        }
        for p in std::mem::take(&mut c2s) {
            s2c.extend(server.handle(&p, now));
        }
        for p in std::mem::take(&mut s2c) {
            c2s.extend(client.handle(&p, now));
        }
        if client.established() && server.established() {
            return;
        }
        assert!(
            client.failure().is_empty() && server.failure().is_empty(),
            "client={:?} server={:?}",
            client.failure(),
            server.failure()
        );
        if c2s.is_empty() && s2c.is_empty() {
            let wait = [client.next_timeout(now), server.next_timeout(now)]
                .into_iter()
                .flatten()
                .min()
                .unwrap_or(1000)
                .max(1);
            now += wait;
            c2s.extend(client.tick(now));
            s2c.extend(server.tick(now));
        }
    }
    panic!("FFI handshake did not establish");
}

#[test]
fn ffi_to_ffi_handshake_and_app_data() {
    let client_cert = Certificate::generate_self_signed("client");
    let server_cert = Certificate::generate_self_signed("server");
    let client = Handle(grpcdc_dtls_new_client(&cfg_for(&client_cert, false), std::ptr::null(), 0));
    assert!(!client.0.is_null());
    let server = Handle(grpcdc_dtls_new_server(&cfg_for(&server_cert, false), 0));
    assert!(!server.0.is_null());
    pump_pair(&client, &server);
    client.app_echo_roundtrip(&server);
    server.app_echo_roundtrip(&client);
    // Fingerprint crosses the ABI.
    let mut buf = vec![0u8; 256];
    let n = grpcdc_dtls_peer_fingerprint(
        client.0,
        buf.as_mut_ptr() as *mut std::ffi::c_char,
        buf.len(),
    );
    assert!(n > 0);
    buf.truncate(n as usize);
    assert_eq!(
        String::from_utf8_lossy(&buf),
        server_cert.fingerprint()
    );
}

// --- FFI client <-> driven Dtls server ----------------------

struct MemoryIo {
    tx: mpsc::Sender<Vec<u8>>,
    rx: mpsc::Receiver<Vec<u8>>,
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

fn real_now(epoch: Instant) -> u64 {
    epoch.elapsed().as_millis() as u64
}

#[test]
fn ffi_client_against_driven_server() {
    let (c2s_tx, c2s_rx) = mpsc::channel::<Vec<u8>>();
    let (s2c_tx, s2c_rx) = mpsc::channel::<Vec<u8>>();
    let server_io = MemoryIo {
        tx: s2c_tx,
        rx: c2s_rx,
    };
    let server_cert = Certificate::generate_self_signed("server");
    let cfg = DtlsConfig {
        certificate: server_cert.clone(),
        expected_peer_fingerprint: None,
        require_peer_certificate: false,
        session_resumption: false,
        session_ticket_key: None,
        connection_id: None,
        pair_hint: None,
    };
    let server = std::thread::spawn(move || {
        let mut dtls = Dtls::accept(server_io, &cfg).expect("driven accept");
        let msg = dtls
            .recv_app_timeout(Duration::from_secs(10))
            .expect("driven recv")
            .expect("message");
        dtls.send_app(&msg).expect("driven echo");
        dtls
    });

    let client_cert = Certificate::generate_self_signed("client");
    let client = Handle(grpcdc_dtls_new_client(
        &cfg_for(&client_cert, false),
        std::ptr::null(),
        0,
    ));
    assert!(!client.0.is_null());
    let epoch = Instant::now();
    for p in client.start() {
        c2s_tx.send(p).unwrap();
    }
    let deadline = Instant::now() + Duration::from_secs(15);
    while !client.established() {
        assert!(Instant::now() < deadline, "FFI client timed out: {:?}", client.failure());
        match s2c_rx.recv_timeout(Duration::from_millis(50)) {
            Ok(packet) => {
                for out in client.handle(&packet, real_now(epoch)) {
                    c2s_tx.send(out).unwrap();
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                for out in client.tick(real_now(epoch)) {
                    c2s_tx.send(out).unwrap();
                }
            }
            Err(e) => panic!("channel: {e}"),
        }
    }
    // App data: FFI encrypt -> driven echo -> FFI decrypt.
    let mut record = vec![0u8; 4096];
    let n = grpcdc_dtls_encrypt_app(client.0, b"ping".as_ptr(), 4, record.as_mut_ptr(), record.len());
    assert!(n > 0);
    record.truncate(n as usize);
    c2s_tx.send(record).unwrap();
    let echo = s2c_rx
        .recv_timeout(Duration::from_secs(10))
        .expect("echo packet");
    let mut plain = vec![0u8; 4096];
    let m = grpcdc_dtls_handle_app(
        client.0,
        echo.as_ptr(),
        echo.len(),
        plain.as_mut_ptr(),
        plain.len(),
    );
    assert_eq!(m, 4);
    plain.truncate(m as usize);
    assert_eq!(plain, b"ping");
    let _server = server.join().unwrap();
}
