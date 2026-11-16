//! IPC transports: UDS DcTransport carries whole frames
//! between two endpoints (host/plugin seam). Stdio uses the
//! same StreamDc framing and is covered by construction.

use bytes::Bytes;
use grpc_dc::{uds_dc, uds_dc_accept, DcTransport};
use std::sync::Arc;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn uds_dc_echo_frames() {
    let path = std::env::temp_dir().join(format!("grpc-dc-ipc-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let dc = uds_dc_accept(stream);
        let msg = dc.next().await.unwrap().unwrap();
        dc.send(Bytes::from(format!("re:{}", String::from_utf8_lossy(&msg))))
            .await
            .unwrap();
    });
    let client = uds_dc(&path).await.unwrap();
    client.send(Bytes::from_static(b"hello-ipc")).await.unwrap();
    let reply = client.next().await.unwrap().unwrap();
    assert_eq!(&reply[..], b"re:hello-ipc");
    server.await.unwrap();
    let _ = std::fs::remove_file(&path);
    let _ = Arc::new(());
}
