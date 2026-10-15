//! Echo demo: all four gRPC method shapes over one in-memory data
//! channel. `cargo run --example echo_demo`
//!
//! The stub in `rust/gen/` came from the generated protoc plugin; the
//! messages in `pb.rs` are hand-written (see that file for why).

mod pb;

#[path = "../../gen/echo_grpc_dc.rs"]
mod stub;

use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{loopback_pair, CallCtx, Channel, DcTransport, RequestStream, ResponseStream, Server, Status};
use std::sync::Arc;
use stub::{echo_service, Echo, EchoClient};

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(
        &self,
        req: pb::EchoRequest,
        ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        if req.message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        let suffix = ctx
            .metadata
            .get("x-echo")
            .map(|v| format!(" [{v}]"))
            .unwrap_or_default();
        Ok(pb::EchoResponse { message: format!("echo: {}{}", req.message, suffix), index: 0 })
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let responses = (0..req.count.max(0)).map(move |i| {
            Ok(pb::EchoResponse { message: req.message.clone(), index: i })
        });
        Ok(Box::pin(futures_util::stream::iter(responses)))
    }

    async fn client_stream(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let parts: Vec<String> = reqs.map_ok(|r| r.message).try_collect().await?;
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32 })
    }

    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream = futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut index)| async move {
            match reqs.next().await {
                Some(Ok(req)) => {
                    let resp = pb::EchoResponse { message: req.message, index };
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
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let (a, b) = loopback_pair();
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![echo_service(Arc::new(EchoService))]));

    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    let client = EchoClient::new(Channel::new(client_transport));

    let unary = client
        .unary(pb::EchoRequest { message: "hello".into(), count: 0, delay_ms: 0 })
        .await?;
    println!("unary        -> {} (index {})", unary.message, unary.index);

    let mut stream = client
        .server_stream(pb::EchoRequest { message: "tick".into(), count: 3, delay_ms: 0 })
        .await?;
    let mut ticks = Vec::new();
    while let Some(resp) = stream.next().await {
        let resp = resp?;
        ticks.push(format!("{}#{}", resp.message, resp.index));
    }
    println!("server-stream-> {}", ticks.join(", "));

    let reqs = futures_util::stream::iter(["a", "b", "c"].into_iter().map(|m| pb::EchoRequest {
        message: m.into(),
        count: 0,
        delay_ms: 0,
    }));
    let joined = client.client_stream(reqs).await?;
    println!("client-stream-> {} ({} parts)", joined.message, joined.index);

    let reqs = futures_util::stream::iter(["x", "y"].into_iter().map(|m| pb::EchoRequest {
        message: m.into(),
        count: 0,
        delay_ms: 0,
    }));
    let mut bidi = client.bidi(reqs).await?;
    let mut echoed = Vec::new();
    while let Some(resp) = bidi.next().await {
        echoed.push(resp?.message);
    }
    println!("bidi         -> {}", echoed.join(", "));
    Ok(())
}
