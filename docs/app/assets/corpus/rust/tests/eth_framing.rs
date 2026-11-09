#![cfg(feature = "webrtc")]
//! End-to-end: generated Echo service over raw Ethernet framing
//! (EthDc transport, EtherType 0x88B5) on the virtual cable — no
//! IP/UDP/ICE anywhere in the path. Covers the embedded case
//! beyond a single small unary: messages larger than one
//! Ethernet frame (EthFraming chunks at 1491 bytes, so a 10 KiB
//! message crosses ~7 frames each way) and all streaming shapes.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use dc_webrtc::net::EthernetCable;
use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{CallCtx, Channel, EthDc, RequestStream, ResponseStream, Server, Status};
use std::sync::Arc;
use std::time::Duration;
use stub::{echo_service, Echo, EchoClient};

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(&self, req: pb::EchoRequest, _ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        Ok(pb::EchoResponse { message: format!("echo: {}", req.message), index: 0, ..Default::default() })
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let responses =
            (0..req.count.max(0)).map(move |i| Ok(pb::EchoResponse { message: req.message.clone(), index: i, ..Default::default() }));
        Ok(Box::pin(futures_util::stream::iter(responses)))
    }

    async fn client_stream(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let parts: Vec<String> = reqs.map_ok(|r| r.message).try_collect().await?;
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32, ..Default::default() })
    }

    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream = futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut index)| async move {
            match reqs.next().await {
                Some(Ok(req)) => {
                    let resp = pb::EchoResponse { message: req.message, index, ..Default::default() };
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

fn eth_client() -> EchoClient {
    const MAC_A: [u8; 6] = [0x02, 0, 0, 0, 0, 1];
    const MAC_B: [u8; 6] = [0x02, 0, 0, 0, 0, 2];
    let cable = Arc::new(EthernetCable::new());
    let server_transport = EthDc::new(MAC_B, MAC_A, cable.raw_endpoint(MAC_B));
    let client_transport = EthDc::new(MAC_A, MAC_B, cable.raw_endpoint(MAC_A));
    tokio::spawn(Server::serve(server_transport, vec![echo_service(Arc::new(EchoService))]));
    EchoClient::new(Channel::new(client_transport))
}

#[tokio::test]
async fn echo_over_raw_ethernet() {
    let client = eth_client();
    let resp = client.unary(req("hello", 0)).await.unwrap();
    assert_eq!(resp.message, "echo: hello");
    println!("ETH_ECHO_OK {}", resp.message);
}

#[tokio::test]
async fn echo_over_raw_ethernet_fragmented_and_streaming() {
    let client = eth_client();
    let run = async {
        // 10 KiB unary: fragmented across ~7 Ethernet frames in
        // each direction by EthFraming (1491-byte chunks).
        let big = "x".repeat(10 * 1024);
        let resp = client.unary(req(&big, 0)).await.unwrap();
        assert_eq!(resp.message, format!("echo: {big}"));

        let mut stream = client.server_stream(req("tick", 3)).await.unwrap();
        let mut got = Vec::new();
        while let Some(item) = stream.next().await {
            got.push(item.unwrap());
        }
        assert_eq!(got.len(), 3);
        assert_eq!(got[2].index, 2);
        assert!(got.iter().all(|r| r.message == "tick"));

        let reqs = futures_util::stream::iter(["a", "b", "c"].into_iter().map(|m| req(m, 0)));
        let resp = client.client_stream(reqs).await.unwrap();
        assert_eq!(resp.message, "a+b+c");
        assert_eq!(resp.index, 3);

        let reqs = futures_util::stream::iter(["x", "y"].into_iter().map(|m| req(m, 0)));
        let mut stream = client.bidi(reqs).await.unwrap();
        let mut got = Vec::new();
        while let Some(item) = stream.next().await {
            got.push(item.unwrap().message);
        }
        assert_eq!(got, vec!["x", "y"]);
    };
    tokio::time::timeout(Duration::from_secs(30), run)
        .await
        .expect("ethernet echo timed out");
    println!("ETH_ECHO_STREAMING_OK fragmented 10KiB unary + 3 streaming shapes");
}
