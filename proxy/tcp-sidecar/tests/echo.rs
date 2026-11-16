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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn udp_frontend_echo_between_two_stacks() {
    use tcp_sidecar::Stack;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    // Bind UDP tunnel endpoints first so addresses are known.
    let a_bind: std::net::SocketAddr = "127.0.0.1:0".parse().unwrap();
    let b_bind: std::net::SocketAddr = "127.0.0.1:0".parse().unwrap();
    // Use fixed tunnel ports to cross-wire peers.
    let a_tun: std::net::SocketAddr = "127.0.0.1:48101".parse().unwrap();
    let b_tun: std::net::SocketAddr = "127.0.0.1:48102".parse().unwrap();
    let _ = (a_bind, b_bind);
    let server = Stack::udp(b_tun, a_tun, [10, 0, 0, 2], [0x02, 0, 0, 0, 0, 2]).unwrap();
    let client = Stack::udp(a_tun, b_tun, [10, 0, 0, 1], [0x02, 0, 0, 0, 0, 1]).unwrap();
    let server_task = tokio::spawn(async move {
        let mut s = server.accept().await.unwrap();
        let mut buf = [0u8; 5];
        s.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"hello");
        s.write_all(b"world").await.unwrap();
        server
    });
    let mut c = client.connect([10, 0, 0, 2], tcp_sidecar::LISTEN_PORT).await.unwrap();
    c.write_all(b"hello").await.unwrap();
    let mut back = [0u8; 5];
    c.read_exact(&mut back).await.unwrap();
    assert_eq!(&back, b"world");
    let server = server_task.await.unwrap();
    let stats = server.stats();
    assert!(stats.frames_received > 0, "{stats:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tun_frontend_opens_or_skips() {
    use tcp_sidecar::Stack;
    match Stack::tun("", [10, 0, 0, 1]) {
        Ok(stack) => {
            let _ = stack.stats();
            println!("tun opened");
        }
        Err(e) => {
            println!("tun unavailable (expected without CAP_NET_ADMIN): {e}");
        }
    }
}
