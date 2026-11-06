//! Echo over raw Ethernet framing: a generated Echo server and
//! client talking through the `EthDc` transport (EtherType
//! 0x88B5) on dc-webrtc's virtual Ethernet cable — no IP, UDP, or
//! ICE anywhere, the bare-metal path for targets whose only
//! network surface is a NIC driver (`EthFramePort`).
//!
//! Run: `cargo run --features webrtc --example eth_echo`
//! Prints `ETH_ECHO_OK echo: hello` on success.

use dc_webrtc::net::EthernetCable;
use grpc_dc::{Channel, EthDc, Server, Status};
use std::sync::Arc;

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use stub::{echo_service, Echo, EchoClient};

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(
        &self,
        req: pb::EchoRequest,
        _ctx: grpc_dc::CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        Ok(pb::EchoResponse {
            message: format!("echo: {}", req.message),
            index: 0,
            ..Default::default()
        })
    }

    async fn server_stream(
        &self,
        _req: pb::EchoRequest,
        _ctx: grpc_dc::CallCtx,
    ) -> Result<grpc_dc::ResponseStream<pb::EchoResponse>, Status> {
        Err(Status::unimplemented("server_stream"))
    }

    async fn client_stream(
        &self,
        _reqs: grpc_dc::RequestStream<pb::EchoRequest>,
        _ctx: grpc_dc::CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        Err(Status::unimplemented("client_stream"))
    }

    async fn bidi(
        &self,
        _reqs: grpc_dc::RequestStream<pb::EchoRequest>,
        _ctx: grpc_dc::CallCtx,
    ) -> Result<grpc_dc::ResponseStream<pb::EchoResponse>, Status> {
        Err(Status::unimplemented("bidi"))
    }
}

#[tokio::main]
async fn main() {
    const MAC_A: [u8; 6] = [0x02, 0, 0, 0, 0, 1];
    const MAC_B: [u8; 6] = [0x02, 0, 0, 0, 0, 2];
    let cable = Arc::new(EthernetCable::new());
    let server_transport = EthDc::new(MAC_B, MAC_A, cable.raw_endpoint(MAC_B));
    let client_transport = EthDc::new(MAC_A, MAC_B, cable.raw_endpoint(MAC_A));
    tokio::spawn(Server::serve(
        server_transport,
        vec![echo_service(Arc::new(EchoService))],
    ));
    let client = EchoClient::new(Channel::new(client_transport));
    let resp = client
        .unary(pb::EchoRequest {
            message: "hello".into(),
            ..Default::default()
        })
        .await
        .expect("unary over raw Ethernet");
    assert_eq!(resp.message, "echo: hello");
    println!("ETH_ECHO_OK {}", resp.message);
}
