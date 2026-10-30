//! Kafka over gRPC proxy.
//!
//! The gRPC side uses the generated `grpcdc.kafka.v1.Kafka`
//! service. The Kafka side uses the dependency-free protocol
//! implementation in this directory and connects to Apache
//! Kafka or Redpanda over TCP.
//!
//! Examples:
//!   cargo run --example kafka_proxy -- --stdio --broker 127.0.0.1:9092
//!   cargo run --example kafka_proxy -- \
//!       --tcp 127.0.0.1:50201 --broker 127.0.0.1:9092
//!   cargo run --features webrtc --example kafka_proxy -- \
//!       --webrtc-direct 127.0.0.1:4433 --broker 127.0.0.1:9092
//!
//! The `--tcp` mode speaks the same u32 big-endian length-prefixed
//! framing as `--stdio` (and as the `direct_sidecar` TCP bridge),
//! so every generated client's SidecarTransport can reach it.
//!
//! SASL:
//!   --sasl-plain USER PASS
//!   --sasl-scram-sha-256 USER PASS
//!   --sasl-scram-sha-512 USER PASS

#[path = "../../gen/kafka_pb.rs"]
mod pb;

#[path = "pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../../gen/kafka_grpc_dc.rs"]
mod stub;

mod client;
mod codecs;
mod crypto;
mod service;
mod wire;

use bytes::Bytes;
use client::{KafkaConfig, SaslConfig, TlsConfig};
use grpc_dc::{DcTransport, Server, Status};
use service::KafkaService;
use std::net::SocketAddr;
use std::sync::Arc;
use stub::kafka_service;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct StdioDc {
    tx: tokio::sync::Mutex<tokio::io::Stdout>,
    rx: tokio::sync::Mutex<tokio::io::Stdin>,
}

#[grpc_dc::async_trait]
impl DcTransport for StdioDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        let mut tx = self.tx.lock().await;
        tx.write_u32(msg.len() as u32)
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        tx.write_all(&msg)
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        tx.flush()
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        Ok(())
    }

    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut rx = self.rx.lock().await;
        let len = match rx.read_u32().await {
            Ok(n) => n as usize,
            Err(_) => return None,
        };
        let mut buf = vec![0u8; len];
        match rx.read_exact(&mut buf).await {
            Ok(_) => Some(Ok(Bytes::from(buf))),
            Err(e) => Some(Err(Status::unavailable(format!("stdio read: {e}")))),
        }
    }
}

/// One accepted length-prefixed TCP connection as a DcTransport.
struct TcpDc {
    tx: tokio::sync::Mutex<tokio::net::tcp::OwnedWriteHalf>,
    rx: tokio::sync::Mutex<tokio::net::tcp::OwnedReadHalf>,
}

#[grpc_dc::async_trait]
impl DcTransport for TcpDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        let mut tx = self.tx.lock().await;
        tx.write_u32(msg.len() as u32)
            .await
            .map_err(|e| Status::unavailable(format!("tcp write: {e}")))?;
        tx.write_all(&msg)
            .await
            .map_err(|e| Status::unavailable(format!("tcp write: {e}")))?;
        tx.flush()
            .await
            .map_err(|e| Status::unavailable(format!("tcp write: {e}")))?;
        Ok(())
    }

    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut rx = self.rx.lock().await;
        let len = match rx.read_u32().await {
            Ok(n) => n as usize,
            Err(_) => return None,
        };
        let mut buf = vec![0u8; len];
        match rx.read_exact(&mut buf).await {
            Ok(_) => Some(Ok(Bytes::from(buf))),
            Err(e) => Some(Err(Status::unavailable(format!("tcp read: {e}")))),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HostMode {
    Stdio,
    Tcp,
    WebRtcDirect,
}

#[derive(Debug)]
struct Options {
    broker: String,
    client_id: String,
    sasl: Option<SaslConfig>,
    tls_ca_cert: Option<String>,
    tls_server_name: Option<String>,
    tls_insecure_skip_verify: bool,
    mode: HostMode,
    tcp_addr: SocketAddr,
    webrtc_addr: SocketAddr,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            broker: "127.0.0.1:9092".to_string(),
            client_id: "grpc-dc-kafka-proxy".to_string(),
            sasl: None,
            tls_ca_cert: None,
            tls_server_name: None,
            tls_insecure_skip_verify: false,
            mode: HostMode::Stdio,
            tcp_addr: "127.0.0.1:0".parse().expect("valid default address"),
            webrtc_addr: "127.0.0.1:0".parse().expect("valid default address"),
        }
    }
}

