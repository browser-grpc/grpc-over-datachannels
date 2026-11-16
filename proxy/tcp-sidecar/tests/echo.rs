use tcp_sidecar::Sidecar;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn echo_and_stats() {
    let sidecar = std::sync::Arc::new(Sidecar::new());
    let sc = sidecar.clone();
    let server = tokio::spawn(async move {
        let mut s = sc.accept().await.unwrap();
        let mut buf = vec![0u8; 32768];
        let mut got = 0;
        while got < buf.len() {
            let n = s.read(&mut buf[got..]).await.unwrap();
            assert!(n > 0);
            got += n;
        }
        s.write_all(&buf).await.unwrap();
    });
    let mut client = sidecar.connect().await.unwrap();
    let payload: Vec<u8> = (0..32768u32).map(|i| (i % 251) as u8).collect();
    client.write_all(&payload).await.unwrap();
    let mut back = vec![0u8; 32768];
    client.read_exact(&mut back).await.unwrap();
    assert_eq!(back, payload);
    server.await.unwrap();
    let stats = sidecar.stats();
    assert!(stats.frames_sent > 0 && stats.bytes_sent >= 32768, "{stats:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn loss_injection_counts_retransmits() {
    let sidecar = std::sync::Arc::new(Sidecar::with_drop(5));
    let sc = sidecar.clone();
    let server = tokio::spawn(async move {
        let mut s = sc.accept().await.unwrap();
        let mut buf = vec![0u8; 16384];
        let mut got = 0;
        while got < buf.len() {
            match s.read(&mut buf[got..]).await {
                Ok(0) => break,
                Ok(n) => got += n,
                Err(_) => break,
            }
        }
        let _ = s.write_all(b"done").await;
    });
    let mut client = sidecar.connect().await.unwrap();
    let payload: Vec<u8> = (0..16384u32).map(|i| (i % 251) as u8).collect();
    client.write_all(&payload).await.unwrap();
    let mut back = [0u8; 4];
    let read = tokio::time::timeout(std::time::Duration::from_secs(30), client.read_exact(&mut back)).await;
    assert!(read.is_ok(), "echo did not complete under loss");
    let _ = server.await;
    let stats = sidecar.stats();
    assert!(stats.tcp_retransmits > 0, "expected retransmits under drop: {stats:?}");
}
