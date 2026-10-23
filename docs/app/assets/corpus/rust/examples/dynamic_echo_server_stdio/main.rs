//! Interop harness: the dynamic (descriptor-driven) Rust echo server
//! over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
//! no generated stubs involved. Used by the oracle tests.
//!
//! The 4-byte length prefix exists only to frame messages on a byte
//! stream (stdio); each framed unit is exactly one DataChannel
//! message (one grpc-dc frame).

mod service;

use async_trait::async_trait;
use bytes::Bytes;
use grpc_dc::{dynamic_service, parse_descriptor_set, DcTransport, Server, Status};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct StdioDc {
    tx: tokio::sync::Mutex<tokio::io::Stdout>,
    rx: tokio::sync::Mutex<tokio::io::Stdin>,
}

#[async_trait]
impl DcTransport for StdioDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        let mut tx = self.tx.lock().await;
        tx.write_u32(msg.len() as u32)
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        tx.write_all(&msg)
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        tx.flush()
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        Ok(())
    }

    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut rx = self.rx.lock().await;
        let len = match rx.read_u32().await {
            Ok(n) => n as usize,
            Err(_) => return None,
        };
        let mut buf = vec![0u8; len];
        match rx.read_exact(&mut buf).await {
            Ok(_) => Some(Ok(Bytes::from(buf))),
            Err(e) => Some(Err(Status::unavailable(format!("stdio read: {e}")))),
        }
    }
}

fn locate_fixtures() -> std::path::PathBuf {
    let mut dir = Some(std::env::current_dir().expect("cwd"));
    while let Some(d) = dir {
        let direct = d.join("fixtures").join("echo_descriptor_set.bin");
        if direct.exists() {
            return direct;
        }
        let nested = d
            .join("grpc-over-datachannels")
            .join("fixtures")
            .join("echo_descriptor_set.bin");
        if nested.exists() {
            return nested;
        }
        dir = d.parent().map(|p| p.to_path_buf());
    }
    panic!("fixtures/echo_descriptor_set.bin not found");
}

#[tokio::main]
async fn main() {
    let bytes = std::fs::read(locate_fixtures()).expect("read descriptor fixture");
    let model = Arc::new(parse_descriptor_set(&bytes).expect("parse descriptor set"));
    let service = dynamic_service(&model, "echo.Echo", Arc::new(service::DynamicEchoService))
        .expect("build dynamic service");
    let transport: Arc<dyn DcTransport> = Arc::new(StdioDc {
        tx: tokio::sync::Mutex::new(tokio::io::stdout()),
        rx: tokio::sync::Mutex::new(tokio::io::stdin()),
    });
    Server::serve(transport, vec![service]).await;
}
