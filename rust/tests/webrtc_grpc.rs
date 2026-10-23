//! gRPC over the reimplemented WebRTC stack (ICE+DTLS+SCTP+DCEP):
//! generated Echo client and server, two full Rust peers.
//! Runs only with `--features webrtc`.

#![cfg(feature = "webrtc")]

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use futures_util::StreamExt;
use grpc_dc::webrtc_transport::WebRtcDc;
use grpc_dc::{CallCtx, Channel, RequestStream, ResponseStream, Server, Status};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::time::Duration;
use stub::{echo_service, Echo, EchoClient};

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(&self, req: pb::EchoRequest, _ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        Ok(pb::EchoResponse { message: format!("echo: {}", req.message), index: 0 , ..Default::default() })
    }
    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let responses = (0..req.count.max(0))
            .map(move |i| Ok(pb::EchoResponse { message: req.message.clone(), index: i , ..Default::default() }));
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
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32 , ..Default::default() })
    }
    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream = futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut i)| async move {
            match reqs.next().await {
                Some(Ok(req)) => {
                    let r = pb::EchoResponse { message: req.message, index: i , ..Default::default() };
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

fn loopback_peer() -> Peer {
    Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: Vec::new(),
    })
    .unwrap()
}

fn req(message: &str, count: i32) -> pb::EchoRequest {
    pb::EchoRequest { message: message.into(), count, delay_ms: 0, ..Default::default() }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn grpc_over_own_webrtc_stack() {
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();
    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = Arc::new(offerer.connect().expect("offerer connect"));
    let answerer_ep = Arc::new(answerer_thread.join().unwrap().expect("answerer connect"));

    // Client opens the "grpc" channel; server waits for it, then serves.
    let client_channel = offerer_ep
        .open_channel(ChannelParams { label: "grpc".into(), ..Default::default() })
        .unwrap();
    let server_channel = {
        let ep = answerer_ep.clone();
        tokio::task::spawn_blocking(move || loop {
            match ep.recv_event_timeout(Duration::from_secs(10)) {
                Some(EndpointEvent::ChannelOpened { channel }) => break channel,
                Some(_) => continue,
                None => panic!("timed out waiting for grpc channel"),
            }
        })
        .await
        .unwrap()
    };

    let server_transport: Arc<dyn grpc_dc::DcTransport> =
        Arc::new(WebRtcDc::new(answerer_ep.clone(), server_channel));
    tokio::spawn(Server::serve(
        server_transport,
        vec![echo_service(Arc::new(EchoService))],
    ));

    let client_transport: Arc<dyn grpc_dc::DcTransport> =
        Arc::new(WebRtcDc::new(offerer_ep.clone(), client_channel));
    let client = EchoClient::new(Channel::new(client_transport));

    let unary = client.unary(req("hello", 0)).await.unwrap();
    assert_eq!(unary.message, "echo: hello");

let unary = client.unary(req("hello", 0)).await.unwrap();
    assert_eq!(unary.message, "echo: hello");

    let mut stream = client.server_stream(req("tick", 3)).await.unwrap();
    let mut ticks = Vec::new();
    while let Some(item) = stream.next().await {
        ticks.push(item.unwrap().index);
    }
    assert_eq!(ticks, vec![0, 1, 2]);

    let reqs = futures_util::stream::iter([req("a", 0), req("b", 0)]);
    let joined = client.client_stream(reqs).await.unwrap();
    assert_eq!(joined.message, "a+b");

    let reqs = futures_util::stream::iter([req("x", 0), req("y", 0)]);
    let mut bidi = client.bidi(reqs).await.unwrap();
    let mut echoed = Vec::new();
    while let Some(item) = bidi.next().await {
        echoed.push(item.unwrap().message);
    }
    assert_eq!(echoed, vec!["x", "y"]);
}
