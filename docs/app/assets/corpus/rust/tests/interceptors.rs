//! Server interceptors: a rejecting interceptor ends the
//! call before the handler runs; a passing chain (in install
//! order) lets it through.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use grpc_dc::{loopback_pair, CallCtx, Channel, Status};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use stub::{echo_service, Echo, EchoClient};

static HANDLED: AtomicUsize = AtomicUsize::new(0);

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        HANDLED.fetch_add(1, Ordering::SeqCst);
        Ok(pb::EchoResponse { message: format!("echo: {}", req.message), index: 0, ..Default::default() })
    }

    async fn server_stream(
        &self,
        _req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<grpc_dc::ResponseStream<pb::EchoResponse>, Status> {
        Ok(Box::pin(futures_util::stream::empty()))
    }

    async fn client_stream(
        &self,
        _reqs: grpc_dc::RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        Ok(pb::EchoResponse::default())
    }

    async fn bidi(
        &self,
        _reqs: grpc_dc::RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<grpc_dc::ResponseStream<pb::EchoResponse>, Status> {
        Ok(Box::pin(futures_util::stream::empty()))
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn interceptor_rejects_before_handler() {
    HANDLED.store(0, Ordering::SeqCst);
    let (a, b) = loopback_pair();
    let handle = grpc_dc::Server::serve_handle(Arc::new(b), vec![echo_service(Arc::new(EchoService))]);
    let order = Arc::new(std::sync::Mutex::new(Vec::new()));
    let o1 = order.clone();
    handle.add_interceptor(Arc::new(move |path, _md| {
        o1.lock().unwrap().push(format!("first:{path}"));
        Ok(())
    }));
    let o2 = order.clone();
    handle.add_interceptor(Arc::new(move |_path, md| {
        o2.lock().unwrap().push("second".to_string());
        if md.get("x-block") == Some(&"yes".to_string()) {
            return Err(Status::new(grpc_dc::Code::Unauthenticated, "blocked by interceptor"));
        }
        Ok(())
    }));

    let client = EchoClient::new(Channel::new(Arc::new(a)));
    let resp = client
        .unary(pb::EchoRequest { message: "hi".into(), ..Default::default() })
        .await
        .unwrap();
    assert_eq!(resp.message, "echo: hi");
    assert_eq!(HANDLED.load(Ordering::SeqCst), 1);
    assert_eq!(
        order.lock().unwrap().join(","),
        "first:/echo.Echo/Unary,second",
        "interceptors must run in install order"
    );

    // Blocked call: metadata is not part of the generated
    // client API surface here, so assert through a second
    // handle whose interceptor always rejects.
    let (a2, b2) = loopback_pair();
    let handle2 = grpc_dc::Server::serve_handle(Arc::new(b2), vec![echo_service(Arc::new(EchoService))]);
    handle2.add_interceptor(Arc::new(|_path, _md| {
        Err(Status::new(grpc_dc::Code::Unauthenticated, "blocked by interceptor"))
    }));
    let client2 = EchoClient::new(Channel::new(Arc::new(a2)));
    let err = client2
        .unary(pb::EchoRequest { message: "hi".into(), ..Default::default() })
        .await
        .unwrap_err();
    assert_eq!(err.code, grpc_dc::Code::Unauthenticated);
    assert_eq!(HANDLED.load(Ordering::SeqCst), 1, "handler must not run when an interceptor rejects");
}
