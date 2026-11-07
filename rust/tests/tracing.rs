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
    ends: std::sync::Mutex<Vec<(String, String, String, String, String)>>,
}

impl grpc_dc::status::Tracer for Recorder {
    fn on_start(&self, kind: &str, method: &str, trace_id: &str, span_id: &str, parent_span_id: &str) {
        self.starts.lock().unwrap().push((kind.into(), method.into(), trace_id.into(), span_id.into(), parent_span_id.into()));
    }
    fn on_end(&self, kind: &str, method: &str, trace_id: &str, span_id: &str, status: &str) {
        self.ends.lock().unwrap().push((kind.into(), method.into(), trace_id.into(), span_id.into(), status.into()));
    }
}

#[tokio::test]
async fn tracing_parented_spans() {
    let recorder = Arc::new(Recorder::default());
    grpc_dc::status::set_tracer(Some(recorder.clone()));
    let client = setup().await;
    let resp = client.unary(req("hello", 0)).await.unwrap();
    grpc_dc::status::set_tracer(None);
    assert_eq!(resp.message, "echo: hello");

    let starts = recorder.starts.lock().unwrap();
    let ends = recorder.ends.lock().unwrap();
    assert_eq!(starts.len(), 2, "starts: {starts:?}");
    assert_eq!(ends.len(), 2, "ends: {ends:?}");
    let client_span = starts.iter().find(|s| s.0 == "client").unwrap();
    let server_span = starts.iter().find(|s| s.0 == "server").unwrap();
    assert_eq!(client_span.2, server_span.2, "one trace id");
    assert_eq!(server_span.4, client_span.3, "server parented to client");
    assert!(ends.iter().all(|e| e.4 == "OK"));
}
