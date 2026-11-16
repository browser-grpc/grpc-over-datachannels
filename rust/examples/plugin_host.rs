//! Host/plugin reference host (issue #2): one public endpoint,
//! out-of-process plugins behind it.
//!
//! Modes:
//!   plugin_host serve   — bind plugin.sock (one plugin) and
//!                         client.sock (many clients) in the
//!                         current directory (PLUGIN_DIR env
//!                         overrides). Each client connection
//!                         gets an endpoint with the Registry
//!                         service registered and /echo.Echo/
//!                         routed DC-to-DC to the plugin.
//!   plugin_host client  — dial client.sock, list services
//!                         via the Registry, then call Echo
//!                         (which is served by the plugin).
//!
//! The plugin is examples/plugin-host/plugin.mjs (Node):
//!   node examples/plugin-host/plugin.mjs
//!   cargo run --features webrtc --example plugin_host -- serve
//!   cargo run --features webrtc --example plugin_host -- client

#[cfg(not(feature = "webrtc"))]
fn main() {
    eprintln!("plugin_host needs --features webrtc");
}

#[cfg(feature = "webrtc")]
#[path = "../gen/echo_pb.rs"]
mod pb;

#[cfg(feature = "webrtc")]
#[path = "echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[cfg(feature = "webrtc")]
#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

#[cfg(feature = "webrtc")]
use grpc_dc::dynamic::{parse_descriptor_set, DynamicClient, GenericMessage};
#[cfg(feature = "webrtc")]
use grpc_dc::endpoint::{Endpoint, StreamIdParity};
#[cfg(feature = "webrtc")]
use grpc_dc::{route_prefix, uds_dc, uds_dc_accept, Channel, DcTransport, Registry};
#[cfg(feature = "webrtc")]
use std::sync::Arc;
#[cfg(feature = "webrtc")]
use stub::EchoClient;

#[cfg(feature = "webrtc")]
fn plugin_dir() -> std::path::PathBuf {
    std::env::var("PLUGIN_DIR").map(std::path::PathBuf::from).unwrap_or_else(|_| std::path::PathBuf::from("."))
}

#[cfg(feature = "webrtc")]
#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mode = std::env::args().nth(1).unwrap_or_else(|| "serve".to_string());
    let dir = plugin_dir();
    match mode.as_str() {
        "serve" => serve(dir).await,
        "client" => client(dir).await,
        other => Err(format!("unknown mode {other} (serve|client)").into()),
    }
}

#[cfg(feature = "webrtc")]
async fn serve(dir: std::path::PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let plugin_sock = dir.join("plugin.sock");
    let client_sock = dir.join("client.sock");
    let _ = std::fs::remove_file(&plugin_sock);
    let _ = std::fs::remove_file(&client_sock);

    // Plugin side: accept one plugin, build its client endpoint.
    let plugin_listener = tokio::net::UnixListener::bind(&plugin_sock)?;
    let (plugin_stream, _) = plugin_listener.accept().await?;
    let plugin_ep = Endpoint::new(Arc::new(uds_dc_accept(plugin_stream)), StreamIdParity::Odd);
    tokio::spawn(plugin_ep.clone().run());
    eprintln!("host: plugin connected");

    // Discovery store: the Echo descriptor (from the repo
    // fixtures in this example; hosts register whatever
    // descriptors their plugins announce in real deployments).
    let registry = Arc::new(Registry::new());
    let echo_descriptor = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../fixtures/echo_descriptor_set.bin"
    ))?;
    registry.register_descriptor("echo.Echo", echo_descriptor);

    let client_listener = tokio::net::UnixListener::bind(&client_sock)?;
    eprintln!("host: serving clients on {}", client_sock.display());
    loop {
        let (stream, _) = client_listener.accept().await?;
        let ep = Endpoint::new(Arc::new(uds_dc_accept(stream)), StreamIdParity::Even);
        ep.register_service(registry.service(ep.clone()));
        route_prefix(&ep, "/echo.Echo/", plugin_ep.clone());
        tokio::spawn(ep.run());
    }
}

#[cfg(feature = "webrtc")]
async fn client(dir: std::path::PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let transport: Arc<dyn DcTransport> = Arc::new(uds_dc(dir.join("client.sock")).await?);
    let channel = Channel::new(transport);

    // Discovery first: what does the host serve?
    let model = parse_descriptor_set(grpc_dc::REGISTRY_DESCRIPTOR_SET)?;
    let registry = DynamicClient::new(channel.clone(), Arc::new(model));
    let listed = registry
        .unary(
            "grpcdc.registry.v1.Registry",
            "ListServices",
            GenericMessage::new(),
        )
        .await?;
    let names: Vec<String> = listed
        .get_all(1)
        .iter()
        .map(|v| format!("{v:?}"))
        .collect();
    println!("services: {}", names.join(", "));

    // Then the plugin's Echo, routed by the host.
    let echo = EchoClient::new(channel);
    let resp = echo
        .unary(pb::EchoRequest { message: "from-host-client".into(), ..Default::default() })
        .await?;
    println!("echo: {}", resp.message);
    Ok(())
}
