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
//!
//! Browser shape (this side answers HTTP/POST signaling):
//!   direct_sidecar signal --http 127.0.0.1:8080 --tcp 127.0.0.1:50052
//! serves POST /grpc-dc/signal (+ /candidate, /restart) on one
//! shared PeerMux socket; each browser session is bridged to
//! the language server over its own framed TCP connection, so
//! any generated language server becomes browser-reachable.
//! Auth/CORS stay with the host serving the page.
//!
//! Browser shape with no signaling at all (Rendezvous):
//!   direct_sidecar rendezvous --udp 0.0.0.0:4001 --tcp 127.0.0.1:50052 \
//!       [--host 203.0.113.10] [--ufrag U --pwd P]
//! prints `RENDEZVOUS {"host":...,"port":...}` on stdout: the
//! fixed descriptor browsers dial with rendezvousChannel.
//! Each browser session is bridged to the language server
//! over its own framed TCP connection, like signal mode.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::direct::{direct_dial_multiaddr, direct_dial_turn_multiaddr, DirectListener};
use dc_webrtc::endpoint::{ChannelHandle, DcEndpoint, EndpointEvent};
use dc_webrtc::mux::PeerMux;
use dc_webrtc::peer::{PeerConfig, RestartHandle};
use dc_webrtc::rendezvous::{RendezvousListener, RendezvousOptions};
use dc_webrtc::turn::TurnServerConfig;
use dc_webrtc::x509::Certificate;
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
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

// ---- signal mode: minimal HTTP/JSON (std-only, mirrors the
// generated rust http_signaling contract) ----

struct SignalSession {
    trickle_tx: Mutex<Option<Sender<String>>>,
    restart: Mutex<Option<RestartHandle>>,
}

type SignalSessions = Arc<Mutex<HashMap<String, Arc<SignalSession>>>>;

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\r' => out.push_str("\\r"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn json_string_field(body: &str, field: &str) -> Option<String> {
    let needle = format!("\"{field}\"");
    let after_key = &body[body.find(&needle)? + needle.len()..];
    let after_colon = after_key.trim_start().strip_prefix(':')?.trim_start();
    let mut chars = after_colon.chars();
    if chars.next()? != '"' {
        return None;
    }
    let mut out = String::new();
    let mut rest = chars.as_str();
    loop {
        let mut it = rest.chars();
        match it.next()? {
            '"' => return Some(out),
            '\\' => {
                let esc = it.next()?;
                rest = it.as_str();
                match esc {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'b' => out.push('\u{0008}'),
                    'f' => out.push('\u{000C}'),
                    'u' => {
                        let hex = rest.get(..4)?;
                        out.push(char::from_u32(u32::from_str_radix(hex, 16).ok()?)?);
                        rest = &rest[4..];
                        continue;
                    }
                    _ => return None,
                }
            }
            c => {
                out.push(c);
                rest = it.as_str();
            }
        }
    }
}

fn signal_write(stream: &mut TcpStream, status: u16, body: &str) {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        _ => "Method Not Allowed",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body.as_bytes());
}

