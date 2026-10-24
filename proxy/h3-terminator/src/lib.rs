//! QUIC termination for grpc-dc-proxy: a quinn endpoint
//! (self-signed in this spike) accepts QUIC connections and
//! bridges every bidirectional stream to a plain TCP backend.
//! This terminates the QUIC layer in the proxy — exactly
//! where HTTP/3 termination will sit; the h3 framing layer
//! on top of these streams is the follow-up.

use std::net::SocketAddr;
use std::sync::Arc;

use quinn::{ClientConfig, Connection, Endpoint, ServerConfig};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

pub fn server_config() -> ServerConfig {
    let certified = rcgen::generate_simple_self_signed(vec!["localhost".to_string()])
        .expect("self-signed certificate");
    let cert = CertificateDer::from(certified.cert.der().to_vec());
    let key = PrivateKeyDer::try_from(certified.signing_key.serialize_der())
        .expect("self-signed key");
    ServerConfig::with_single_cert(vec![cert], key).expect("server config")
}

/// Client config that skips certificate verification
/// (spike only; production pins the proxy certificate).
pub fn insecure_client_config() -> ClientConfig {
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let crypto = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("protocol versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(SkipVerification))
        .with_no_client_auth();
    ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(crypto).expect("quic client config"),
    ))
}

#[derive(Debug)]
struct SkipVerification;

impl rustls::client::danger::ServerCertVerifier for SkipVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::aws_lc_rs::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// Accept QUIC connections forever; bridge each bidi stream
/// to a fresh TCP connection to `backend`.
pub async fn run_terminator(endpoint: Endpoint, backend: SocketAddr) {
    while let Some(connecting) = endpoint.accept().await {
        tokio::spawn(async move {
            let conn = match connecting.await {
                Ok(conn) => conn,
                Err(_) => return,
            };
            handle_connection(conn, backend).await;
        });
    }
}

async fn handle_connection(conn: Connection, backend: SocketAddr) {
    while let Ok((send, recv)) = conn.accept_bi().await {
        tokio::spawn(async move {
            let tcp = match TcpStream::connect(backend).await {
                Ok(tcp) => tcp,
                Err(_) => return,
            };
            let _ = bridge(send, recv, tcp).await;
        });
    }
}

async fn bridge(
    mut send: quinn::SendStream,
    mut recv: quinn::RecvStream,
    tcp: TcpStream,
) -> std::io::Result<()> {
    let (mut tcp_read, mut tcp_write) = tcp.into_split();
    let quic_to_tcp = async move {
        while let Some(chunk) = recv.read_chunk(64 * 1024, true).await.map_err(to_io)? {
            tcp_write.write_all(&chunk.bytes).await?;
        }
        tcp_write.shutdown().await
    };
    let tcp_to_quic = async move {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = tcp_read.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            send.write_all(&buf[..n]).await.map_err(to_io)?;
        }
        send.finish().map_err(to_io)
    };
    tokio::try_join!(quic_to_tcp, tcp_to_quic)?;
    Ok(())
}

fn to_io<E: std::fmt::Display>(err: E) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Other, err.to_string())
}
