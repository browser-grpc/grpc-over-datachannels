//! Interop server direction through the generated Rust
//! wrapper (no Node bridge): the official grpc-go
//! TestServiceClient speaks HTTP/2 to a tokio listener whose
//! streams are forwarded by grpc_dc::http2's
//! serve_h2_connection onto a grpc-dc Endpoint connected
//! (stdio) to the Rust interop TestService server.
//!
//! Skips when the oracle binaries are not built.

use async_trait::async_trait;
use bytes::Bytes;
use grpc_dc::endpoint::{Endpoint, StreamIdParity};
use grpc_dc::http2::proxy::serve_h2_connection;
use grpc_dc::{DcTransport, Status};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

/// Availability skip that hard-fails when GRPC_DC_REQUIRE_ORACLE
/// is set (the CI image sets it; its Dockerfile builds every
/// oracle, so a missing one there is build breakage).
#[track_caller]
fn oracle_skip(reason: &str) {
    if std::env::var_os("GRPC_DC_REQUIRE_ORACLE").is_some() {
        panic!("oracle required but unavailable: {reason}");
    }
    eprintln!("skip: {reason}");
}

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

struct KillOnDrop(Child);

impl Drop for KillOnDrop {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn official_go_client_through_wrapper_calls_rust_server() {
    let root = root();
    let server_bin = format!("{root}/rust/target/debug/examples/interop_server_stdio");
    let go_client = format!("{root}/oracle/go-interop/interop-client");
    if !std::path::Path::new(&server_bin).exists() || !std::path::Path::new(&go_client).exists() {
        oracle_skip("interop server/client not built");
        return;
    }
    let mut server = Command::new(&server_bin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn interop server");
    let transport: Arc<dyn DcTransport> = Arc::new(StdioDc {
        tx: Mutex::new(server.stdin.take().unwrap()),
        rx: Mutex::new(server.stdout.take().unwrap()),
    });
    let _server = KillOnDrop(server);
    let endpoint = Endpoint::new(transport, StreamIdParity::Odd);
    // The stdio transport blocks on read/write; run the endpoint
    // loop on a dedicated thread with its own runtime so it can
    // never starve the async workers the wrapper tasks need.
    {
        let ep = endpoint.clone();
        std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(ep.run());
        });
    }

    let port = free_port();
    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}")).await.unwrap();
    let ep = endpoint.clone();
    let accept_loop = tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((socket, _)) => {
                    let ep = ep.clone();
                    tokio::spawn(async move {
                        let _ = serve_h2_connection(socket, ep).await;
                    });
                }
                Err(_) => break,
            }
        }
    });

    for case in ["empty_unary", "large_unary", "ping_pong"] {
        let client_bin = go_client.clone();
        let output = tokio::task::spawn_blocking(move || {
            Command::new(&client_bin)
                .args([
                    "-server_host=127.0.0.1",
                    &format!("-server_port={port}"),
                    "-test_case",
                    case,
                ])
                .output()
                .unwrap_or_else(|e| panic!("spawn client for {case}: {e}"))
        })
        .await
        .unwrap();
        assert!(
            output.status.success(),
            "case {case} failed: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }
    accept_loop.abort();
}
