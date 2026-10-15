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

fn wait_for_stderr(child: &mut Child, needle: &str, timeout: Duration) -> String {
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
            Ok(text) if text.contains(&needle) => return text,
            Ok(_) => continue,
            Err(_) => panic!("timed out waiting for {needle:?}"),
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

#[test]
fn rust_client_rust_server_echo() {
    let port = free_port();
    let mut server = spawn_server(port);
    let _ = wait_for_stderr(&mut server, "LISTENING", Duration::from_secs(5));

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
    let port = free_port();
    let mut server = Command::new("openssl")
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

#[test]
fn openssl_client_rust_server() {
    if !have_openssl() {
        eprintln!("openssl CLI not available; skipping");
        return;
    }
    let port = free_port();
    let mut server = spawn_server(port);
    let _ = wait_for_stderr(&mut server, "LISTENING", Duration::from_secs(5));

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
