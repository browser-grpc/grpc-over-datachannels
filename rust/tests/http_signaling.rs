//! HTTP/POST signaling (grpc_dc::http_signaling): a Rust Peer
//! offerer POSTs its offer over a raw TCP HTTP request, the
//! generated signaling server answers and serves Echo on the
//! resulting "grpc" channel. Runs only with `--features webrtc`.

#![cfg(feature = "webrtc")]

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::peer::{Peer, PeerConfig};
use futures_util::StreamExt;
use dc_webrtc::mux::PeerMux;
use grpc_dc::http_signaling::serve_http_signaling_muxed;
use grpc_dc::webrtc_transport::WebRtcDc;
use grpc_dc::{CallCtx, Channel, RequestStream, ResponseStream, Status};
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, TcpStream};
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

fn loopback_config() -> PeerConfig {
    PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: Vec::new(),
    }
}

fn json_escape(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\r', "\\r")
        .replace('\n', "\\n")
}

fn http_exchange(addr: &str, request: &str) -> (u16, String) {
    let mut stream = TcpStream::connect(addr).unwrap();
    stream.write_all(request.as_bytes()).unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    let status: u16 = response
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    (status, response)
}

fn extract_sdp(body: &str) -> String {
    extract_json_string(body, "sdp")
}

fn extract_json_string(body: &str, field: &str) -> String {
    let needle = format!("\"{field}\":\"");
    let start = body.find(&needle).unwrap() + needle.len();
    let mut out = String::new();
    let mut chars = body[start..].chars();
    loop {
        match chars.next().unwrap() {
            '"' => break,
            '\\' => match chars.next().unwrap() {
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                c => out.push(c),
            },
            c => out.push(c),
        }
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn http_signaling_echo() {
    // Host-supplied shared PeerMux: every session peer lives
    // on this one UDP socket.
    let mux = Arc::new(PeerMux::bind("127.0.0.1:0".parse().unwrap()).unwrap());
    let mux_port = mux.local_addr().port();
    let addr = serve_http_signaling_muxed(
        mux,
        "127.0.0.1:0",
        grpc_dc::http_signaling::SIGNAL_PATH,
        vec![echo_service(Arc::new(EchoService))],
        loopback_config,
    )
    .unwrap();
    let addr = addr.to_string();

    // Contract negatives: wrong method, malformed offer.
    let (status, _) = http_exchange(&addr, "GET /grpc-dc/signal HTTP/1.1\r\nhost: x\r\n\r\n");
    assert_eq!(status, 405);
    let bad = format!(
        "POST /grpc-dc/signal HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{{\"type\":\"offer\",\"sdp\":\"\"}}",
        "{\"type\":\"offer\",\"sdp\":\"\"}".len()
    );
    let (status, _) = http_exchange(&addr, &bad);
    assert_eq!(status, 400);

    let mut offerer = Peer::new(loopback_config()).unwrap();
    let offer = offerer.create_offer();
    let body = format!("{{\"type\":\"offer\",\"sdp\":\"{}\"}}", json_escape(&offer));
    let request = format!(
        "POST /grpc-dc/signal HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
        body.len(),
        body
    );
    let (status, response) = http_exchange(&addr, &request);
    assert_eq!(status, 200, "response: {response}");
    let answer = extract_sdp(&response);
    assert!(answer.contains("a=setup:active"), "answer: {answer}");
    assert!(
        answer.contains(&format!(" {mux_port} typ host")),
        "answer candidates do not use the mux port {mux_port}: {answer}"
    );
    let session = extract_json_string(&response, "session");
    assert!(!session.is_empty(), "answer carries a session id");
    offerer.handle_answer(&answer).unwrap();

    let (offerer_ep, restart) = offerer.connect_with_handle().expect("offerer connect");
    let offerer_ep = Arc::new(offerer_ep);
    let client_channel = offerer_ep
        .open_channel(ChannelParams { label: "grpc".into(), ..Default::default() })
        .unwrap();
    let client_transport: Arc<dyn grpc_dc::DcTransport> =
        Arc::new(WebRtcDc::new(offerer_ep.clone(), client_channel));
    let client = EchoClient::new(Channel::new(client_transport));
    let unary = client
        .unary(pb::EchoRequest { message: "hello".into(), count: 0, delay_ms: 0, ..Default::default() })
        .await
        .unwrap();
    assert_eq!(unary.message, "echo: hello");

    // Trickle candidate POST (unknown session 404s first).
    let bad_body = "{\"session\":\"nope\",\"candidate\":\"candidate:1 1 udp 1 127.0.0.1 9 typ host\"}";
    let bad_request = format!(
        "POST /grpc-dc/signal/candidate HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
        bad_body.len(),
        bad_body
    );
    let (status, _) = http_exchange(&addr, &bad_request);
    assert_eq!(status, 404);

    // ICE restart over the same session, then the channel works.
    let restart_offer = restart.create_restart_offer();
    let restart_body = format!(
        "{{\"session\":\"{}\",\"type\":\"offer\",\"sdp\":\"{}\"}}",
        json_escape(&session),
        json_escape(&restart_offer)
    );
    let restart_request = format!(
        "POST /grpc-dc/signal/restart HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
        restart_body.len(),
        restart_body
    );
    let (status, restart_response) = http_exchange(&addr, &restart_request);
    assert_eq!(status, 200, "restart response: {restart_response}");
    let restart_answer = extract_sdp(&restart_response);
    restart.handle_restart_answer(&restart_answer).unwrap();
    let after = client
        .unary(pb::EchoRequest { message: "after".into(), count: 0, delay_ms: 0, ..Default::default() })
        .await
        .unwrap();
    assert_eq!(after.message, "echo: after");
}
