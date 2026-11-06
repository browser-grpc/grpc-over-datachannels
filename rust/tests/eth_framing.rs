#![cfg(feature = "webrtc")]
//! End-to-end: generated Echo service over raw Ethernet framing
//! (EthDc transport, EtherType 0x88B5) on the virtual cable — no
//! IP/UDP/ICE anywhere in the path.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use dc_webrtc::net::EthernetCable;
use grpc_dc::{Channel, EthDc, Server, Status};
use std::sync::Arc;
use stub::{echo_service, Echo, EchoClient};

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(&self, req: pb::EchoRequest, _ctx: grpc_dc::CallCtx) -> Result<pb::EchoResponse, Status> {
        Ok(pb::EchoResponse { message: format!("echo: {}", req.message), index: 0, ..Default::default() })
    }
    async fn server_stream(&self, _r: pb::EchoRequest, _c: grpc_dc::CallCtx) -> Result<grpc_dc::ResponseStream<pb::EchoResponse>, Status> {
        Err(Status::unimplemented("x"))
    }
    async fn client_stream(&self, _r: grpc_dc::RequestStream<pb::EchoRequest>, _c: grpc_dc::CallCtx) -> Result<pb::EchoResponse, Status> {
        Err(Status::unimplemented("x"))
    }
    async fn bidi(&self, _r: grpc_dc::RequestStream<pb::EchoRequest>, _c: grpc_dc::CallCtx) -> Result<grpc_dc::ResponseStream<pb::EchoResponse>, Status> {
        Err(Status::unimplemented("x"))
    }
}

#[tokio::test]
async fn echo_over_raw_ethernet() {
    const MAC_A: [u8; 6] = [0x02, 0, 0, 0, 0, 1];
    const MAC_B: [u8; 6] = [0x02, 0, 0, 0, 0, 2];
    let cable = Arc::new(EthernetCable::new());
    let server_transport = EthDc::new(MAC_B, MAC_A, cable.raw_endpoint(MAC_B));
    let client_transport = EthDc::new(MAC_A, MAC_B, cable.raw_endpoint(MAC_A));
    tokio::spawn(Server::serve(server_transport, vec![echo_service(Arc::new(EchoService))]));
    let client = EchoClient::new(Channel::new(client_transport));
    let resp = client.unary(pb::EchoRequest { message: "hello".into(), ..Default::default() }).await.unwrap();
    assert_eq!(resp.message, "echo: hello");
    println!("ETH_ECHO_OK {}", resp.message);
}
