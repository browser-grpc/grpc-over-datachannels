//! Full-peer echo harness with SDP exchanged through files:
//!   peer_echo offerer  <offer-file> <answer-file> [all-ips]
//!   peer_echo answerer <offer-file> <answer-file> [all-ips]
//!   peer_echo mux-offerer  <dir>   (two pairs over one PeerMux)
//!   peer_echo mux-answerer <dir>
//! The offerer writes its offer, waits for the answer file, connects,
//! opens the "echo" channel, sends stdin lines and prints replies.
//! The answerer echoes. Used by JS tests for native cross-language
//! full-stack checks.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::{DcEndpoint, EndpointEvent};
use dc_webrtc::mux::PeerMux;
use dc_webrtc::peer::{Peer, PeerConfig};
use std::io::{self, BufRead, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

fn wait_for_file(path: &str) -> String {
    loop {
        if let Ok(content) = std::fs::read_to_string(path) {
            if !content.trim().is_empty() {
                return content;
            }
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn loopback_config() -> PeerConfig {
    // Optional 4th CLI arg "all-ips": advertise the default-route
    // interface too (browser tests: Firefox does not pair with
    // loopback-only remote candidates).
    let all_ips = std::env::args().nth(4).map(|a| a == "all-ips").unwrap_or(false);
    PeerConfig {
        local_ips: if all_ips { Vec::new() } else { vec![IpAddr::V4(Ipv4Addr::LOCALHOST)] },
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: Vec::new(),
    }
}

fn loopback_peer() -> Peer {
    Peer::new(loopback_config()).unwrap()
}

/// Config for mux-mode peers. With a TURN server address as
/// the 3rd CLI arg, the advertised host address is deliberately
/// unreachable, so a successful pair proves the relay carried
/// it (relay-only, like the in-stack TURN tests).
fn mux_config() -> PeerConfig {
    let mut config = loopback_config();
    if let Some(turn) = std::env::args().nth(3).filter(|a| !a.is_empty()) {
        config.local_ips = vec![IpAddr::V4(Ipv4Addr::new(10, 11, 12, 13))];
        config.turn_servers =
            vec![dc_webrtc::turn::TurnServerConfig::new(&turn, "dcuser", "dcpass")];
    }
    config
}

/// Echo loop for one connected answerer endpoint ("re:" prefix).
fn echo_loop(endpoint: DcEndpoint) -> io::Result<()> {
    let mut channels = std::collections::HashMap::new();
    loop {
        match endpoint.recv_event_timeout(Duration::from_secs(120)) {
            Some(EndpointEvent::ChannelOpened { channel }) => {
                eprintln!("CHANNEL_OPEN stream={}", channel.stream);
                channels.insert(channel.stream, channel);
            }
            Some(EndpointEvent::Message { stream, data, .. }) => {
                if let Some(channel) = channels.get(&stream) {
                    let mut reply = b"re:".to_vec();
                    reply.extend_from_slice(&data);
                    channel.send_binary(&reply)?;
                }
            }
            Some(EndpointEvent::ChannelClosed { stream }) => {
                eprintln!("CHANNEL_CLOSED stream={stream}");
                channels.remove(&stream);
            }
            None => return Ok(()),
            _ => {}
        }
    }
}

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(|s| s.as_str()).unwrap_or("");
    let offer_path = args.get(2).cloned().unwrap_or_default();
    let answer_path = args.get(3).cloned().unwrap_or_default();
    match mode {
        "answerer" => {
            let offer = wait_for_file(&offer_path);
            let mut peer = loopback_peer();
            let answer = peer.handle_offer(&offer)?;
            std::fs::write(&answer_path, answer)?;
            eprintln!("ANSWER_WRITTEN");
            let endpoint = peer.connect()?;
            eprintln!("CONNECTED");
            echo_loop(endpoint)
        }
        "mux-answerer" => {
            // Two pairs over one PeerMux socket; SDP via
            // <dir>/offer<i> and <dir>/answer<i>.
            let dir = offer_path.clone();
            let mux = PeerMux::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))?;
            let mut peers = Vec::new();
            for pair in 0..2 {
                let offer = wait_for_file(&format!("{dir}/offer{pair}"));
                let mut peer = mux.new_peer(mux_config())?;
                let answer = peer.handle_offer(&offer)?;
                std::fs::write(format!("{dir}/answer{pair}"), answer)?;
                peers.push(peer);
            }
            let mut handles = Vec::new();
            for mut peer in peers {
                handles.push(std::thread::spawn(move || {
                    let endpoint = peer.connect()?;
                    echo_loop(endpoint)
                }));
            }
            eprintln!("MUX_ANSWERER_READY");
            for h in handles {
                let _ = h.join();
            }
            Ok(())
        }
        "mux-offerer" => {
            let dir = offer_path.clone();
            let mux = PeerMux::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))?;
            let mut peers = Vec::new();
            for pair in 0..2 {
                let mut peer = mux.new_peer(mux_config())?;
                let offer = peer.create_offer();
                std::fs::write(format!("{dir}/offer{pair}"), offer)?;
                peers.push(peer);
            }
            let (tx, rx) = std::sync::mpsc::channel::<(usize, String)>();
            let mut handles = Vec::new();
            for (pair, mut peer) in peers.into_iter().enumerate() {
                let answer = wait_for_file(&format!("{dir}/answer{pair}"));
                peer.handle_answer(&answer)?;
                let tx = tx.clone();
                handles.push(std::thread::spawn(move || -> io::Result<()> {
                    let endpoint = peer.connect()?;
                    let channel = endpoint.open_channel(ChannelParams {
                        label: "echo".into(),
                        ..Default::default()
                    })?;
                    channel.send_binary(format!("hello-from-pair-{pair}").as_bytes())?;
                    let deadline = std::time::Instant::now() + Duration::from_secs(30);
                    loop {
                        match endpoint.recv_event_timeout(Duration::from_secs(5)) {
                            Some(EndpointEvent::Message { data, .. }) => {
                                let _ = tx.send((pair, String::from_utf8_lossy(&data).into_owned()));
                                break;
                            }
                            _ => {
                                if std::time::Instant::now() > deadline {
                                    eprintln!("mux offerer: no reply for pair {pair}");
                                    std::process::exit(1);
                                }
                            }
                        }
                    }
                    // Stay alive (mux socket + consent) until killed.
                    loop {
                        std::thread::sleep(Duration::from_secs(60));
                    }
                }));
            }
            drop(tx);
            let mut got: Vec<(usize, String)> = Vec::new();
            for _ in 0..2 {
                got.push(rx.recv().expect("pair result"));
            }
            got.sort();
            for (pair, text) in got {
                println!("pair{pair}: {text}");
            }
            println!("MUX_OK");
            io::stdout().flush()?;
            Ok(())
        }
        "offerer" => {
            let mut peer = loopback_peer();
            let offer = peer.create_offer();
            std::fs::write(&offer_path, offer)?;
            eprintln!("OFFER_WRITTEN");
            let answer = wait_for_file(&answer_path);
            peer.handle_answer(&answer)?;
            let endpoint = peer.connect()?;
            eprintln!("CONNECTED");
            let channel = endpoint.open_channel(ChannelParams {
                label: "echo".into(),
                ..Default::default()
            })?;
            let stdin = io::stdin();
            for line in stdin.lock().lines() {
                let line = line?;
                if line.is_empty() {
                    continue;
                }
                if line == "__close__" {
                    // Cross-stack close check: reset the stream
                    // and report once both directions complete.
                    channel.close();
                    let deadline = std::time::Instant::now() + Duration::from_secs(15);
                    let mut closed = false;
                    while std::time::Instant::now() < deadline && !closed {
                        match endpoint.recv_event_timeout(Duration::from_millis(200)) {
                            Some(EndpointEvent::ChannelClosed { .. }) => closed = true,
                            _ => {}
                        }
                    }
                    if !closed {
                        eprintln!("close timed out");
                        std::process::exit(1);
                    }
                    eprintln!("CHANNEL_CLOSED_LOCAL");
                    println!("closed");
                    io::stdout().flush()?;
                    continue;
                }
                channel.send_binary(line.as_bytes())?;
                match endpoint.recv_event_timeout(Duration::from_secs(15)) {
                    Some(EndpointEvent::Message { data, .. }) => {
                        println!("{}", String::from_utf8_lossy(&data));
                        io::stdout().flush()?;
                    }
                    _ => {
                        eprintln!("no reply");
                        std::process::exit(1);
                    }
                }
            }
            Ok(())
        }
        _ => {
            eprintln!("usage: peer_echo <offerer|answerer|mux-offerer|mux-answerer> <offer-file|dir> <answer-file>");
            std::process::exit(2);
        }
    }
}
