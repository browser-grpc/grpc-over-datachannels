//! h3-terminator binary: QUIC endpoint bridging streams to
//! a TCP backend. HTTP/3 framing (h3) layers on these same
//! streams as the follow-up.
//!   h3-terminator --listen 127.0.0.1:4433 --backend 127.0.0.1:50051

use std::net::SocketAddr;

use grpc_dc_h3_terminator::{run_terminator, server_config};

fn arg(name: &str) -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    args.windows(2).find(|w| w[0] == name).map(|w| w[1].clone())
}

#[tokio::main]
async fn main() {
    let listen: SocketAddr = arg("--listen")
        .unwrap_or_else(|| "127.0.0.1:4433".into())
        .parse()
        .expect("--listen host:port");
    let backend: SocketAddr = arg("--backend")
        .unwrap_or_else(|| "127.0.0.1:50051".into())
        .parse()
        .expect("--backend host:port");
    let endpoint = quinn::Endpoint::server(server_config(), listen).expect("quic endpoint");
    println!("h3-terminator: quic {listen} -> tcp {backend} (self-signed, spike)");
    run_terminator(endpoint, backend).await;
}
