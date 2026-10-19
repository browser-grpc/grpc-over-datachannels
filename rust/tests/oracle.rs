//! Oracle tests: official grpc-java, bridged over TCP<->DataChannel by
//! ../oracle/bridge.mjs, must agree with the Rust runtime on every case
//! of the generated scenario driver (oracle_scenarios.rs, stamped by
//! racket/oracle-gen.rkt). Skips when the Java oracle or Node bridge
//! are unavailable (Dockerfile.ci provides both).

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

#[path = "oracle_scenarios/mod.rs"]
mod oracle_scenarios;

use async_trait::async_trait;
use bytes::Bytes;
use grpc_dc::{Channel, DcTransport, Status};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use stub::EchoClient;

struct StdioDc {
    tx: Mutex<std::process::ChildStdin>,
    rx: Mutex<std::process::ChildStdout>,
}

#[async_trait]
impl DcTransport for StdioDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        let mut tx = self.tx.lock().unwrap();
        tx.write_all(&(msg.len() as u32).to_be_bytes())
            .and_then(|_| tx.write_all(&msg))
            .and_then(|_| tx.flush())
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))
    }

    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut rx = self.rx.lock().unwrap();
        let mut len = [0u8; 4];
        rx.read_exact(&mut len).ok()?;
        let mut buf = vec![0u8; u32::from_be_bytes(len) as usize];
        match rx.read_exact(&mut buf) {
            Ok(()) => Some(Ok(Bytes::from(buf))),
            Err(e) => Some(Err(Status::unavailable(format!("stdio read: {e}")))),
        }
    }
}

fn java_classpath() -> Option<String> {
    let dir = format!("{}/../oracle/java/target", env!("CARGO_MANIFEST_DIR"));
    let cp = std::fs::read_to_string(format!("{dir}/cp.txt")).ok()?;
    if !std::path::Path::new(&format!("{dir}/classes")).exists() {
        return None;
    }
    Some(format!("{dir}/classes:{}", cp.trim()))
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn spawn_java_server(cp: &str, port: u16) -> Child {
    let mut child = Command::new("java")
        .args(["-cp", cp, "dc.oracle.OracleServer", &port.to_string()])
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn java oracle server");
    let stderr = child.stderr.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines() {
            if line.map(|l| l.contains("READY")).unwrap_or(false) {
                let _ = tx.send(());
                break;
            }
        }
    });
    rx.recv_timeout(std::time::Duration::from_secs(60))
        .expect("java oracle server did not become ready");
    child
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn oracle_rust_client_calls_official_server() {
    let Some(cp) = java_classpath() else {
        eprintln!("skip: java oracle not built");
        return;
    };
    let java_port = free_port();
    let mut java = spawn_java_server(&cp, java_port);

    let root = format!("{}/..", env!("CARGO_MANIFEST_DIR"));
    let mut bridge = Command::new("node")
        .args([
            &format!("{root}/oracle/bridge.mjs"),
            "dc-to-http2",
            "--grpc",
            &format!("127.0.0.1:{java_port}"),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn bridge");
    let transport: Arc<dyn DcTransport> = Arc::new(StdioDc {
        tx: Mutex::new(bridge.stdin.take().unwrap()),
        rx: Mutex::new(bridge.stdout.take().unwrap()),
    });
    let client = EchoClient::new(Channel::new(transport));
    let result = oracle_scenarios::run_scenarios(&client).await;
    let _ = bridge.kill();
    let _ = java.kill();
    assert!(result.is_ok(), "{}", result.unwrap_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn oracle_official_client_calls_rust_server() {
    let Some(cp) = java_classpath() else {
        eprintln!("skip: java oracle not built");
        return;
    };
    let root = format!("{}/..", env!("CARGO_MANIFEST_DIR"));
    let server_bin = format!("{root}/rust/target/debug/examples/echo_server_stdio");
    if !std::path::Path::new(&server_bin).exists() {
        eprintln!("skip: echo_server_stdio not built");
        return;
    }
    let port = free_port();
    let mut bridge = Command::new("node")
        .args([
            &format!("{root}/oracle/bridge.mjs"),
            "http2-to-dc",
            "--port",
            &port.to_string(),
            "--target-cmd",
            &server_bin,
        ])
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn bridge");
    // The Java client retries until the bridge listens.
    let output = Command::new("java")
        .args([
            "-cp",
            &cp,
            "dc.oracle.OracleClient",
            &port.to_string(),
            &format!("{root}/fixtures/oracle_scenarios.txt"),
        ])
        .output()
        .expect("run oracle client");
    let _ = bridge.kill();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success() && stdout.contains("ORACLE CLIENT: ALL OK"),
        "oracle client failed:\n{stdout}\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
