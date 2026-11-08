//! grpc-dc-proxy (Rust): TCP <-> DataChannel proxy, both
//! directions, homegrown HTTP/2 (grpc_dc::http2, generated).
//! No external gRPC or HTTP/2 dependencies; cleartext h2c on
//! the TCP side, WebRTC-Direct on the DataChannel side.
//!
//! Direction 1 — stock HTTP/2 gRPC clients call a grpc-dc
//! server (the proxy dials the server over WebRTC-Direct):
//!
//!   grpc_dc_proxy --dc-dial <multiaddr> --http2 50051
//!
//! Direction 2 — grpc-dc clients call a stock HTTP/2 gRPC
//! server (the proxy listens over WebRTC-Direct):
//!
//!   grpc_dc_proxy --dc-listen 4001 --http2-dial 127.0.0.1:50051
//!
//! Compression terminates in the proxy in both directions;
//! the DataChannel wire is always uncompressed.

use grpc_dc::endpoint::{Endpoint, StreamIdParity};
use grpc_dc::http2::proxy::{serve_dc_to_http2, serve_http2_to_dc};
use grpc_dc::Status;
use std::sync::Arc;

fn value(args: &[String], name: &str) -> Option<String> {
    args.windows(2).find(|w| w[0] == name).map(|w| w[1].clone())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if let Some(multiaddr) = value(&args, "--dc-dial") {
        // Direction 1: HTTP/2 ingress -> grpc-dc server.
        let port: u16 = value(&args, "--http2").unwrap_or_else(|| "50051".into()).parse()?;
        let host = value(&args, "--host").unwrap_or_else(|| "127.0.0.1".into());
        let transport = grpc_dc::webrtc_direct::direct_client(&multiaddr).await?;
        let endpoint = Endpoint::new(transport, StreamIdParity::Odd);
        tokio::spawn(endpoint.clone().run());
        let listener = tokio::net::TcpListener::bind(format!("{host}:{port}")).await?;
        eprintln!("grpc-dc-proxy(rust): ingress http2={}:{} -> grpc-dc server", host, port);
        serve_http2_to_dc(listener, endpoint).await?;
        return Ok(());
    }

    if let Some(listen) = value(&args, "--dc-listen") {
        // Direction 2: grpc-dc clients -> HTTP/2 backend.
        let authority = value(&args, "--http2-dial")
            .ok_or_else(|| Status::invalid_argument("--http2-dial is required with --dc-listen"))?;
        let addr: std::net::SocketAddr = format!("127.0.0.1:{listen}").parse()?;
        let listener = Arc::new(grpc_dc::webrtc_direct::direct_listener(addr)?);
        eprintln!(
            "grpc-dc-proxy(rust): dc-listen {} ({}) -> http2 {}",
            addr,
            listener.multiaddr(),
            authority
        );
        loop {
            let transport = grpc_dc::webrtc_direct::accept_direct_transport(listener.clone()).await?;
            let authority = authority.clone();
            tokio::spawn(async move {
                if let Err(e) = serve_dc_to_http2(transport, &authority).await {
                    eprintln!("grpc-dc-proxy(rust): dc connection ended: {e}");
                }
            });
        }
    }

    eprintln!(
        "usage:\n  grpc_dc_proxy --dc-dial <multiaddr> [--http2 50051] [--host 127.0.0.1]\n  grpc_dc_proxy --dc-listen <port> --http2-dial <host:port>"
    );
    std::process::exit(2);
}
