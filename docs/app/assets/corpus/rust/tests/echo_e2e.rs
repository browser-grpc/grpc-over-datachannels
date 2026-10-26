//! End-to-end over the loopback transport, using the protoc-generated
//! stub (`rust/gen/echo_grpc_dc.rs`) and the generated messages.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{
    loopback_pair, CallCtx, Channel, Code, DcTransport, Message, Metadata, RequestStream,
    ResponseStream, Server, Status,
};
use std::sync::Arc;
use stub::{echo_service, Echo, EchoClient};

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(&self, req: pb::EchoRequest, ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        if req.message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        let suffix = ctx.metadata.get("x-echo").map(|v| format!(" [{v}]")).unwrap_or_default();
        if let Some(v) = ctx.metadata.get("x-echo") {
            let mut h = Metadata::new();
            h.insert("x-echo-header".into(), v.clone());
            ctx.set_headers(h);
            let mut t = Metadata::new();
            t.insert("x-echo-trailer".into(), v.clone());
            ctx.set_trailers(t);
        }
        Ok(pb::EchoResponse { message: format!("echo: {}{}", req.message, suffix), index: 0 , ..Default::default() })
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        if req.message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        let responses =
            (0..req.count.max(0)).map(move |i| Ok(pb::EchoResponse { message: req.message.clone(), index: i , ..Default::default() }));
        Ok(Box::pin(futures_util::stream::iter(responses)))
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
        let stream = futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut index)| async move {
            match reqs.next().await {
                Some(Ok(req)) => {
                    let resp = pb::EchoResponse { message: req.message, index , ..Default::default() };
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

fn req(message: &str, count: i32) -> pb::EchoRequest {
    pb::EchoRequest { message: message.into(), count, delay_ms: 0, ..Default::default() }
}

async fn setup() -> EchoClient {
    let (a, b) = loopback_pair();
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![echo_service(Arc::new(EchoService))]));
    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    EchoClient::new(Channel::new(client_transport))
}

#[test]
fn protobuf_golden_bytes() {
    let encoded = req("hi", 2).encode();
    assert_eq!(encoded, vec![0x0a, 0x02, b'h', b'i', 0x10, 0x02]);
    let decoded = pb::EchoRequest::decode(&encoded).unwrap();
    assert_eq!(decoded, req("hi", 2));
}

#[tokio::test]
async fn unary_trailers_round_trip() {
    let client = setup().await;
    let headers = Arc::new(std::sync::Mutex::new(Metadata::new()));
    let trailers = Arc::new(std::sync::Mutex::new(Metadata::new()));
    let mut md = Metadata::new();
    md.insert("x-echo".into(), "meta".into());
    let options = grpc_dc::CallOptions::new()
        .metadata(md)
        .capture_headers(headers.clone())
        .capture_trailers(trailers.clone());
    let resp = client.unary_with_options(req("hello", 0), options).await.unwrap();
    assert_eq!(resp.message, "echo: hello [meta]");
    assert_eq!(
        headers.lock().unwrap().get("x-echo-header").map(|v| v.as_str()),
        Some("meta")
    );
    assert_eq!(
        trailers.lock().unwrap().get("x-echo-trailer").map(|v| v.as_str()),
        Some("meta")
    );
}

#[tokio::test]
async fn unary_round_trip() {
    let client = setup().await;
    let resp = client.unary(req("hello", 0)).await.unwrap();
    assert_eq!(resp.message, "echo: hello");
}

#[tokio::test]
async fn server_streaming() {
    let client = setup().await;
    let mut stream = client.server_stream(req("tick", 3)).await.unwrap();
    let mut got = Vec::new();
    while let Some(item) = stream.next().await {
        got.push(item.unwrap());
    }
    assert_eq!(got.len(), 3);
    assert_eq!(got[2].index, 2);
    assert!(got.iter().all(|r| r.message == "tick"));
}

#[tokio::test]
async fn client_streaming() {
    let client = setup().await;
    let reqs = futures_util::stream::iter(["a", "b", "c"].into_iter().map(|m| req(m, 0)));
    let resp = client.client_stream(reqs).await.unwrap();
    assert_eq!(resp.message, "a+b+c");
    assert_eq!(resp.index, 3);
}

#[tokio::test]
async fn bidi_streaming() {
    let client = setup().await;
    let reqs = futures_util::stream::iter(["x", "y", "z"].into_iter().map(|m| req(m, 0)));
    let mut stream = client.bidi(reqs).await.unwrap();
    let mut got = Vec::new();
    while let Some(item) = stream.next().await {
        got.push(item.unwrap().message);
    }
    assert_eq!(got, vec!["x", "y", "z"]);
}

#[tokio::test]
async fn handler_error_propagates_as_status() {
    let client = setup().await;
    let err = client.unary(req("fail", 0)).await.unwrap_err();
    assert_eq!(err.code, Code::InvalidArgument);
    assert!(err.message.contains("asked to fail"), "got: {err}");

    let mut stream = client.bidi(futures_util::stream::iter([req("a", 0)])).await.unwrap();
    assert!(stream.next().await.unwrap().is_ok()); // sanity: stream itself works

    let client2 = setup().await;
    let err = client2.server_stream(req("fail", 1)).await.unwrap().next().await.unwrap().unwrap_err();
    assert_eq!(err.code, Code::InvalidArgument);
}

#[tokio::test]
async fn unknown_method_is_unimplemented() {
    let (a, b) = loopback_pair();
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![echo_service(Arc::new(EchoService))]));
    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    let channel = Channel::new(client_transport);
    let err: Status = channel
        .unary::<pb::EchoRequest, pb::EchoResponse>("/echo.Echo/Nope", req("hi", 0))
        .await
        .unwrap_err();
    assert_eq!(err.code, Code::Unimplemented);
}

