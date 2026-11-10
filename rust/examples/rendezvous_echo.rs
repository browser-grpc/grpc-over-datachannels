//! Rendezvous Echo server harness for browser tests: serves
//! the generated Echo service on a fixed rendezvous endpoint
//! (grpc_dc::rendezvous::serve_rendezvous) and prints the
//! publishable descriptor as one JSON line on stdout.
//! Browsers dial it with rendezvousChannel — no signaling.
//! Used by browser-test/rendezvous_stacks.test.mjs.
//!
//!   cargo run --features webrtc --example rendezvous_echo

#[cfg(not(feature = "webrtc"))]
fn main() {
    eprintln!("rendezvous_echo needs --features webrtc");
}

#[cfg(feature = "webrtc")]
#[path = "../gen/echo_pb.rs"]
mod pb;

#[cfg(feature = "webrtc")]
#[path = "echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[cfg(feature = "webrtc")]
#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

#[cfg(feature = "webrtc")]
use futures_util::StreamExt;
#[cfg(feature = "webrtc")]
use grpc_dc::{CallCtx, RequestStream, ResponseStream, Status};
#[cfg(feature = "webrtc")]
use std::sync::Arc;
#[cfg(feature = "webrtc")]
use stub::{echo_service, Echo};

#[cfg(feature = "webrtc")]
struct EchoService;

#[cfg(feature = "webrtc")]
#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(&self, req: pb::EchoRequest, _ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        Ok(pb::EchoResponse { message: format!("echo: {}", req.message), index: 0, ..Default::default() })
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
        mut reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let mut parts = Vec::new();
        while let Some(req) = reqs.next().await {
            parts.push(req?.message);
        }
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32, ..Default::default() })
    }
    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream = futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut i)| async move {
            match reqs.next().await {
                Some(Ok(req)) => {
                    let r = pb::EchoResponse { message: req.message, index: i, ..Default::default() };
                    i += 1;
                    Some((Ok(r), (reqs, i)))
                }
                Some(Err(e)) => Some((Err(e), (reqs, i))),
                None => None,
            }
        });
        Ok(Box::pin(stream))
    }
}

/// This host's default-route IPv4, as a real deployment would
/// publish its public address.
#[cfg(feature = "webrtc")]
fn outward_ip() -> String {
    std::net::UdpSocket::bind("0.0.0.0:0")
        .and_then(|socket| {
            socket.connect("8.8.8.8:53")?;
            socket.local_addr()
        })
        .map(|addr| addr.ip().to_string())
        .unwrap_or_else(|_| "127.0.0.1".to_string())
}

#[cfg(feature = "webrtc")]
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listener = grpc_dc::rendezvous::serve_rendezvous(
        "0.0.0.0:0",
        vec![echo_service(Arc::new(EchoService))],
    )?;
    println!("{}", listener.descriptor(&outward_ip()).to_json());
    std::future::pending::<()>().await;
    Ok(())
}
