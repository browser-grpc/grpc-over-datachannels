//! DC-to-DC routing: a host endpoint with no local services
//! forwards calls under a prefix to a plugin endpoint; the
//! client only ever dials the host.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use grpc_dc::endpoint::StreamIdParity;
use grpc_dc::{loopback_pair, route_prefix, CallCtx, Channel, Endpoint, Status};
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
async fn host_routes_prefix_to_plugin() {
    // Plugin: Echo served on its own endpoint (pair B server side).
    let (plugin_client_side, plugin_server_side) = loopback_pair();
    tokio::spawn(grpc_dc::Server::serve(
        Arc::new(plugin_server_side),
        vec![echo_service(Arc::new(EchoService))],
    ));
    let plugin_ep = Endpoint::new(Arc::new(plugin_client_side), StreamIdParity::Odd);
    tokio::spawn(plugin_ep.clone().run());

    // Host: no local services; route /echo.Echo/ to the plugin.
    let (client_side, host_side) = loopback_pair();
    let host = grpc_dc::Server::serve_handle(Arc::new(host_side), vec![]);
    route_prefix(&host, "/echo.Echo/", plugin_ep);

    let client = EchoClient::new(Channel::new(Arc::new(client_side)));
    let resp = client
        .unary(pb::EchoRequest { message: "via-host".into(), ..Default::default() })
        .await
        .unwrap();
    assert_eq!(resp.message, "echo: via-host");
    assert!(host.registered_services().is_empty(), "routing must not register locally");
}
