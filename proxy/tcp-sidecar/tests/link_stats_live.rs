//! LinkStats on one live wrapper call, all three legs filled:
//! generated TestService client over a real WebRTC
//! DataChannel (SCTP leg, WebRtcDc stats) -> generated
//! wrapper (serve_dc_to_http2_conn) -> HTTP/2 over a
//! SidecarStream (TCP leg bridged to the reference grpc-go
//! server; HTTP/2 leg from H2ClientConn counters).
//!
//! Skips when the oracle binary is not built.

#[path = "../../../rust/examples/interop_server_stdio/pb_glue.rs"]
mod pb;

#[path = "../../../rust/gen/test_grpc_dc.rs"]
mod test_stub;

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use grpc_dc::http2::proxy::serve_dc_to_http2_conn;
use grpc_dc::http2::H2ClientConn;
use grpc_dc::link_stats::LinkStats;
use grpc_dc::webrtc_transport::WebRtcDc;
use grpc_dc::{Channel, DcTransport};
use std::net::{IpAddr, Ipv4Addr, TcpListener};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::Duration;
use tcp_sidecar::Sidecar;
use test_stub::TestServiceClient;

fn root() -> String {
    format!("{}/../..", env!("CARGO_MANIFEST_DIR"))
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn wait_port(port: u16, what: &str) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return;
        }
        assert!(std::time::Instant::now() < deadline, "{what} did not start");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

struct KillOnDrop(Child);

impl Drop for KillOnDrop {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn link_stats_all_legs_on_one_wrapper_call() {
    let root = root();
    let binary = format!("{root}/oracle/go-interop/interop-server");
    if !std::path::Path::new(&binary).exists() {
        eprintln!("skip: go interop server not built (oracle/go-interop)");
        return;
    }
    let port = free_port();
    let _server = KillOnDrop(
        Command::new(&binary)
            .args(["-port", &port.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn go interop server"),
    );
    wait_port(port, "go interop server");
    let authority = format!("127.0.0.1:{port}");

    // TCP leg (smoltcp) bridged to the OS socket.
    let sidecar = Arc::new(Sidecar::new());
    let bridge_sidecar = sidecar.clone();
    let bridge_authority = authority.clone();
    let bridge = tokio::spawn(async move {
        let mut smol = bridge_sidecar.accept().await.unwrap();
        let mut os = tokio::net::TcpStream::connect(&bridge_authority).await.unwrap();
        let _ = tokio::io::copy_bidirectional(&mut smol, &mut os).await;
    });
    let smol_client = sidecar.connect().await.unwrap();
    let h2 = Arc::new(H2ClientConn::from_stream(smol_client).await.unwrap());

    // SCTP leg: two real peers, client + wrapper channels.
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();
    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();
    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = Arc::new(offerer.connect().expect("offerer connect"));
    let answerer_ep = Arc::new(answerer_thread.join().unwrap().expect("answerer connect"));

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

    let wrapper_transport_obj = WebRtcDc::new(answerer_ep.clone(), server_channel);
    let wrapper_transport: Arc<dyn DcTransport> = Arc::new(wrapper_transport_obj);
    let auth2 = authority.clone();
    let h2c = h2.clone();
    let wrapper = tokio::spawn(async move {
        let _ = serve_dc_to_http2_conn(wrapper_transport, h2c, &auth2).await;
    });

    let client_transport_obj = Arc::new(WebRtcDc::new(offerer_ep.clone(), client_channel));
    let stats_source = client_transport_obj.clone();
    let client_transport: Arc<dyn DcTransport> = client_transport_obj;
    let client = TestServiceClient::new(Channel::new(client_transport));
    let empty = client.empty_call(pb::Empty::default()).await.unwrap();
    assert_eq!(empty, pb::Empty::default());

    let sctp = stats_source.stats().expect("sctp stats");
    let stats = LinkStats::new()
        .with_sctp(sctp.into())
        .with_tcp(sidecar.stats().into())
        .with_http2(h2.stats());
    let s = stats.sctp.expect("sctp leg filled");
    assert!(s.chunks_sent > 0 && s.chunks_received > 0, "{s:?}");
    let t = stats.tcp.expect("tcp leg filled");
    assert!(t.frames_sent > 0 && t.syn_count >= 1, "{t:?}");
    let h = stats.http2.expect("http2 leg filled");
    assert!(h.frames_sent > 0 && h.streams_opened >= 1, "{h:?}");
    println!("LinkStats live: sctp={s:?} tcp={t:?} http2={h:?}");

    wrapper.abort();
    bridge.abort();
}
