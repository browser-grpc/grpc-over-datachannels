//! Deadlines: CallOptions timeout propagates as grpc-timeout and is
//! enforced while awaiting responses (DEADLINE_EXCEEDED + RST);
//! CallCtx exposes the remaining budget to handlers.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{
    loopback_pair, CallCtx, CallOptions, Channel, Code, DcTransport, RequestStream,
    ResponseStream, Server, Status,
};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use stub::{echo_service, Echo, EchoClient};

#[derive(Default)]
struct SlowEcho {
    seen: Mutex<Option<std::sync::Arc<Mutex<Option<CallCtx>>>>>,
}

#[grpc_dc::async_trait]
impl Echo for SlowEcho {
    async fn unary(&self, req: pb::EchoRequest, ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        if let Some(slot) = self.seen.lock().unwrap().clone() {
            *slot.lock().unwrap() = Some(ctx.clone());
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
        Ok(pb::EchoResponse { message: format!("echo: {}", req.message), index: 0 , ..Default::default() })
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream = futures_util::stream::unfold(0i32, move |i| {
            let message = req.message.clone();
            let count = req.count;
            async move {
                if i >= count.max(0) {
                    return None;
                }
                if i > 0 {
                    tokio::time::sleep(Duration::from_millis(300)).await;
                }
                Some((Ok(pb::EchoResponse { message, index: i , ..Default::default() }), i + 1))
            }
        });
        Ok(Box::pin(stream))
    }

    async fn client_stream(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let parts: Vec<String> = reqs.map_ok(|r| r.message).try_collect().await?;
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32 , ..Default::default() })
    }

    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let mut index = 0i32;
        Ok(Box::pin(reqs.map_ok(move |r| {
            let resp = pb::EchoResponse { message: r.message, index , ..Default::default() };
            index += 1;
            resp
        })))
    }
}

async fn setup() -> (EchoClient, std::sync::Arc<Mutex<Option<CallCtx>>>) {
    let (client_transport, server_transport) = loopback_pair();
    let seen: std::sync::Arc<Mutex<Option<CallCtx>>> = Arc::new(Mutex::new(None));
    let svc = SlowEcho { seen: Mutex::new(Some(seen.clone())) };
    tokio::spawn(Server::serve(
        Arc::new(server_transport) as Arc<dyn DcTransport>,
        vec![echo_service(Arc::new(svc))],
    ));
    (EchoClient::new(Channel::new(Arc::new(client_transport) as Arc<dyn DcTransport>)), seen)
}

fn req(message: &str, count: i32) -> pb::EchoRequest {
    pb::EchoRequest { message: message.to_string(), count, delay_ms: 0, ..Default::default() }
}

#[test]
fn timeout_codec_round_trip() {
    for d in [Duration::from_millis(250), Duration::from_secs(90)] {
        assert_eq!(grpc_dc::codec::parse_timeout(&grpc_dc::codec::encode_timeout(d)), Some(d));
    }
    assert_eq!(grpc_dc::codec::parse_timeout("10x"), None);
}

#[tokio::test]
async fn unary_deadline_exceeded_and_ctx_budget() {
    let (client, seen) = setup().await;
    let start = std::time::Instant::now();
    let err = client
        .unary_with_options(req("hello", 0), CallOptions::with_timeout(Duration::from_millis(50)))
        .await
        .unwrap_err();
    assert_eq!(err.code, Code::DeadlineExceeded);
    assert!(start.elapsed() < Duration::from_millis(350), "took {:?}", start.elapsed());
    let ctx = seen.lock().unwrap().clone().expect("handler ran");
    assert!(ctx.metadata.contains_key("grpc-timeout"));
    assert!(ctx.deadline.is_some());
    assert!(ctx.time_remaining().is_some());
}

#[tokio::test]
async fn server_stream_deadline_mid_stream() {
    let (client, _seen) = setup().await;
    let mut stream = client
        .server_stream_with_options(
            req("tick", 5),
            CallOptions::with_timeout(Duration::from_millis(150)),
        )
        .await
        .unwrap();
    let first = stream.next().await.unwrap().unwrap();
    assert_eq!(first.index, 0);
    let err = stream.next().await.unwrap().unwrap_err();
    assert_eq!(err.code, Code::DeadlineExceeded);
}

#[tokio::test]
async fn generous_timeout_succeeds() {
    let (client, _seen) = setup().await;
    let resp = client
        .client_stream_with_options(
            futures_util::stream::iter(vec![req("a", 0), req("b", 0)]),
            CallOptions::with_timeout(Duration::from_secs(5)),
        )
        .await
        .unwrap();
    assert_eq!(resp.message, "a+b");
}
