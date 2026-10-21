//! gRPC over WebRTC-Direct (libp2p-style, signaling-free):
//! generated Echo client dials a generated server by multiaddr
//! only (address + certhash), through the generated
//! `grpc_dc::webrtc_direct` helpers. Runs only with
//! `--features webrtc`.

#![cfg(feature = "webrtc")]

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use futures_util::StreamExt;
use grpc_dc::webrtc_direct::{accept_direct_transport, direct_client, direct_listener};
use grpc_dc::{CallCtx, Channel, RequestStream, ResponseStream, Server, Status};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
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
        let responses = (0..req.count.max(0))
            .map(move |i| Ok(pb::EchoResponse { message: req.message.clone(), index: i, ..Default::default() }));
        Ok(Box::pin(futures_util::stream::iter(responses)))
    }
    async fn client_stream(
        &self,
        mut reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let mut parts = Vec::new();
        while let Some(req) = reqs.next().await {
            parts.push(req?.message);
        }
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32, ..Default::default() })
    }
    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream = futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut i)| async move {
            match reqs.next().await {
                Some(Ok(req)) => {
                    let r = pb::EchoResponse { message: req.message, index: i, ..Default::default() };
                    i += 1;
                    Some((Ok(r), (reqs, i)))
                }
                Some(Err(e)) => Some((Err(e), (reqs, i))),
                None => None,
            }
        });
        Ok(Box::pin(stream))
    }
}

fn req(message: &str, count: i32) -> pb::EchoRequest {
    pb::EchoRequest { message: message.into(), count, delay_ms: 0, ..Default::default() }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn grpc_over_webrtc_direct_multiaddr() {
    let listener = Arc::new(
        direct_listener(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)).expect("listener"),
    );
    let multiaddr = listener.multiaddr();
    assert!(multiaddr.contains("/webrtc-direct/certhash/f"), "{multiaddr}");

    let server_listener = listener.clone();
    let server = tokio::spawn(async move {
        let transport = accept_direct_transport(server_listener).await.expect("accept");
        Server::serve(transport, vec![echo_service(Arc::new(EchoService))]).await;
    });

    let transport = direct_client(&multiaddr).await.expect("direct client");
    let client = EchoClient::new(Channel::new(transport));

    let unary = client.unary(req("hello", 0)).await.unwrap();
    assert_eq!(unary.message, "echo: hello");

    let mut stream = client.server_stream(req("tick", 3)).await.unwrap();
    let mut ticks = Vec::new();
    while let Some(item) = stream.next().await {
        ticks.push(item.unwrap().index);
    }
    assert_eq!(ticks, vec![0, 1, 2]);

    server.abort();
}

/// A lossy, unordered application channel opened next to the
/// grpc channel through the generated adapter's endpoint
/// surface: messages arrive (no loss on loopback, but the
/// channel is negotiated maxRetransmits=0 + unordered via
/// ChannelParams).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lossy_unordered_app_channel_next_to_grpc() {
    use futures_util::StreamExt as _;
    use grpc_dc::webrtc_direct::{
        accept_direct_endpoint, direct_client_endpoint, ChannelParams, Reliability,
    };

    let listener = Arc::new(
        direct_listener(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)).expect("listener"),
    );
    let multiaddr = listener.multiaddr();

    let server_listener = listener.clone();
    let server = tokio::spawn(async move {
        let endpoint = accept_direct_endpoint(server_listener).await.expect("accept endpoint");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        let mut got = None;
        while std::time::Instant::now() < deadline && got.is_none() {
            match endpoint.recv_event_timeout(std::time::Duration::from_millis(200)) {
                Some(grpc_dc::webrtc_direct::EndpointEvent::Message { data, .. }) => {
                    got = Some(data)
                }
                _ => {}
            }
        }
        endpoint.shutdown();
        got.expect("app channel message")
    });

    let endpoint = direct_client_endpoint(&multiaddr).await.expect("client endpoint");
    let channel = endpoint
        .open_channel(ChannelParams {
            label: "telemetry".into(),
            ordered: false,
            reliability: Reliability::MaxRetransmits(0),
            ..Default::default()
        })
        .expect("open lossy channel");
    channel.send_binary(b"ping-lossy").expect("send");
    let got = server.await.expect("server task");
    assert_eq!(got, b"ping-lossy");
    endpoint.shutdown();
}
