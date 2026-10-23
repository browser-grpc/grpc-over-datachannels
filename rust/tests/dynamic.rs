//! Dynamic (descriptor-driven) runtime: schemas consumed as data at
//! runtime, no generated stubs. Loopback plus the official grpc-java
//! oracle in both directions (the oracle is the runtime test bed).

#[path = "../examples/dynamic_echo_server_stdio/service.rs"]
mod service;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::StreamExt;
use grpc_dc::dynamic::{
    decode_generic, dynamic_service, encode_generic, parse_descriptor_set, DynamicClient,
    FileModel, GenericMessage,
};
use grpc_dc::{loopback_pair, Channel, DcTransport, Server, Status};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

const SERVICE: &str = "echo.Echo";

fn load_model() -> Arc<FileModel> {
    let path = format!(
        "{}/../fixtures/echo_descriptor_set.bin",
        env!("CARGO_MANIFEST_DIR")
    );
    let bytes = std::fs::read(&path).expect("descriptor fixture (run make generate)");
    Arc::new(parse_descriptor_set(&bytes).expect("parse descriptor set"))
}

fn req(model: &FileModel, message: &str, count: i64) -> GenericMessage {
    let mut m = GenericMessage::new();
    m.set(1, message.to_string());
    m.set(2, count);
    let _ = model;
    m
}

fn reqs(model: &FileModel, messages: &[String]) -> Vec<GenericMessage> {
    messages.iter().map(|m| req(model, m, 0)).collect()
}

fn unmsg(token: &str) -> String {
    if token == "-" {
        String::new()
    } else {
        token.to_string()
    }
}

struct Scenario {
    kind: String,
    messages: Vec<String>,
    count: i64,
    expect_status: Option<u32>,
}

fn load_scenarios() -> Vec<Scenario> {
    let path = format!("{}/../fixtures/oracle_scenarios.txt", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(path).expect("scenario fixture");
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let tokens: Vec<&str> = line.split_whitespace().collect();
        let kind = tokens[0].to_string();
        let mut messages: Vec<String> = Vec::new();
        let mut count: i64 = 0;
        let mut expect_status: Option<u32> = None;
        let mut i = 1;
        while i < tokens.len() {
            if tokens[i] == "EXPECT_STATUS" {
                expect_status = Some(tokens[i + 1].parse().unwrap());
                i += 2;
            } else if kind == "SERVER_STREAM" && i == tokens.len() - 1 {
                count = tokens[i].parse().unwrap();
                i += 1;
            } else {
                messages.push(tokens[i].to_string());
                i += 1;
            }
        }
        out.push(Scenario { kind, messages, count, expect_status });
    }
    out
}

async fn run_scenarios(client: &DynamicClient, model: &FileModel) -> Result<(), String> {
    for c in load_scenarios() {
        let line = format!("{} {}", c.kind, c.messages.join(" "));
        let messages: Vec<String> = c.messages.iter().map(|m| unmsg(m)).collect();
        match c.kind.as_str() {
            "UNARY" => match client.unary(SERVICE, "Unary", req(model, &messages[0], 0)).await {
                Ok(resp) => {
                    if c.expect_status.is_some() {
                        return Err(format!("{line}: expected status, got {resp:?}"));
                    }
                    if resp.get_string(1) != format!("echo: {}", messages[0])
                        || resp.get_i64(2) != 0
                    {
                        return Err(format!("{line}: resp = {resp:?}"));
                    }
                }
                Err(status) => {
                    if c.expect_status != Some(status.code as u32) {
                        return Err(format!("{line}: status = {status}"));
                    }
                }
            },
            "SERVER_STREAM" => {
                let mut stream = client
                    .server_stream(SERVICE, "ServerStream", req(model, &messages[0], c.count))
                    .await
                    .map_err(|s| format!("{line}: {s}"))?;
                let mut i: i64 = 0;
                while let Some(item) = stream.next().await {
                    let resp = item.map_err(|s| format!("{line}: {s}"))?;
                    if resp.get_string(1) != messages[0] || resp.get_i64(2) != i {
                        return Err(format!("{line}: resp = {resp:?} at {i}"));
                    }
                    i += 1;
                }
                if i != c.count {
                    return Err(format!("{line}: got {i} responses, want {}", c.count));
                }
            }
            "CLIENT_STREAM" => {
                let resp = client
                    .client_stream(SERVICE, "ClientStream", reqs(model, &messages))
                    .await
                    .map_err(|s| format!("{line}: {s}"))?;
                if resp.get_string(1) != messages.join("+")
                    || resp.get_i64(2) != messages.len() as i64
                {
                    return Err(format!("{line}: resp = {resp:?}"));
                }
            }
            "BIDI" => {
                let mut stream = client
                    .bidi(SERVICE, "Bidi", reqs(model, &messages))
                    .await
                    .map_err(|s| format!("{line}: {s}"))?;
                let mut i: i64 = 0;
                while let Some(item) = stream.next().await {
                    let resp = item.map_err(|s| format!("{line}: {s}"))?;
                    if i as usize >= messages.len()
                        || resp.get_string(1) != messages[i as usize]
                        || resp.get_i64(2) != i
                    {
                        return Err(format!("{line}: resp = {resp:?} at {i}"));
                    }
                    i += 1;
                }
                if i as usize != messages.len() {
                    return Err(format!("{line}: got {i} responses, want {}", messages.len()));
                }
            }
            other => return Err(format!("unknown scenario kind: {other}")),
        }
    }
    Ok(())
}

#[test]
fn generic_codec_and_unknown_field_retention() {
    let model = load_model();
    let request_type = model.message(".echo.EchoRequest").unwrap();
    // message="hi", count=2, then unknown fields 99 (varint 42) and
    // 100 (length-delimited "x"): retained raw and re-emitted verbatim.
    let payload: &[u8] = &[
        0x0a, 0x02, b'h', b'i', 0x10, 0x02, 0x98, 0x06, 0x2a, 0xa2, 0x06, 0x01, b'x',
    ];
    let decoded = decode_generic(&request_type, payload, &model).unwrap();
    assert_eq!(decoded.unknown.len(), 2, "unknown retained: {decoded:?}");
    assert_eq!(encode_generic(&request_type, &decoded, &model).unwrap(), payload);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dynamic_loopback() {
    let model = load_model();
    let (a, b) = loopback_pair();
    let service = dynamic_service(&model, SERVICE, Arc::new(service::DynamicEchoService)).unwrap();
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![service]));
    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    let client = DynamicClient::new(Channel::new(client_transport), model.clone());
    let result = run_scenarios(&client, &model).await;
    assert!(result.is_ok(), "{}", result.unwrap_err());
}

// -- oracle harness (mirrors tests/oracle.rs) -------------------------------

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
async fn dynamic_oracle_rust_client_calls_official_server() {
    let Some(cp) = java_classpath() else {
        eprintln!("skip: java oracle not built");
        return;
    };
    let model = load_model();
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
    let client = DynamicClient::new(Channel::new(transport), model.clone());
    let result = run_scenarios(&client, &model).await;
    let _ = bridge.kill();
    let _ = java.kill();
    assert!(result.is_ok(), "{}", result.unwrap_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dynamic_oracle_official_client_calls_rust_server() {
    let Some(cp) = java_classpath() else {
        eprintln!("skip: java oracle not built");
        return;
    };
    let root = format!("{}/..", env!("CARGO_MANIFEST_DIR"));
    let server_bin = format!("{root}/rust/target/debug/examples/dynamic_echo_server_stdio");
    if !std::path::Path::new(&server_bin).exists() {
        eprintln!("skip: dynamic_echo_server_stdio not built");
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
