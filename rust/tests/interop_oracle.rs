//! Interop oracle: the generated Rust TestService client and
//! server graded against the reference implementations through
//! the bridge, mirroring the JS/Go/Python interop suites.
//!
//! Client direction: Rust client -> bridge (dc-to-http2) ->
//! reference grpc-go TestService server (with ORCA service):
//! empty/large unary, orca_per_rpc, orca_oob.
//! Server direction: official grpc-java client (and the
//! grpc-go client for ORCA, which the Java client cannot
//! grade) -> bridge (http2-to-dc) -> Rust interop server:
//! the four compressed cases plus sanity cases.
//!
//! Skips when the oracle binaries are not built (Dockerfile.ci
//! builds them).

#[path = "../examples/interop_server_stdio/pb_glue.rs"]
mod pb;

#[path = "../gen/test_grpc_dc.rs"]
mod test_stub;

#[path = "../gen/orca_grpc_dc.rs"]
mod orca_stub;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{Channel, DcTransport, Status};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use test_stub::TestServiceClient;

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

fn root() -> String {
    format!("{}/..", env!("CARGO_MANIFEST_DIR"))
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn wait_port(port: u16, what: &str) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return;
        }
        assert!(std::time::Instant::now() < deadline, "{what} did not start");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

struct KillOnDrop(Child);

