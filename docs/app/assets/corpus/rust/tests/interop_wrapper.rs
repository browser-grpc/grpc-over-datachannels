//! Interop through the generated native wrapper (no Node
//! bridge): generated Rust TestService client over a loopback
//! DataChannel pair, forwarded by grpc_dc::http2's
//! serve_dc_to_http2_conn to the reference grpc-go
//! TestService server over a real H2ClientConn. This is the
//! `dc <-> http2 <-> stock server` wrapper contract from
//! proxy-spec, exercised end to end.
//!
//! Skips when the oracle binary is not built (Dockerfile.ci
//! builds oracle/go-interop).

#[path = "../examples/interop_server_stdio/pb_glue.rs"]
mod pb;

#[path = "../gen/test_grpc_dc.rs"]
mod test_stub;

use grpc_dc::http2::proxy::serve_dc_to_http2_conn;
use grpc_dc::http2::H2ClientConn;
use grpc_dc::{loopback_pair, Channel, DcTransport};
use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use test_stub::TestServiceClient;

fn root() -> String {
    format!("{}/..", env!("CARGO_MANIFEST_DIR"))
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
async fn rust_client_through_wrapper_calls_go_reference_server() {
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
    let h2 = Arc::new(H2ClientConn::connect(&authority).await.unwrap());

    // Wrapper: client side of the loopback pair is the gRPC
    // channel; the other side is served by serve_dc_to_http2_conn.
    let (client_dc, wrapper_dc) = loopback_pair();
    let client_transport: Arc<dyn DcTransport> = Arc::new(client_dc);
    let wrapper_transport: Arc<dyn DcTransport> = Arc::new(wrapper_dc);
    let wrapper = tokio::spawn(async move {
        let _ = serve_dc_to_http2_conn(wrapper_transport, h2, &authority).await;
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

    wrapper.abort();
}
