//! Registry discovery: ListServices answers from live
//! registrations, GetDescriptor returns registered bytes,
//! and a dynamic client calls the discovered service with
//! the fetched descriptor — no codegen on the client side.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use grpc_dc::dynamic::{parse_descriptor_set, DynamicClient, GenericMessage};
use grpc_dc::{loopback_pair, CallCtx, Channel, Registry, Status};
use std::sync::Arc;
use stub::{echo_service, Echo};

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
async fn discovery_list_fetch_and_dynamic_call() {
    let (a, b) = loopback_pair();
    let host = grpc_dc::Server::serve_handle(Arc::new(b), vec![echo_service(Arc::new(EchoService))]);
    let registry = Arc::new(Registry::new());
    let echo_descriptor = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../fixtures/echo_descriptor_set.bin")).unwrap();
    registry.register_descriptor("echo.Echo", echo_descriptor.clone());
    host.register_service(registry.service(host.clone()));

    // Dynamic client speaks to the Registry with the
    // embedded descriptor model.
    let model = parse_descriptor_set(grpc_dc::REGISTRY_DESCRIPTOR_SET).unwrap();
    let client = DynamicClient::new(Channel::new(Arc::new(a)), Arc::new(model));
    let listed = client
        .unary("grpcdc.registry.v1.Registry", "ListServices", GenericMessage::new())
        .await
        .unwrap();
    let names: Vec<String> = listed
        .get_all(1)
        .iter()
        .map(|v| format!("{v:?}"))
        .collect();
    assert!(names.iter().any(|n| n.contains("echo.Echo")), "{names:?}");
    assert!(names.iter().any(|n| n.contains("grpcdc.registry.v1.Registry")), "{names:?}");

    let mut fetch = GenericMessage::new();
    fetch.set(1, "echo.Echo".to_string());
    let got = client
        .unary("grpcdc.registry.v1.Registry", "GetDescriptor", fetch)
        .await
        .unwrap();
    let bytes = match &got.get_all(1)[0] {
        grpc_dc::GenericValue::Bytes(b) => b.clone(),
        other => panic!("descriptor value: {other:?}"),
    };
    assert_eq!(bytes, echo_descriptor);

    // Call the discovered service dynamically.
    let echo_model = parse_descriptor_set(&bytes).unwrap();
    let (a2, b2) = loopback_pair();
    let _host2 = grpc_dc::Server::serve_handle(Arc::new(b2), vec![echo_service(Arc::new(EchoService))]);
    let dyn_client = DynamicClient::new(Channel::new(Arc::new(a2)), Arc::new(echo_model));
    let mut req = GenericMessage::new();
    req.set(1, "discovered".to_string());
    let resp = dyn_client.unary("echo.Echo", "Unary", req).await.unwrap();
    assert_eq!(resp.get_string(1), "echo: discovered");
}