impl Drop for KillOnDrop {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Spawn the reference Go TestService server (with the ORCA
/// service) and a dc-to-http2 bridge; returns the Rust clients.
fn go_server_clients() -> Option<(KillOnDrop, KillOnDrop, TestServiceClient, orca_stub::OpenRcaServiceClient)> {
    let root = root();
    let binary = format!("{root}/oracle/go-interop/interop-server");
    if !std::path::Path::new(&binary).exists() {
        eprintln!("skip: go interop server not built (oracle/go-interop)");
        return None;
    }
    let port = free_port();
    let server = Command::new(&binary)
        .args(["-port", &port.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn go interop server");
    wait_port(port, "go interop server");
    let mut bridge = Command::new("node")
        .args([
            &format!("{root}/oracle/bridge.mjs"),
            "dc-to-http2",
            "--grpc",
            &format!("127.0.0.1:{port}"),
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
    let channel = Channel::new(transport);
    Some((
        KillOnDrop(server),
        KillOnDrop(bridge),
        TestServiceClient::new(channel.clone()),
        orca_stub::OpenRcaServiceClient::new(channel),
    ))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rust_client_calls_go_reference_server() {
    let Some((_server, _bridge, client, _orca_client)) = go_server_clients() else {
        return;
    };

    let empty = client.empty_call(pb::Empty::default()).await.unwrap();
    assert_eq!(empty, pb::Empty::default());

    let large = client
        .unary_call(pb::SimpleRequest {
            response_size: 314_159,
            payload: Some(Box::new(pb::Payload {
                body: vec![0u8; 271_828],
                ..Default::default()
            })),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(large.payload.unwrap().body.len(), 314_159);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rust_client_orca_against_go_reference_server() {
    let Some((_server, _bridge, client, orca_client)) = go_server_clients() else {
        return;
    };

    // orca_per_rpc: the per-query report comes back as the
    // endpoint-load-metrics-bin trailer.
    let trailers = Arc::new(Mutex::new(HashMap::new()));
    let options = grpc_dc::CallOptions::new().capture_trailers(trailers.clone());
    let mut request_cost = HashMap::new();
    request_cost.insert("cost".to_string(), 3456.32);
    let mut utilization = HashMap::new();
    utilization.insert("util".to_string(), 0.30499);
    client
        .unary_call_with_options(
            pb::SimpleRequest {
                response_size: 1,
                orca_per_query_report: Some(Box::new(pb::TestOrcaReport {
                    cpu_utilization: 0.8210,
                    memory_utilization: 0.5847,
                    request_cost,
                    utilization,
                    ..Default::default()
                })),
                ..Default::default()
            },
            options,
        )
        .await
        .unwrap();
    let encoded = trailers
        .lock()
        .unwrap()
        .get("endpoint-load-metrics-bin")
        .expect("endpoint-load-metrics-bin trailer")
        .clone();
    let report = pb::OrcaLoadReport::decode(&pb::base64_decode(&encoded).unwrap()).unwrap();
    assert!((report.cpu_utilization - 0.8210).abs() < 1e-9);
    assert!((report.mem_utilization - 0.5847).abs() < 1e-9);
    assert!((report.request_cost["cost"] - 3456.32).abs() < 1e-9);
    assert!((report.utilization["util"] - 0.30499).abs() < 1e-9);

    // orca_oob: feed the shared state via FullDuplexCall, then
    // read it back on StreamCoreMetrics.
    let mut oob_util = HashMap::new();
    oob_util.insert("util".to_string(), 0.5);
    let feed = futures_util::stream::once(async move {
        pb::StreamingOutputCallRequest {
            orca_oob_report: Some(Box::new(pb::TestOrcaReport {
                cpu_utilization: 0.9,
                memory_utilization: 0.85,
                utilization: oob_util,
                ..Default::default()
            })),
            ..Default::default()
        }
    });
    let responses = client.full_duplex_call(feed).await.unwrap();
    let drained: Vec<_> = responses.collect().await;
    assert!(drained.iter().all(|r| r.is_ok()), "feed failed: {drained:?}");

    let mut stream = orca_client
        .stream_core_metrics(pb::OrcaLoadReportRequest::default())
        .await
        .unwrap();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
    loop {
        let report = tokio::time::timeout_at(deadline, stream.next())
            .await
            .expect("oob report within 15s")
            .expect("oob stream open")
            .unwrap();
        if (report.cpu_utilization - 0.9).abs() < 1e-9
            && (report.mem_utilization - 0.85).abs() < 1e-9
            && (report.utilization["util"] - 0.5).abs() < 1e-9
        {
            break;
        }
    }
    // Dropping the stream here cancels it server-side (the
    // reference server stops its 2s OOB ticker for this call).
    drop(stream);
}

fn java_classpath() -> Option<String> {
    let root = root();
    let target = format!("{root}/oracle/java/target");
    let cp_file = format!("{target}/cp.txt");
    if !std::path::Path::new(&cp_file).exists()
        || !std::path::Path::new(&format!("{target}/classes")).is_dir()
    {
        eprintln!("skip: java oracle not built (cd oracle/java && mvn package)");
        return None;
    }
    let cp = std::fs::read_to_string(cp_file).unwrap();
    Some(format!("{target}/classes:{}", cp.trim()))
}

fn run_case(client_cmd: &[&str], case: &str) {
    let mut cmd = Command::new(client_cmd[0]);
    cmd.args(&client_cmd[1..]);
    // The Java client spells it --test_case=, the Go client -test_case=.
    if client_cmd[0] == "java" {
        cmd.arg(format!("--test_case={case}"));
    } else {
        cmd.arg("-test_case").arg(case);
        if case.starts_with("orca") {
            // Upstream runs the ORCA cases through the test LB
            // policy that surfaces per-RPC load reports.
            cmd.arg("-service_config_json")
                .arg("{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}");
        }
    }
    let output = cmd
        .output()
        .unwrap_or_else(|e| panic!("spawn client for {case}: {e}"));
    assert!(
        output.status.success(),
        "case {case} failed: {}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn official_clients_call_rust_server() {
    let root = root();
    let server_bin = format!("{root}/rust/target/debug/examples/interop_server_stdio");
    if !std::path::Path::new(&server_bin).exists() {
        eprintln!("skip: interop_server_stdio not built");
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
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn bridge");
    let _bridge = KillOnDrop(bridge);
    wait_port(port, "bridge http2-to-dc");

    if let Some(cp) = java_classpath() {
        let port_arg = format!("--server_port={port}");
        let java: Vec<&str> = vec![
            "java",
            "-cp",
            &cp,
            "io.grpc.testing.integration.TestServiceClient",
            "--server_host=127.0.0.1",
            &port_arg,
            "--use_tls=false",
        ];
        let java_refs = java;
        for case in [
            "empty_unary",
            "large_unary",
            "ping_pong",
            "client_compressed_unary",
            "client_compressed_streaming",
            "server_compressed_unary",
            "server_compressed_streaming",
        ] {
            run_case(&java_refs, case);
        }
    }

    // ORCA server direction is graded with the grpc-go client
    // (the Java client's ORCA report capture does not work
    // against any server; see oracle/interop/README.md).
    let go_client = format!("{root}/oracle/go-interop/interop-client");
    if std::path::Path::new(&go_client).exists() {
        let port_arg = format!("-server_port={port}");
        let go: Vec<&str> = vec![go_client.as_str(), "-server_host=127.0.0.1", &port_arg];
        let go_refs = go;
        for case in ["orca_per_rpc", "orca_oob"] {
            run_case(&go_refs, case);
        }
    }
}
