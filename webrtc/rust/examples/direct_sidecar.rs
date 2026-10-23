//! WebRTC-Direct sidecar: the Rust stack as a service for every
//! other generated language.
//!
//! It owns DTLS/SCTP/TURN (via `dc_webrtc::direct`) and bridges
//! one "grpc" datachannel to a local TCP socket using u32
//! big-endian length-prefixed messages (one prefix per
//! DataChannel message, boundaries preserved). A generated
//! runtime in any language only needs stdlib TCP + that framing
//! (see `grpcdc.sidecar.SidecarTransport` in Python) to be a
//! WebRTC-Direct client or server, including over TURN.
//!
//! Client shape (this side dials the Direct listener):
//!   direct_sidecar dial --multiaddr /ip4/.../webrtc-direct/certhash/f... \
//!       --tcp 127.0.0.1:50051 [--turn host:port user pass]
//! The language client connects to 127.0.0.1:50051.
//!
//! Server shape (this side is the Direct listener):
//!   direct_sidecar listen --udp 0.0.0.0:4001 --tcp 127.0.0.1:50052
//! prints `MULTIADDR /ip4/...` on stdout; the language server
//! listens on 127.0.0.1:50052 and accepts one framed TCP
//! connection per Direct connection.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::direct::{direct_dial_multiaddr, direct_dial_turn_multiaddr, DirectListener};
use dc_webrtc::endpoint::{ChannelHandle, DcEndpoint, EndpointEvent};
use dc_webrtc::turn::TurnServerConfig;
use dc_webrtc::x509::Certificate;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::time::Duration;

fn arg(args: &[String], name: &str) -> Option<String> {
    args.windows(2).find(|w| w[0] == name).map(|w| w[1].clone())
}

fn bridge(endpoint: Arc<DcEndpoint>, channel: ChannelHandle, tcp: TcpStream) -> io::Result<()> {
    let stream_id = channel.stream;
    let mut reader = tcp.try_clone()?;
    let mut writer = tcp;
    let chan = channel.clone();
    let tcp_to_dc = std::thread::spawn(move || loop {
        let mut len_buf = [0u8; 4];
        if reader.read_exact(&mut len_buf).is_err() {
            break;
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        let mut payload = vec![0u8; len];
        if reader.read_exact(&mut payload).is_err() || chan.send_binary(&payload).is_err() {
            break;
        }
    });
    loop {
        match endpoint.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::Message { stream, data, .. }) if stream == stream_id => {
                writer.write_all(&(data.len() as u32).to_be_bytes())?;
                writer.write_all(&data)?;
                writer.flush()?;
            }
            Some(EndpointEvent::ChannelClosed { stream }) if stream == stream_id => break,
            Some(_) => {}
            None => {
                if tcp_to_dc.is_finished() {
                    break;
                }
            }
        }
    }
    endpoint.shutdown();
    Ok(())
}

fn wait_channel(endpoint: &DcEndpoint) -> io::Result<ChannelHandle> {
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    while std::time::Instant::now() < deadline {
        match endpoint.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::ChannelOpened { channel }) => return Ok(channel),
            Some(_) => continue,
            None => continue,
        }
    }
    Err(io::Error::new(io::ErrorKind::TimedOut, "no channel opened"))
}

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(|s| s.as_str()).unwrap_or("");
    match mode {
        "dial" => {
            let multiaddr = arg(&args, "--multiaddr").expect("--multiaddr required");
            let tcp_addr: SocketAddr = arg(&args, "--tcp")
                .expect("--tcp required")
                .parse()
                .expect("bad --tcp address");
            let turn = match (arg(&args, "--turn"), arg(&args, "--turn-user"), arg(&args, "--turn-pass")) {
                (Some(addr), Some(user), Some(pass)) => Some(TurnServerConfig::new(&addr, &user, &pass)),
                _ => None,
            };
            let listener = TcpListener::bind(tcp_addr)?;
            println!("TCP {}", listener.local_addr()?);
            use std::io::BufRead;
            let _ = io::stdout().flush();
            // One thread per language connection: each dials its
            // own Direct session, so several language clients can
            // be in flight through this one sidecar at once.
            for conn in listener.incoming() {
                let tcp = conn?;
                let multiaddr = multiaddr.clone();
                let turn = turn.clone();
                std::thread::spawn(move || {
                    let cert = Certificate::generate_self_signed("grpc-dc-sidecar");
                    let endpoint = match &turn {
                        Some(cfg) => direct_dial_turn_multiaddr(&multiaddr, cert, cfg)?,
                        None => direct_dial_multiaddr(&multiaddr, cert)?,
                    };
                    let endpoint = Arc::new(endpoint);
                    let channel = endpoint
                        .open_channel(ChannelParams { label: "grpc".into(), ..Default::default() })?;
                    bridge(endpoint, channel, tcp)
                });
            }
            let _ = io::BufReader::new(io::stdin());
            Ok(())
        }
        "listen" => {
            let udp_addr: SocketAddr = arg(&args, "--udp")
                .expect("--udp required")
                .parse()
                .expect("bad --udp address");
            let lang_addr: SocketAddr = arg(&args, "--tcp")
                .expect("--tcp required")
                .parse()
                .expect("bad --tcp address");
            let listener = DirectListener::bind(udp_addr, Certificate::generate_self_signed("grpc-dc"))?;
            println!("MULTIADDR {}", listener.multiaddr());
            io::stdout().flush()?;
            // One thread per accepted Direct connection: each
            // gets its own TCP connection to the language server,
            // so concurrent dialers are served concurrently.
            loop {
                let endpoint = Arc::new(listener.accept()?);
                std::thread::spawn(move || {
                    let channel = wait_channel(&endpoint)?;
                    let tcp = TcpStream::connect(lang_addr)?;
                    bridge(endpoint, channel, tcp)
                });
            }
        }
        _ => {
            eprintln!("usage: direct_sidecar dial --multiaddr MA --tcp A [--turn A --turn-user U --turn-pass P]");
            eprintln!("       direct_sidecar listen --udp A --tcp A");
            std::process::exit(2);
        }
    }
}
