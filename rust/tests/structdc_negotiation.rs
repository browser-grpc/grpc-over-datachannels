//! Struct-codec negotiation end to end over loopback (Rust
//! runtime): struct<->struct succeeds via the shared
//! grpc_dc::structdc codec, struct client against a protobuf-only
//! server is rejected UNIMPLEMENTED, and a plain protobuf client
//! against a struct-enabled server still works (the marker is
//! opt-in per call).

#[path = "../examples/dynamic_echo_server_stdio/service.rs"]
mod service;

use grpc_dc::dynamic::{dynamic_service, parse_descriptor_set, DynamicClient, FileModel, GenericMessage};
use grpc_dc::{loopback_pair, Channel, Code, DcTransport, Server};
use std::sync::Arc;

fn load_model() -> Arc<FileModel> {
    let path = format!(
        "{}/../fixtures/echo_descriptor_set.bin",
        env!("CARGO_MANIFEST_DIR")
    );
    let bytes = std::fs::read(&path).expect("descriptor fixture (run make generate)");
    Arc::new(parse_descriptor_set(&bytes).expect("parse descriptor set"))
}

fn req(message: &str) -> GenericMessage {
    let mut m = GenericMessage::new();
    m.set(1, message.to_string());
    m.set(2, 7i64);
    m
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn struct_negotiation_matrix() {
    let model = load_model();

    // struct client <-> struct server: OK over the shared codec
    let (a, b) = loopback_pair();
    let svc = dynamic_service(&model, "echo.Echo", Arc::new(service::DynamicEchoService)).unwrap();
    let ep = Server::serve_handle(Arc::new(b) as Arc<dyn DcTransport>, vec![svc]);
    ep.set_struct_codec(true);
    let client = DynamicClient::new(Channel::new(Arc::new(a) as Arc<dyn DcTransport>), model.clone());
    client.set_struct_codec(true);
    let resp = client.unary("echo.Echo", "Unary", req("hello")).await.unwrap();
    assert_eq!(resp.get_string(1), "echo: hello");

    // struct client -> protobuf-only server: UNIMPLEMENTED
    let (a, b) = loopback_pair();
    let svc = dynamic_service(&model, "echo.Echo", Arc::new(service::DynamicEchoService)).unwrap();
    let _ep = Server::serve_handle(Arc::new(b) as Arc<dyn DcTransport>, vec![svc]);
    let client = DynamicClient::new(Channel::new(Arc::new(a) as Arc<dyn DcTransport>), model.clone());
    client.set_struct_codec(true);
    let err = client.unary("echo.Echo", "Unary", req("hello")).await.unwrap_err();
    assert_eq!(err.code, Code::Unimplemented, "got {err}");

    // plain client -> struct server: protobuf path unaffected
    let (a, b) = loopback_pair();
    let svc = dynamic_service(&model, "echo.Echo", Arc::new(service::DynamicEchoService)).unwrap();
    let ep = Server::serve_handle(Arc::new(b) as Arc<dyn DcTransport>, vec![svc]);
    ep.set_struct_codec(true);
    let client = DynamicClient::new(Channel::new(Arc::new(a) as Arc<dyn DcTransport>), model.clone());
    let resp = client.unary("echo.Echo", "Unary", req("hello")).await.unwrap();
    assert_eq!(resp.get_string(1), "echo: hello");
}
