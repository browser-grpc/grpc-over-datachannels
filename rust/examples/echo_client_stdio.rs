//! Interop harness: the Rust echo client over stdio.
//!
//! JS tests spawn this binary against the JavaScript server, proving the
//! two runtimes interoperate on the same frames. Prints one line per call
//! shape and exits non-zero on any failure. The 4-byte length prefix only
//! frames messages on stdio; each unit is one grpc-dc frame.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::StreamExt;
use grpc_dc::{Channel, DcTransport, Status};
use std::sync::Arc;
use stub::EchoClient;
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

fn req(message: &str, count: i32) -> pb::EchoRequest {
    pb::EchoRequest { message: message.into(), count, delay_ms: 0, ..Default::default() }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let transport: Arc<dyn DcTransport> = Arc::new(StdioDc {
        tx: tokio::sync::Mutex::new(tokio::io::stdout()),
        rx: tokio::sync::Mutex::new(tokio::io::stdin()),
    });
    let client = EchoClient::new(Channel::new(transport));

    let unary = client.unary(req("hello", 0)).await?;
    eprintln!("unary={}", unary.message);

    let mut ticks = Vec::new();
    let mut stream = client.server_stream(req("tick", 3)).await?;
    while let Some(resp) = stream.next().await {
        let resp = resp?;
        ticks.push(format!("{}#{}", resp.message, resp.index));
    }
    eprintln!("server_stream={}", ticks.join(","));

    let reqs = futures_util::stream::iter([req("a", 0), req("b", 0), req("c", 0)]);
    let joined = client.client_stream(reqs).await?;
    eprintln!("client_stream={}", joined.message);

    let reqs = futures_util::stream::iter([req("x", 0), req("y", 0)]);
    let mut echoed = Vec::new();
    let mut bidi = client.bidi(reqs).await?;
    while let Some(resp) = bidi.next().await {
        echoed.push(resp?.message);
    }
    eprintln!("bidi={}", echoed.join(","));

    match client.unary(req("fail", 0)).await {
        Ok(_) => eprintln!("error_case=no error"),
        Err(st) => eprintln!("error_case={st}"),
    }

    let mut md = std::collections::HashMap::new();
    md.insert("x-echo".to_string(), "meta".to_string());
    let md_resp = client
        .unary_with_options(req("hello", 0), grpc_dc::CallOptions::default().metadata(md))
        .await?;
    eprintln!("metadata={}", md_resp.message);

    let mut slow = req("slow", 0);
    slow.delay_ms = 400;
    match client
        .unary_with_options(slow, grpc_dc::CallOptions::with_timeout(std::time::Duration::from_millis(50)))
        .await
    {
        Ok(_) => eprintln!("deadline=no error"),
        Err(st) => eprintln!("deadline={}", st.code as i32),
    }
    // The endpoint reader task parks on stdin forever; exit explicitly
    // rather than waiting for the runtime to drain blocking I/O.
    std::process::exit(0);
}