fn signal_handle(
    mut stream: TcpStream,
    mux: Arc<PeerMux>,
    sessions: SignalSessions,
    stun: Option<String>,
    lang_addr: SocketAddr,
) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let header_end = loop {
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > (1 << 20) {
            return;
        }
        match stream.read(&mut chunk) {
            Ok(0) => return,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(_) => return,
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or("");
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let request_path = parts.next().unwrap_or("").to_string();
    if method != "POST" {
        signal_write(&mut stream, 405, "{\"error\":\"method not allowed\"}");
        return;
    }
    let content_length = lines
        .filter_map(|line| {
            let (name, value) = line.split_once(':')?;
            if name.trim().eq_ignore_ascii_case("content-length") {
                value.trim().parse::<usize>().ok()
            } else {
                None
            }
        })
        .next()
        .unwrap_or(0);
    let mut body = buf.split_off(header_end);
    while body.len() < content_length {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => body.extend_from_slice(&chunk[..n]),
            Err(_) => return,
        }
    }
    body.truncate(content_length);
    let body_text = String::from_utf8_lossy(&body).to_string();

    if request_path == "/grpc-dc/signal/candidate" || request_path == "/grpc-dc/signal/restart" {
        let session_id = json_string_field(&body_text, "session").unwrap_or_default();
        let session = sessions.lock().unwrap().get(&session_id).cloned();
        let session = match session {
            Some(s) => s,
            None => {
                signal_write(&mut stream, 404, "{\"error\":\"unknown session\"}");
                return;
            }
        };
        if request_path.ends_with("/candidate") {
            let candidate = json_string_field(&body_text, "candidate").unwrap_or_default();
            if let Some(tx) = session.trickle_tx.lock().unwrap().as_ref() {
                let _ = tx.send(candidate);
            }
            signal_write(&mut stream, 200, "{\"ok\":true}");
            return;
        }
        let sdp = json_string_field(&body_text, "sdp").unwrap_or_default();
        let answer = {
            let restart = session.restart.lock().unwrap();
            restart.as_ref().and_then(|h| h.handle_restart_offer(&sdp).ok())
        };
        match answer {
            Some(answer) => signal_write(
                &mut stream,
                200,
                &format!(
                    "{{\"type\":\"answer\",\"sdp\":\"{}\",\"session\":\"{}\"}}",
                    json_escape(&answer),
                    json_escape(&session_id)
                ),
            ),
            None => signal_write(&mut stream, 400, "{\"error\":\"invalid restart offer SDP\"}"),
        }
        return;
    }
    if request_path != "/grpc-dc/signal" {
        signal_write(&mut stream, 404, "{\"error\":\"not found\"}");
        return;
    }
    let offer_sdp = match json_string_field(&body_text, "sdp") {
        Some(sdp) if !sdp.is_empty() => sdp,
        _ => {
            signal_write(&mut stream, 400, "{\"error\":\"expected offer\"}");
            return;
        }
    };
    let mut config = PeerConfig::default();
    if let Some(stun) = &stun {
        config.stun_servers = vec![stun.clone()];
    }
    let mut peer = match mux.new_peer(config) {
        Ok(p) => p,
        Err(_) => {
            signal_write(&mut stream, 400, "{\"error\":\"peer creation failed\"}");
            return;
        }
    };
    let answer = match peer.handle_offer(&offer_sdp) {
        Ok(a) => a,
        Err(_) => {
            signal_write(&mut stream, 400, "{\"error\":\"invalid offer SDP\"}");
            return;
        }
    };
    static SEQ: AtomicU64 = AtomicU64::new(1);
    let session_id = format!("s{}-{}", std::process::id(), SEQ.fetch_add(1, Ordering::Relaxed));
    let (trickle_tx, trickle_rx) = channel();
    let session = Arc::new(SignalSession {
        trickle_tx: Mutex::new(Some(trickle_tx)),
        restart: Mutex::new(None),
    });
    sessions.lock().unwrap().insert(session_id.clone(), session.clone());
    signal_write(
        &mut stream,
        200,
        &format!(
            "{{\"type\":\"answer\",\"sdp\":\"{}\",\"session\":\"{}\"}}",
            json_escape(&answer),
            json_escape(&session_id)
        ),
    );
    let registry = sessions.clone();
    let registry_id = session_id.clone();
    std::thread::spawn(move || {
        let result = (|| -> io::Result<()> {
            let (endpoint, restart) = peer.connect_trickled_with_handle(trickle_rx)?;
            *session.restart.lock().unwrap() = Some(restart);
            *session.trickle_tx.lock().unwrap() = None;
            let endpoint = Arc::new(endpoint);
            let channel = wait_channel(&endpoint)?;
            let tcp = TcpStream::connect(lang_addr)?;
            bridge(endpoint, channel, tcp)
        })();
        registry.lock().unwrap().remove(&registry_id);
        if let Err(e) = &result {
            eprintln!("signal session {registry_id} failed: {e}");
        }
        result
    });
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
        "signal" => {
            let http_addr: SocketAddr = arg(&args, "--http")
                .expect("--http required")
                .parse()
                .expect("bad --http address");
            let udp_addr: SocketAddr = arg(&args, "--udp")
                .unwrap_or_else(|| "0.0.0.0:0".to_string())
                .parse()
                .expect("bad --udp address");
            let lang_addr: SocketAddr = arg(&args, "--tcp")
                .expect("--tcp required")
                .parse()
                .expect("bad --tcp address");
            let stun = arg(&args, "--stun");
            let mux = Arc::new(PeerMux::bind(udp_addr)?);
            let listener = TcpListener::bind(http_addr)?;
            println!(
                "SIGNAL http://{}/grpc-dc/signal udp {}",
                listener.local_addr()?,
                mux.local_addr()
            );
            io::stdout().flush()?;
            let sessions: SignalSessions = Arc::new(Mutex::new(HashMap::new()));
            for conn in listener.incoming() {
                let stream = conn?;
                let mux = mux.clone();
                let sessions = sessions.clone();
                let stun = stun.clone();
                std::thread::spawn(move || signal_handle(stream, mux, sessions, stun, lang_addr));
            }
            Ok(())
        }
        "rendezvous" => {
            let udp_addr: SocketAddr = arg(&args, "--udp")
                .expect("--udp required")
                .parse()
                .expect("bad --udp address");
            let lang_addr: SocketAddr = arg(&args, "--tcp")
                .expect("--tcp required")
                .parse()
                .expect("bad --tcp address");
            // The published host: --host, else this host's
            // default-route IPv4 (as a deployment publishes
            // its public address).
            let host = arg(&args, "--host").unwrap_or_else(|| {
                std::net::UdpSocket::bind("0.0.0.0:0")
                    .and_then(|s| {
                        s.connect("8.8.8.8:53")?;
                        s.local_addr()
                    })
                    .map(|a| a.ip().to_string())
                    .unwrap_or_else(|_| "127.0.0.1".to_string())
            });
            let listener = RendezvousListener::bind(
                udp_addr,
                RendezvousOptions {
                    ice_ufrag: arg(&args, "--ufrag"),
                    ice_pwd: arg(&args, "--pwd"),
                    on_endpoint: Box::new(move |endpoint| {
                        let endpoint = Arc::new(endpoint);
                        std::thread::spawn(move || -> io::Result<()> {
                            let channel = wait_channel(&endpoint)?;
                            let tcp = TcpStream::connect(lang_addr)?;
                            bridge(endpoint, channel, tcp)
                        });
                    }),
                    on_error: Box::new(|e| eprintln!("rendezvous session failed: {e}")),
                    ..Default::default()
                },
            )?;
            println!("RENDEZVOUS {}", listener.descriptor(&host).to_json());
            io::stdout().flush()?;
            loop {
                std::thread::sleep(Duration::from_secs(3600));
            }
        }
        _ => {
            eprintln!("usage: direct_sidecar dial --multiaddr MA --tcp A [--turn A --turn-user U --turn-pass P]");
            eprintln!("       direct_sidecar listen --udp A --tcp A");
            eprintln!("       direct_sidecar signal --http A --tcp A [--udp A] [--stun URL]");
            eprintln!("       direct_sidecar rendezvous --udp A --tcp A [--host IP] [--ufrag U --pwd P]");
            std::process::exit(2);
        }
    }
}
