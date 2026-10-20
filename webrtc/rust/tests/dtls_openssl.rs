//! DTLS oracle tests: our handshake against OpenSSL (the reference
//! implementation every browser stack is measured against), in both
//! roles, plus our own client<->server. Tests that need the `openssl`
//! CLI skip quietly when it is unavailable.

use std::io::{BufRead, BufReader, Write};
use std::net::UdpSocket;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

fn echo_binary() -> std::path::PathBuf {
    // target/debug/examples/dtls_echo, relative to this test binary
    // (target/debug/deps/<test>) — cargo builds examples with tests.
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop(); // deps
    path.pop(); // debug
    path.push("examples/dtls_echo");
    path
}

fn free_port() -> u16 {
    UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn wait_for_stderr_opt(child: &mut Child, needle: &str, timeout: Duration) -> Option<String> {
    let stderr = child.stderr.take().expect("stderr piped");
    let (tx, rx) = mpsc::channel();
    let needle = needle.to_string();
    let needle_in_thread = needle.clone();
    std::thread::spawn(move || {
        let needle = needle_in_thread;
        let mut captured = String::new();
        for line in BufReader::new(stderr).lines() {
            match line {
                Ok(line) => {
                    captured.push_str(&line);
                    captured.push('\n');
                    if captured.contains(&needle) {
                        let _ = tx.send(captured.clone());
                    }
                }
                Err(_) => break,
            }
        }
        let _ = tx.send(captured);
    });
    let deadline = Instant::now() + timeout;
    loop {
        match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(text) if text.contains(&needle) => return Some(text),
            Ok(_) => continue,
            Err(_) => return None,
        }
    }
}

fn spawn_server(port: u16) -> Child {
    Command::new(echo_binary())
        .args(["server", &port.to_string()])
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn dtls_echo server")
}

// Spawn the echo server and wait (generously) for it to listen.
// Process startup under a full parallel test run can take far
// longer than 5s, and the probed free port can be taken by a
// sibling test before the server binds; retry with a fresh port
// instead of flaking.
fn start_server() -> (Child, u16) {
    for _ in 0..3 {
        let port = free_port();
        let mut server = spawn_server(port);
        if wait_for_stderr_opt(&mut server, "LISTENING", Duration::from_secs(30)).is_some() {
            return (server, port);
        }
        server.kill().ok();
    }
    panic!("dtls_echo server did not start after 3 attempts");
}

