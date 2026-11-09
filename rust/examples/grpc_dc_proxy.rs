//! grpc-dc-proxy (Rust): TCP <-> DataChannel proxy, both
//! directions, homegrown HTTP/2 (grpc_dc::http2, generated).
//! No external gRPC or HTTP/2 dependencies. The TCP side is
//! h2c, or TLS with --tls-cert/--tls-key (direction 1) /
//! --http2-tls (direction 2; --insecure-skip-verify for
//! self-signed backends, --tls-ca for a private root).
//! The DataChannel side is WebRTC-Direct.
//!
//! Direction 1 — stock HTTP/2 gRPC clients call a grpc-dc
//! server (the proxy dials the server over WebRTC-Direct):
//!
//!   grpc_dc_proxy --dc-dial <multiaddr> --http2 50051
//!   grpc_dc_proxy --dc-dial <multiaddr> --http2 50051 --tls-cert c.pem --tls-key k.pem
//!
//! Direction 2 — grpc-dc clients call a stock HTTP/2 gRPC
//! server (the proxy listens over WebRTC-Direct):
//!
//!   grpc_dc_proxy --dc-listen 4001 --http2-dial 127.0.0.1:50051
//!   grpc_dc_proxy --dc-listen 4001 --http2-dial localhost:50051 --http2-tls
//!
//! Compression terminates in the proxy in both directions;
//! the DataChannel wire is always uncompressed.

use grpc_dc::endpoint::{Endpoint, StreamIdParity};
use grpc_dc::http2::proxy::{serve_dc_to_http2_conn, serve_h2_connection, serve_http2_to_dc};
use grpc_dc::http2::H2ClientConn;
use grpc_dc::Status;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName};
use std::io::BufReader;
use std::sync::Arc;
use tokio::net::TcpStream;

fn value(args: &[String], name: &str) -> Option<String> {
    args.windows(2).find(|w| w[0] == name).map(|w| w[1].clone())
}

fn load_certs(path: &str) -> Result<Vec<CertificateDer<'static>>, Box<dyn std::error::Error>> {
    let mut reader = BufReader::new(std::fs::File::open(path)?);
    Ok(rustls_pemfile::certs(&mut reader).collect::<Result<Vec<_>, _>>()?)
}

fn load_key(path: &str) -> Result<PrivateKeyDer<'static>, Box<dyn std::error::Error>> {
    let mut reader = BufReader::new(std::fs::File::open(path)?);
    Ok(rustls_pemfile::private_key(&mut reader)?
        .ok_or_else(|| Status::invalid_argument(format!("no private key in {path}")))?)
}

fn server_acceptor(
    cert_path: &str,
    key_path: &str,
) -> Result<tokio_rustls::TlsAcceptor, Box<dyn std::error::Error>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(load_certs(cert_path)?, load_key(key_path)?)?;
    config.alpn_protocols = vec![b"h2".to_vec()];
    Ok(tokio_rustls::TlsAcceptor::from(Arc::new(config)))
}

async fn backend_client(
    authority: &str,
    tls: bool,
    insecure: bool,
    ca_path: Option<&str>,
    server_name: &str,
) -> Result<H2ClientConn, Box<dyn std::error::Error>> {
    let tcp = TcpStream::connect(authority).await?;
    if !tls {
        return Ok(H2ClientConn::from_stream(tcp).await?);
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut roots = rustls::RootCertStore::empty();
    if let Some(path) = ca_path {
        for cert in load_certs(path)? {
            roots.add(cert)?;
        }
    } else if !insecure {
        // System root store: SSL_CERT_FILE or the usual
        // platform bundle paths (same approach as the WebRTC
        // stack's root store).
        let bundle = std::env::var("SSL_CERT_FILE").ok().filter(|p| std::path::Path::new(p).exists())
            .or_else(|| {
                ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
                 "/etc/ssl/cert.pem", "/usr/local/etc/openssl/cert.pem"]
                    .iter().find(|p| std::path::Path::new(p).exists()).map(|p| p.to_string())
            });
        if let Some(path) = bundle {
            for cert in load_certs(&path).unwrap_or_default() {
                let _ = roots.add(cert);
            }
        }
    }
    let builder = rustls::ClientConfig::builder();
    let mut config = if insecure {
        builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoVerify))
            .with_no_client_auth()
    } else {
        builder.with_root_certificates(roots).with_no_client_auth()
    };
    config.alpn_protocols = vec![b"h2".to_vec()];
    let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
    let name = ServerName::try_from(server_name.to_string())?;
    let stream = connector.connect(name, tcp).await?;
    Ok(H2ClientConn::from_stream(stream).await?)
}

#[derive(Debug)]
struct NoVerify;

impl rustls::client::danger::ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self,
        _end: &CertificateDer<'_>,
        _inter: &[CertificateDer<'_>],
        _name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _m: &[u8],
        _c: &CertificateDer<'_>,
        _d: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self,
        _m: &[u8],
        _c: &CertificateDer<'_>,
        _d: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::ED25519,
        ]
    }
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
        match (value(&args, "--tls-cert"), value(&args, "--tls-key")) {
            (Some(cert), Some(key)) => {
                let acceptor = server_acceptor(&cert, &key)?;
                loop {
                    let (socket, _) = listener.accept().await?;
                    let ep = endpoint.clone();
                    let acceptor = acceptor.clone();
                    tokio::spawn(async move {
                        match acceptor.accept(socket).await {
                            Ok(stream) => {
                                let _ = serve_h2_connection(stream, ep).await;
                            }
                            Err(e) => eprintln!("grpc-dc-proxy(rust): tls accept: {e}"),
                        }
                    });
                }
            }
            _ => serve_http2_to_dc(listener, endpoint).await?,
        }
        return Ok(());
    }

    if let Some(listen) = value(&args, "--dc-listen") {
        // Direction 2: grpc-dc clients -> HTTP/2 backend.
        let authority = value(&args, "--http2-dial")
            .ok_or_else(|| Status::invalid_argument("--http2-dial is required with --dc-listen"))?;
        let use_tls = args.iter().any(|a| a == "--http2-tls");
        let insecure = args.iter().any(|a| a == "--insecure-skip-verify");
        let ca = value(&args, "--tls-ca");
        let server_name = value(&args, "--tls-server-name")
            .unwrap_or_else(|| authority.split(':').next().unwrap_or("localhost").to_string());
        let client = Arc::new(
            backend_client(&authority, use_tls, insecure, ca.as_deref(), &server_name).await?,
        );
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
            let client = client.clone();
            tokio::spawn(async move {
                if let Err(e) = serve_dc_to_http2_conn(transport, client, &authority).await {
                    eprintln!("grpc-dc-proxy(rust): dc connection ended: {e}");
                }
            });
        }
    }

    eprintln!(
        "usage:\n  grpc_dc_proxy --dc-dial <multiaddr> [--http2 50051] [--host 127.0.0.1] [--tls-cert c.pem --tls-key k.pem]\n  grpc_dc_proxy --dc-listen <port> --http2-dial <host:port> [--http2-tls] [--tls-ca ca.pem] [--tls-server-name name] [--insecure-skip-verify]"
    );
    std::process::exit(2);
}