impl Options {
    fn parse(args: &[String]) -> Result<Self, String> {
        let mut options = Self::default();
        let mut index = 0;
        while index < args.len() {
            let arg = &args[index];
            let mut value = |index: &mut usize| -> Result<String, String> {
                *index += 1;
                args.get(*index)
                    .cloned()
                    .ok_or_else(|| format!("missing value for {arg}"))
            };
            match arg.as_str() {
                "--broker" => options.broker = value(&mut index)?,
                "--client-id" => options.client_id = value(&mut index)?,
                "--stdio" => options.mode = HostMode::Stdio,
                "--tcp" => {
                    options.mode = HostMode::Tcp;
                    let value = value(&mut index)?;
                    options.tcp_addr = value
                        .parse()
                        .map_err(|error| format!("invalid --tcp address: {error}"))?;
                }
                "--webrtc-direct" => {
                    options.mode = HostMode::WebRtcDirect;
                    let value = value(&mut index)?;
                    options.webrtc_addr = value
                        .parse()
                        .map_err(|error| format!("invalid --webrtc-direct address: {error}"))?;
                }
                "--sasl-plain" => {
                    let username = value(&mut index)?;
                    let password = value(&mut index)?;
                    options.sasl = Some(SaslConfig::Plain { username, password });
                }
                "--sasl-scram-sha-256" => {
                    let username = value(&mut index)?;
                    let password = value(&mut index)?;
                    options.sasl = Some(SaslConfig::Scram {
                        mechanism: "SCRAM-SHA-256".to_string(),
                        username,
                        password,
                    });
                }
                "--sasl-scram-sha-512" => {
                    let username = value(&mut index)?;
                    let password = value(&mut index)?;
                    options.sasl = Some(SaslConfig::Scram {
                        mechanism: "SCRAM-SHA-512".to_string(),
                        username,
                        password,
                    });
                }
                "--tls-ca-cert" => options.tls_ca_cert = Some(value(&mut index)?),
                "--tls-server-name" => options.tls_server_name = Some(value(&mut index)?),
                "--tls-insecure-skip-verify" => options.tls_insecure_skip_verify = true,
                "--help" | "-h" => return Err(usage()),
                _ => return Err(format!("unknown argument {arg}\n\n{}", usage())),
            }
            index += 1;
        }
        Ok(options)
    }
}

fn usage() -> String {
    "Usage: kafka_proxy [--stdio | --tcp ADDR | --webrtc-direct ADDR]\n\
     [--broker HOST:PORT] [--client-id ID] [--sasl-plain USER PASS |\n\
     --sasl-scram-sha-256 USER PASS | --sasl-scram-sha-512 USER PASS]\n\
     [--tls-ca-cert PEM | --tls-insecure-skip-verify] [--tls-server-name NAME]"
        .to_string()
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let options = match Options::parse(&args) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(2);
        }
    };

    let tls = if options.tls_ca_cert.is_some()
        || options.tls_server_name.is_some()
        || options.tls_insecure_skip_verify
    {
        Some(TlsConfig {
            ca_cert: options.tls_ca_cert,
            server_name: options.tls_server_name,
            insecure_skip_verify: options.tls_insecure_skip_verify,
        })
    } else {
        None
    };
    let service = Arc::new(KafkaService::new(KafkaConfig {
        broker: options.broker,
        client_id: options.client_id,
        sasl: options.sasl,
        tls,
    }));

    match options.mode {
        HostMode::Stdio => {
            let transport: Arc<dyn DcTransport> = Arc::new(StdioDc {
                tx: tokio::sync::Mutex::new(tokio::io::stdout()),
                rx: tokio::sync::Mutex::new(tokio::io::stdin()),
            });
            Server::serve(transport, vec![kafka_service(service)]).await;
        }
        HostMode::Tcp => {
            serve_tcp(service, options.tcp_addr).await?;
        }
        HostMode::WebRtcDirect => {
            serve_webrtc_direct(service, options.webrtc_addr).await?;
        }
    }
    Ok(())
}

async fn serve_tcp(
    service: Arc<KafkaService>,
    addr: SocketAddr,
) -> Result<(), Box<dyn std::error::Error>> {
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("kafka proxy listening on tcp {}", listener.local_addr()?);
    loop {
        let (socket, _) = listener.accept().await?;
        let service = service.clone();
        tokio::spawn(async move {
            let (read_half, write_half) = socket.into_split();
            let transport: Arc<dyn DcTransport> = Arc::new(TcpDc {
                tx: tokio::sync::Mutex::new(write_half),
                rx: tokio::sync::Mutex::new(read_half),
            });
            Server::serve(transport, vec![kafka_service(service)]).await;
        });
    }
}

#[cfg(feature = "webrtc")]
async fn serve_webrtc_direct(
    service: Arc<KafkaService>,
    addr: SocketAddr,
) -> Result<(), Box<dyn std::error::Error>> {
    use grpc_dc::webrtc_direct::{accept_direct_transport, direct_listener};

    let listener = Arc::new(direct_listener(addr)?);
    println!("{}", listener.multiaddr());
    loop {
        let transport = accept_direct_transport(listener.clone()).await?;
        let service = service.clone();
        tokio::spawn(async move {
            Server::serve(transport, vec![kafka_service(service)]).await;
        });
    }
}

#[cfg(not(feature = "webrtc"))]
async fn serve_webrtc_direct(
    _service: Arc<KafkaService>,
    _addr: SocketAddr,
) -> Result<(), Box<dyn std::error::Error>> {
    Err("kafka_proxy was built without the `webrtc` feature".into())
}