struct CountingService {
    produced: Arc<std::sync::atomic::AtomicU32>,
}

#[grpc_dc::async_trait]
impl Echo for CountingService {
    async fn unary(&self, req: pb::EchoRequest, _ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        Ok(pb::EchoResponse { message: req.message, index: 0, ..Default::default() })
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let produced = self.produced.clone();
        let stream = futures_util::stream::unfold(0i32, move |i| {
            let produced = produced.clone();
            async move {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                produced.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Some((Ok(pb::EchoResponse { message: "tick".into(), index: i, ..Default::default() }), i + 1))
            }
        });
        Ok(Box::pin(stream))
    }

    async fn client_stream(
        &self,
        _reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        Err(Status::unimplemented("unused"))
    }

    async fn bidi(
        &self,
        _reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        Err(Status::unimplemented("unused"))
    }
}

#[tokio::test]
async fn dropping_response_stream_cancels_server_production() {
    let produced = Arc::new(std::sync::atomic::AtomicU32::new(0));
    let (a, b) = loopback_pair();
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(
        server_transport,
        vec![echo_service(Arc::new(CountingService { produced: produced.clone() }))],
    ));
    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    let client = EchoClient::new(Channel::new(client_transport));

    let mut stream = client.server_stream(req("tick", 1000)).await.unwrap();
    let first = stream.next().await.unwrap().unwrap();
    assert_eq!(first.index, 0);
    // Dropping the stream mid-call must RST it: the server
    // stops producing instead of streaming into the void.
    drop(stream);
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let settled = produced.load(std::sync::atomic::Ordering::SeqCst);
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert_eq!(produced.load(std::sync::atomic::Ordering::SeqCst), settled);
    assert!(settled < 100, "server kept producing ({settled})");
}

#[tokio::test]
async fn concurrent_unary_calls() {
    let client = Arc::new(setup().await);
    let mut handles = Vec::new();
    for i in 0..16 {
        let client = client.clone();
        handles.push(tokio::spawn(async move {
            client.unary(req(&format!("m{i}"), 0)).await.unwrap().message
        }));
    }
    for (i, h) in handles.into_iter().enumerate() {
        assert_eq!(h.await.unwrap(), format!("echo: m{i}"));
    }
}
