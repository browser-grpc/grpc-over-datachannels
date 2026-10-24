//! QUIC termination proof: a quinn client speaks to the
//! terminator, whose streams are bridged to a plain TCP echo
//! backend. QUIC exists only between client and proxy.

use std::net::SocketAddr;
use std::time::Duration;

use grpc_dc_h3_terminator::{insecure_client_config, run_terminator, server_config};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[tokio::test]
async fn quic_stream_bridged_to_tcp_backend() {
    // Plain TCP echo backend.
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let backend: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut buf = vec![0u8; 4096];
                while let Ok(n) = sock.read(&mut buf).await {
                    if n == 0 || sock.write_all(&buf[..n]).await.is_err() {
                        return;
                    }
                }
            });
        }
    });

    // Terminator under test.
    let server = quinn::Endpoint::server(server_config(), "127.0.0.1:0".parse().unwrap()).unwrap();
    let proxy_addr = server.local_addr().unwrap();
    tokio::spawn(run_terminator(server, backend));

    // QUIC client.
    let mut client = quinn::Endpoint::client("0.0.0.0:0".parse().unwrap()).unwrap();
    client.set_default_client_config(insecure_client_config());
    let conn = tokio::time::timeout(
        Duration::from_secs(20),
        client.connect(proxy_addr, "localhost").unwrap(),
    )
    .await
    .expect("connect timed out")
    .expect("connect failed");

    let (mut send, mut recv) = conn.open_bi().await.unwrap();
    send.write_all(b"hello over terminated quic").await.unwrap();
    send.finish().unwrap();
    let echoed = tokio::time::timeout(Duration::from_secs(20), recv.read_to_end(4096))
        .await
        .expect("read timed out")
        .expect("read failed");
    assert_eq!(echoed, b"hello over terminated quic");
    conn.close(0u32.into(), b"done");
}
