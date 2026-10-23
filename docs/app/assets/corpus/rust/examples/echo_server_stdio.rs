//! Interop harness: the Rust echo server over stdio.
//!
//! JS tests spawn this binary and drive it with the JavaScript client,
//! proving the two runtimes interoperate on the same frames. The 4-byte
//! length prefix exists only to frame messages on a byte stream (stdio);
//! each framed unit is exactly one DataChannel message (one grpc-dc
//! frame). Run via: `cargo run --example echo_server_stdio`

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{CallCtx, DcTransport, RequestStream, ResponseStream, Server, Status};
use std::sync::Arc;
use stub::{echo_service, Echo};
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

struct EchoService;

#[async_trait]
impl Echo for EchoService {
    async fn unary(&self, req: pb::EchoRequest, ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        if req.delay_ms > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(req.delay_ms as u64)).await;
        }
        if req.message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        let suffix =
            ctx.metadata.get("x-echo").map(|v| format!(" [{v}]")).unwrap_or_default();
        Ok(pb::EchoResponse { message: format!("echo: {}{}", req.message, suffix), index: 0, ..Default::default() })
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let responses = (0..req.count.max(0))
            .map(move |i| Ok(pb::EchoResponse { message: req.message.clone(), index: i, ..Default::default() }));
        Ok(Box::pin(futures_util::stream::iter(responses)))
    }

    async fn client_stream(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let parts: Vec<String> = reqs.map_ok(|r| r.message).try_collect().await?;
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32, ..Default::default() })
    }

    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream =
            futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut index)| async move {
                match reqs.next().await {
                    Some(Ok(req)) => {
                        let resp = pb::EchoResponse { message: req.message, index, ..Default::default() };
                        index += 1;
                        Some((Ok(resp), (reqs, index)))
                    }
                    Some(Err(e)) => Some((Err(e), (reqs, index))),
                    None => None,
                }
            });
        Ok(Box::pin(stream))
    }
}

#[tokio::main]
async fn main() {
    let transport: Arc<dyn DcTransport> = Arc::new(StdioDc {
        tx: tokio::sync::Mutex::new(tokio::io::stdout()),
        rx: tokio::sync::Mutex::new(tokio::io::stdin()),
    });
    Server::serve(transport, vec![echo_service(Arc::new(EchoService))]).await;
}
