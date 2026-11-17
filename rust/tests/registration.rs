//! Runtime service registration: register and unregister
//! services on a live endpoint handle; later calls observe
//! the change immediately.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use grpc_dc::{loopback_pair, CallCtx, Channel, Status};
use std::sync::Arc;
use stub::{echo_service, Echo, EchoClient};

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
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
async fn register_unregister_after_serve() {
    let (a, b) = loopback_pair();
    // Start with NO services: the first call must fail.
    let handle = grpc_dc::Server::serve_handle(Arc::new(b), vec![]);
    let client = EchoClient::new(Channel::new(Arc::new(a)));
    let req = || pb::EchoRequest { message: "hi".into(), ..Default::default() };

    let err = client.unary(req()).await.unwrap_err();
    assert_eq!(err.code, grpc_dc::Code::Unimplemented, "{err}");

    // Register at runtime: the same client now succeeds.
    handle.register_service(echo_service(Arc::new(EchoService)));
    assert_eq!(handle.registered_services(), vec!["echo.Echo".to_string()]);
    let resp = client.unary(req()).await.unwrap();
    assert_eq!(resp.message, "echo: hi");

    // Unregister: calls fail again.
    handle.unregister_service("echo.Echo");
    assert!(handle.registered_services().is_empty());
    let err = client.unary(req()).await.unwrap_err();
    assert_eq!(err.code, grpc_dc::Code::Unimplemented, "{err}");
}
