//! gRPC over the smoltcp leg: generated TestService client
//! over a loopback DataChannel pair, forwarded by the
//! generated wrapper (serve_dc_to_http2_conn) whose HTTP/2
//! backend connection runs over a SidecarStream (smoltcp
//! userspace TCP). The sidecar's server stack bridges bytes
//! to an OS TcpStream to the reference grpc-go server — the
//! selectable-TCP-leg wrapper contract, end to end.
//!
//! Skips when the oracle binary is not built.

#[path = "../../../rust/examples/interop_server_stdio/pb_glue.rs"]
mod pb;

#[path = "../../../rust/gen/test_grpc_dc.rs"]
mod test_stub;

use grpc_dc::http2::proxy::serve_dc_to_http2_conn;
use grpc_dc::http2::H2ClientConn;
use grpc_dc::{loopback_pair, Channel, DcTransport};
use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn grpc_over_smoltcp_leg_calls_go_reference_server() {
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

    // smoltcp leg: client stream dials the in-pair listener;
    // the accepted side bridges bytes to the OS socket.
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

    let (client_dc, wrapper_dc) = loopback_pair();
    let client_transport: Arc<dyn DcTransport> = Arc::new(client_dc);
    let wrapper_transport: Arc<dyn DcTransport> = Arc::new(wrapper_dc);
    let auth2 = authority.clone();
    let wrapper = tokio::spawn(async move {
        let _ = serve_dc_to_http2_conn(wrapper_transport, h2, &auth2).await;
    });

    let client = TestServiceClient::new(Channel::new(client_transport));
    let empty = client.empty_call(pb::Empty::default()).await.unwrap();
    assert_eq!(empty, pb::Empty::default());
    let large = client
        .unary_call(pb::SimpleRequest {
            response_size: 314_159,
            payload: Some(Box::new(pb::Payload {
                body: vec![0u8; 271_828],
                ..Default::default()
            })),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(large.payload.unwrap().body.len(), 314_159);

    let stats = sidecar.stats();
    assert!(stats.frames_sent > 0 && stats.syn_count >= 1, "{stats:?}");
    let link = sidecar.link_stats();
    assert_eq!(link.tcp.unwrap().frames_sent, stats.frames_sent);

    wrapper.abort();
    bridge.abort();
}
