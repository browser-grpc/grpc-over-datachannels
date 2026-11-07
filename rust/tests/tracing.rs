//! Tracing: a registered Tracer observes one shared trace id
//! with the server span parented to the client span, over the
//! loopback transport with the protoc-generated stub.

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

#[derive(Default)]
struct Recorder {
    starts: std::sync::Mutex<Vec<(String, String, String, String, String)>>,
    ends: std::sync::Mutex<Vec<(String, String, String, String, String, f64)>>,
}

impl grpc_dc::status::Tracer for Recorder {
    fn on_start(&self, kind: &str, method: &str, trace_id: &str, span_id: &str, parent_span_id: &str) {
        self.starts.lock().unwrap().push((kind.into(), method.into(), trace_id.into(), span_id.into(), parent_span_id.into()));
    }
    fn on_end(&self, kind: &str, method: &str, trace_id: &str, span_id: &str, status: &str, duration_ms: f64) {
        self.ends.lock().unwrap().push((kind.into(), method.into(), trace_id.into(), span_id.into(), status.into(), duration_ms));
    }
}

#[tokio::test]
async fn tracing_parented_spans() {
    let recorder = Arc::new(Recorder::default());
    grpc_dc::status::set_tracer(Some(recorder.clone()));
    let client = setup().await;
    let resp = client.unary(req("hello", 0)).await.unwrap();
    assert_eq!(resp.message, "echo: hello");

    {
        let starts = recorder.starts.lock().unwrap();
        let ends = recorder.ends.lock().unwrap();
        assert_eq!(starts.len(), 2, "starts: {starts:?}");
        assert_eq!(ends.len(), 2, "ends: {ends:?}");
        let client_span = starts.iter().find(|s| s.0 == "client").unwrap();
        let server_span = starts.iter().find(|s| s.0 == "server").unwrap();
        assert_eq!(client_span.2, server_span.2, "one trace id");
        assert_eq!(server_span.4, client_span.3, "server parented to client");
        assert!(ends.iter().all(|e| e.4 == "OK" && e.5 >= 0.0));
    }

    let parent = grpc_dc::status::parse_traceparent(Some(
        &"00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-00".to_string(),
    ))
    .unwrap();
    assert!(!parent.sampled);
    assert_eq!(
        grpc_dc::status::format_traceparent(&parent.trace_id, &parent.span_id, parent.sampled),
        "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-00"
    );

    recorder.starts.lock().unwrap().clear();
    recorder.ends.lock().unwrap().clear();
    let client = setup().await;
    let mut metadata = Metadata::new();
    metadata.insert(
        "traceparent".into(),
        "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-00".into(),
    );
    let resp = client
        .unary_with_options(req("hello", 0), grpc_dc::CallOptions { metadata, timeout: None, ..Default::default() })
        .await
        .unwrap();
    assert_eq!(resp.message, "echo: hello");
    assert!(recorder.starts.lock().unwrap().is_empty());
    assert!(recorder.ends.lock().unwrap().is_empty());

    // Nested: the front callee's handler makes an outbound call
    // parented to its server span via CallCtx::trace_context.
    recorder.starts.lock().unwrap().clear();
    recorder.ends.lock().unwrap().clear();
    let downstream = setup().await;
    let seen = Arc::new(std::sync::Mutex::new(None::<String>));
    let front_service = FrontService { downstream, seen: seen.clone() };
    let (a, b) = loopback_pair();
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![echo_service(Arc::new(front_service))]));
    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    let front_client = EchoClient::new(Channel::new(client_transport));
    let resp = front_client.unary(req("hello", 0)).await.unwrap();
    assert_eq!(resp.message, "echo: nested");
    {
        let starts = recorder.starts.lock().unwrap();
        assert_eq!(starts.len(), 4, "starts: {starts:?}");
        let kinds: Vec<&str> = starts.iter().map(|s| s.0.as_str()).collect();
        assert_eq!(kinds, ["client", "server", "client", "server"]);
        let (outer_client, outer_server, inner_client, inner_server) =
            (&starts[0], &starts[1], &starts[2], &starts[3]);
        assert!(starts.iter().all(|s| s.2 == outer_client.2));
        assert_eq!(outer_server.4, outer_client.3);
        assert_eq!(inner_client.4, outer_server.3);
        assert_eq!(inner_server.4, inner_client.3);
        assert_eq!(seen.lock().unwrap().as_deref(), Some(outer_server.3.as_str()));
        assert_eq!(recorder.ends.lock().unwrap().len(), 4);
    }

    // Root context groups several client calls under one trace.
    recorder.starts.lock().unwrap().clear();
    recorder.ends.lock().unwrap().clear();
    let root = grpc_dc::status::new_trace_context("internal", "workflow").unwrap();
    let client = setup().await;
    for msg in ["one", "two"] {
        client
            .unary_with_options(
                req(msg, 0),
                grpc_dc::CallOptions::default().trace_parent(&root),
            )
            .await
            .unwrap();
    }
    grpc_dc::status::trace_end("internal", "workflow", Some(&root), "OK");
    grpc_dc::status::set_tracer(None);
    {
        let starts = recorder.starts.lock().unwrap();
        let clients: Vec<_> = starts.iter().filter(|s| s.0 == "client").collect();
        assert_eq!(clients.len(), 2);
        assert!(clients.iter().all(|s| s.4 == root.span_id));
        assert!(starts.iter().all(|s| s.2 == root.trace_id));
    }
}

struct FrontService {
    downstream: EchoClient,
    seen: Arc<std::sync::Mutex<Option<String>>>,
}

#[grpc_dc::async_trait]
impl Echo for FrontService {
    async fn unary(&self, _req: pb::EchoRequest, ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        let trace = ctx.trace_context.clone().expect("server trace context");
        *self.seen.lock().unwrap() = Some(trace.span_id.clone());
        self.downstream
            .unary_with_options(
                req("nested", 0),
                grpc_dc::CallOptions::default().trace_parent(&trace),
            )
            .await
    }

    async fn server_stream(
        &self,
        _req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        Ok(Box::pin(futures_util::stream::empty()))
    }

    async fn client_stream(
        &self,
        _reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        Ok(pb::EchoResponse::default())
    }

    async fn bidi(
        &self,
        _reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        Ok(Box::pin(futures_util::stream::empty()))
    }
}