#[test]
fn rust_client_rust_server_echo() {
    let (mut server, port) = start_server();

    let mut client = Command::new(echo_binary())
        .args(["client", &port.to_string()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn dtls_echo client");
    client.stdin.as_mut().unwrap().write_all(b"hello\ndtls world\n").unwrap();
    drop(client.stdin.take());
    let out = client.wait_with_output().unwrap();
    assert!(out.status.success(), "client failed: {}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "echo:hello\necho:dtls world\n");
    server.kill().ok();
}

fn have_openssl() -> bool {
    Command::new("openssl").arg("version").output().map(|o| o.status.success()).unwrap_or(false)
}

fn openssl_cert() -> (std::path::PathBuf, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("dc-webrtc-ossl-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let key = dir.join("key.pem");
    let cert = dir.join("cert.pem");
    let status = Command::new("openssl")
        .args([
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-keyout", key.to_str().unwrap(), "-out", cert.to_str().unwrap(),
            "-days", "1", "-nodes", "-subj", "/CN=openssl-dtls",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    (cert, key)
}

#[test]
fn rust_client_openssl_server() {
    if !have_openssl() {
        eprintln!("openssl CLI not available; skipping");
        return;
    }
    let (cert, key) = openssl_cert();
    // The probed free port can be taken by a sibling test before
    // s_server binds (parallel runs); retry with a fresh port
    // when the server dies during startup.
    let mut server = None;
    let mut port = 0;
    for _ in 0..3 {
        port = free_port();
        let mut candidate = Command::new("openssl")
            .args([
                "s_server", "-accept", &port.to_string(), "-dtls1_2",
                "-cert", cert.to_str().unwrap(), "-key", key.to_str().unwrap(),
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn openssl s_server");
        std::thread::sleep(Duration::from_millis(500));
        if candidate.try_wait().unwrap().is_none() {
            server = Some(candidate);
            break;
        }
    }
    let mut server = server.expect("openssl s_server did not stay up after 3 attempts");

    let mut client = Command::new(echo_binary())
        .args(["client", &port.to_string()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn dtls_echo client");
    client.stdin.as_mut().unwrap().write_all(b"ping\n").unwrap();
    std::thread::sleep(Duration::from_millis(500));
    server.stdin.as_mut().unwrap().write_all(b"from-openssl\n").unwrap();
    drop(client.stdin.take());
    drop(server.stdin.take());
    let out = client.wait_with_output().unwrap();
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("HANDSHAKE_OK"),
        "client stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "from-openssl");
    server.kill().ok();
}

struct WireIo {
    socket: UdpSocket,
    peer: std::net::SocketAddr,
    seen: std::sync::Arc<std::sync::Mutex<Vec<Vec<u8>>>>,
}

impl dc_webrtc::dtls::DtlsIo for WireIo {
    fn send_packet(&mut self, packet: &[u8]) -> std::io::Result<()> {
        self.socket.send_to(packet, self.peer)?;
        Ok(())
    }
    fn recv_packet(&mut self, timeout: Duration) -> std::io::Result<Option<Vec<u8>>> {
        self.socket.set_read_timeout(Some(timeout))?;
        let mut buf = vec![0u8; 65536];
        match self.socket.recv(&mut buf) {
            Ok(n) => {
                buf.truncate(n);
                self.seen.lock().unwrap().push(buf.clone());
                Ok(Some(buf))
            }
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }
}

/// Handshake message types (first per record) seen on the wire.
fn handshake_types(packets: &[Vec<u8>]) -> Vec<u8> {
    let mut types = Vec::new();
    for packet in packets {
        let mut off = 0;
        while off + 13 <= packet.len() {
            let content = packet[off];
            let len = u16::from_be_bytes([packet[off + 11], packet[off + 12]]) as usize;
            if content == 22 && off + 14 <= packet.len() {
                types.push(packet[off + 13]);
            }
            off += 13 + len;
        }
    }
    types
}

#[test]
fn openssl_server_ticket_resumption() {
    use dc_webrtc::dtls::{Dtls, DtlsConfig};
    if !have_openssl() {
        eprintln!("openssl CLI not available; skipping");
        return;
    }
    let (cert, key) = openssl_cert();

    let cfg = |fp: Option<String>| DtlsConfig {
        certificate: dc_webrtc::x509::Certificate::generate_self_signed("dc-webrtc"),
        expected_peer_fingerprint: fp,
        require_peer_certificate: false,
        session_resumption: true,
        session_ticket_key: None,
    };
    let wire = |port| {
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        (
            WireIo {
                socket: UdpSocket::bind("127.0.0.1:0").unwrap(),
                peer: format!("127.0.0.1:{port}").parse().unwrap(),
                seen: seen.clone(),
            },
            seen,
        )
    };

    // 1) Full handshake; OpenSSL must issue a session ticket.
    // Server startup under full-suite load can lose the port
    // race or start slowly; retry the pairing on a fresh port.
    let (mut server, server_log, port, mut conn1) = {
        let mut attempt = 0;
        loop {
            attempt += 1;
            let port = free_port();
            let mut server = Command::new("openssl")
                .args([
                    "s_server", "-accept", &port.to_string(), "-dtls1_2",
                    "-cert", cert.to_str().unwrap(), "-key", key.to_str().unwrap(),
                    "-state",
                ])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .expect("spawn openssl s_server");
            let server_log = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
            let pipes: [Box<dyn std::io::Read + Send>; 2] = [
                Box::new(server.stderr.take().unwrap()),
                Box::new(server.stdout.take().unwrap()),
            ];
            for mut pipe in pipes {
                let log = server_log.clone();
                std::thread::spawn(move || {
                    use std::io::Read as _;
                    let mut buf = [0u8; 4096];
                    loop {
                        match pipe.read(&mut buf) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => log
                                .lock()
                                .unwrap()
                                .push_str(&String::from_utf8_lossy(&buf[..n])),
                        }
                    }
                });
            }
            std::thread::sleep(Duration::from_millis(500));
            let (io1, _seen1) = wire(port);
            match Dtls::connect(io1, &cfg(None)) {
                Ok(conn1) => break (server, server_log, port, conn1),
                Err(e) => {
                    server.kill().ok();
                    if attempt >= 3 {
                        panic!("full handshake vs OpenSSL after 3 attempts: {e}");
                    }
                }
            }
        }
    };
    let session = conn1
        .take_session()
        .expect("OpenSSL issued a session ticket our client captured");
    let fp = conn1.peer_fingerprint().expect("peer fingerprint");
    // Exchange data so the server is fully in its data phase,
    // then close politely so it accepts connection 2.
    server.stdin.as_mut().unwrap().write_all(b"from-server\n").unwrap();
    let data = conn1
        .recv_app_timeout(Duration::from_secs(10))
        .expect("io ok")
        .expect("app data on first session");
    assert_eq!(data, b"from-server\n");
    conn1.close();
    // Read the server's close_notify answer (arrives as an alert)
    // so its accept loop releases the peer binding cleanly.
    let _ = conn1.recv_app_timeout(Duration::from_secs(2));
    drop(conn1);
    std::thread::sleep(Duration::from_millis(300));

    // 2) Resumed handshake: must succeed, keep identity, and be
    // abbreviated on the wire (no Certificate flight from OpenSSL).
    let (io2, seen2) = wire(port);
    let mut conn2 = Dtls::connect_resumed(io2, &cfg(Some(fp.clone())), &session)
        .expect("resumed handshake vs OpenSSL");
    assert!(conn2.was_resumed(), "handshake actually abbreviated");
    assert_eq!(conn2.peer_fingerprint().as_deref(), Some(fp.as_str()));
    let types = handshake_types(&seen2.lock().unwrap());
    assert!(types.contains(&2), "ServerHello seen: {types:?}");
    assert!(
        !types.contains(&11),
        "no Certificate flight in resumed handshake: {types:?}"
    );

    // 3) Application data flows on the resumed session, both
    // ways: ours lands on the server's stdout; a stdin line
    // comes back to us.
    conn2.send_app(b"from-client\n").unwrap();
    let mut data = None;
    for _ in 0..10 {
        if server_log.lock().unwrap().contains("from-client") {
            break;
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    assert!(
        server_log.lock().unwrap().contains("from-client"),
        "server received app data on resumed session"
    );
    for _ in 0..5 {
        server.stdin.as_mut().unwrap().write_all(b"resumed-ok\n").unwrap();
        if let Ok(Some(d)) = conn2.recv_app_timeout(Duration::from_secs(3)) {
            data = Some(d);
            break;
        }
    }
    assert_eq!(data.as_deref(), Some(b"resumed-ok\n".as_slice()), "app data on resumed session");
    server.kill().ok();
}

#[test]
fn openssl_client_ticket_resumption() {
    if !have_openssl() {
        eprintln!("openssl CLI not available; skipping");
        return;
    }
    // Rust server in resume mode: tickets on, accept loop.
    let port = free_port();
    let mut server = Command::new(echo_binary())
        .args(["server", &port.to_string(), "resume"])
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn dtls_echo server resume");
    let server_log = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    {
        let log = server_log.clone();
        let mut stderr = server.stderr.take().unwrap();
        std::thread::spawn(move || {
            use std::io::Read as _;
            let mut buf = [0u8; 4096];
            loop {
                match stderr.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => log.lock().unwrap().push_str(&String::from_utf8_lossy(&buf[..n])),
                }
            }
        });
    }
    let sess_file = std::env::temp_dir().join(format!("grpcdc-sess-{port}.pem"));
    let run_client = |extra: &[&str], line: &str| -> String {
        let mut args = vec!["s_client", "-dtls1_2", "-connect"];
        let target = format!("127.0.0.1:{port}");
        args.push(&target);
        args.extend_from_slice(extra);
        let mut client = Command::new("openssl")
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn openssl s_client");
        let out_buf = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
        {
            let out_buf = out_buf.clone();
            let mut stdout = client.stdout.take().unwrap();
            std::thread::spawn(move || {
                use std::io::Read as _;
                let mut buf = [0u8; 4096];
                loop {
                    match stdout.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => out_buf
                            .lock()
                            .unwrap()
                            .push_str(&String::from_utf8_lossy(&buf[..n])),
                    }
                }
            });
        }
        client.stdin.as_mut().unwrap().write_all(line.as_bytes()).unwrap();
        // Wait for the echo (handshake + round trip) up to 20s:
        // the server may need a moment to return to accept.
        let want = format!("echo:{}", line.trim());
        for _ in 0..80 {
            if out_buf.lock().unwrap().contains(&want) {
                break;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        // "Q" makes s_client shut down cleanly — only then does
        // it write -sess_out; killing it loses the session file.
        // (Ignore BrokenPipe: it may already have exited.)
        let _ = client.stdin.as_mut().unwrap().write_all(b"Q\n");
        drop(client.stdin.take());
        std::thread::sleep(Duration::from_millis(500));
        client.kill().ok();
        let _ = client.wait();
        let out = out_buf.lock().unwrap().clone();
        out
    };
    let wait_log = |needle: &str| {
        for _ in 0..40 {
            if server_log.lock().unwrap().contains(needle) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        false
    };
    assert!(wait_log("LISTENING"), "server listening");

    // 1) Full handshake; s_client saves the session (ticket).
    let sess = sess_file.to_str().unwrap().to_string();
    let out1 = run_client(&["-sess_out", &sess], "hello-one\n");
    assert!(out1.contains("echo:hello-one"), "first echo: {out1}");
    assert!(wait_log("resumed=false"), "full handshake logged: {}", server_log.lock().unwrap());

    // 2) Second s_client reuses the session: OpenSSL reports the
    // session Reused and our server reports an abbreviated
    // (resumed) handshake; echo still flows. Give the server a
    // moment to leave connection 1's echo loop (idle timeout)
    // and return to accept.
    std::thread::sleep(Duration::from_secs(4));
    let out2 = run_client(&["-sess_in", &sess], "hello-two\n");
    assert!(out2.contains("echo:hello-two"), "resumed echo: {out2}");
    assert!(out2.contains("Reused"), "OpenSSL reports session reuse: {out2}");
    assert!(wait_log("resumed=true"), "server resumed: {}", server_log.lock().unwrap());
    std::fs::remove_file(&sess_file).ok();
    server.kill().ok();
}

#[test]
fn openssl_client_rust_server() {
    if !have_openssl() {
        eprintln!("openssl CLI not available; skipping");
        return;
    }
    let (mut server, port) = start_server();

    let mut client = Command::new("openssl")
        .args(["s_client", "-dtls1_2", "-connect", &format!("127.0.0.1:{port}")])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn openssl s_client");
    client.stdin.as_mut().unwrap().write_all(b"hello-from-openssl\n").unwrap();
    // Give the echo time to arrive, then close so s_client exits.
    std::thread::sleep(Duration::from_secs(3));
    drop(client.stdin.take());
    std::thread::sleep(Duration::from_millis(500));
    client.kill().ok();
    let out = client.wait_with_output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("echo:hello-from-openssl"), "s_client output: {text}");
    server.kill().ok();
}
