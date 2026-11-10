//! Rendezvous (grpc_dc::rendezvous): a Rust Peer dialer
//! synthesizes the listener's description locally, runs ICE
//! as controlling agent, and runs generated Echo stubs over
//! the resulting "grpc" channel — no signaling exchange.
//! Runs only with `--features webrtc`.

#![cfg(feature = "webrtc")]

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::ice::Candidate;
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::sdp::{generate, SessionDescription};
use futures_util::StreamExt;
use grpc_dc::rendezvous::serve_rendezvous;
use grpc_dc::webrtc_transport::WebRtcDc;
use grpc_dc::{CallCtx, Channel, RequestStream, ResponseStream, Status};
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rendezvous_echo() {
    let listener = serve_rendezvous("127.0.0.1:0", vec![echo_service(Arc::new(EchoService))])
        .expect("serve rendezvous");
    let desc = listener.descriptor("127.0.0.1");

    let mut dialer = Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        ..Default::default()
    })
    .unwrap();
    let remote = SessionDescription {
        ufrag: desc.ice_ufrag.clone(),
        pwd: desc.ice_pwd.clone(),
        fingerprint: desc.fingerprint.clone(),
        setup: "passive".to_string(),
        candidates: vec![Candidate::host(
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), desc.port),
            "1",
        )],
        sctp_port: 5000,
    };
    dialer.handle_answer(&generate(&remote, false)).unwrap();
    let endpoint = Arc::new(dialer.connect().expect("dialer connect"));
    let client_channel = endpoint
        .open_channel(ChannelParams { label: "grpc".into(), ..Default::default() })
        .unwrap();
    let client_transport: Arc<dyn grpc_dc::DcTransport> =
        Arc::new(WebRtcDc::new(endpoint.clone(), client_channel));
    let client = EchoClient::new(Channel::new(client_transport));
    let unary = client
        .unary(pb::EchoRequest { message: "hello".into(), count: 0, delay_ms: 0, ..Default::default() })
        .await
        .unwrap();
    assert_eq!(unary.message, "echo: hello");
    listener.close();
}
