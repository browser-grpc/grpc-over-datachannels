//! Mux throughput/latency benchmark (baseline numbers, not a
//! correctness test): ordinary offerer peers cross-connected
//! to answerer peers hosted on ONE `PeerMux` socket.
//!
//!   cargo run --release --example mux_bench [pairs] [msgs] [size] [pingpongs]
//!
//! Phases:
//!   handshake  - establish `pairs` pairs, report pairs/s.
//!   blast      - pair 0 sends `msgs` messages of `size` bytes
//!                without waiting; the answerer counts them and
//!                replies once, report msgs/s and MiB/s.
//!   pingpong   - pair 0 echoes `pingpongs` round trips,
//!                report mean RTT.
//! Defaults: 8 pairs, 2000 messages, 1024 bytes, 200 ping-pongs.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::{DcEndpoint, EndpointEvent};
use dc_webrtc::mux::PeerMux;
use dc_webrtc::peer::{Peer, PeerConfig};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::{Duration, Instant};

fn loopback_config() -> PeerConfig {
    PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        ..Default::default()
    }
}

fn arg(n: usize, default: usize) -> usize {
    std::env::args()
        .nth(n)
        .and_then(|a| a.parse().ok())
        .unwrap_or(default)
}

/// Answerer loop: echo every message; stop after `expect`
/// messages (blast phase counts on the caller side via the
/// final echo of the last payload). Runs until shutdown.
fn answerer_loop(endpoint: DcEndpoint) {
    let mut channels = std::collections::HashMap::new();
    loop {
        match endpoint.recv_event_timeout(Duration::from_secs(60)) {
            Some(EndpointEvent::ChannelOpened { channel }) => {
                channels.insert(channel.stream, channel);
            }
            Some(EndpointEvent::Message { stream, data, .. }) => {
                if let Some(ch) = channels.get(&stream) {
                    let _ = ch.send_binary(&data);
                }
            }
            Some(EndpointEvent::ChannelClosed { stream }) => {
                channels.remove(&stream);
            }
            None => return,
            _ => {}
        }
    }
}

fn wait_message(endpoint: &DcEndpoint, deadline: Duration) -> Vec<u8> {
    let end = Instant::now() + deadline;
    while Instant::now() < end {
        if let Some(EndpointEvent::Message { data, .. }) =
            endpoint.recv_event_timeout(Duration::from_millis(250))
        {
            return data;
        }
    }
    panic!("timed out waiting for message");
}

fn main() {
    let pairs = arg(1, 8);
    let msgs = arg(2, 2000);
    let size = arg(3, 1024);
    let pingpongs = arg(4, 200);

    let mux = PeerMux::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0))
        .expect("bind mux");
    println!("mux socket: {}", mux.local_addr());

    // ---- handshake phase -------------------------------------
    let started = Instant::now();
    let mut offerers: Vec<DcEndpoint> = Vec::new();
    let mut joins = Vec::new();
    for _ in 0..pairs {
        let mut offerer = Peer::new(loopback_config()).expect("offerer");
        let mut answerer = mux.new_peer(loopback_config()).expect("mux peer");
        let offer = offerer.create_offer();
        let answer = answerer.handle_offer(&offer).expect("handle offer");
        offerer.handle_answer(&answer).expect("handle answer");
        joins.push(std::thread::spawn(move || {
            let endpoint = answerer.connect().expect("answerer connect");
            answerer_loop(endpoint);
        }));
        let endpoint = offerer.connect().expect("offerer connect");
        offerers.push(endpoint);
    }
    let handshake_s = started.elapsed().as_secs_f64();
    println!(
        "handshake: {pairs} pairs in {handshake_s:.2}s \
         ({:.1} pairs/s, {:.1} ms/pair)",
        pairs as f64 / handshake_s,
        handshake_s * 1000.0 / pairs as f64
    );

    let client = &offerers[0];
    let channel = client
        .open_channel(ChannelParams { label: "bench".into(), ..Default::default() })
        .expect("open channel");
    // Warm-up: first echo confirms the channel is live.
    channel.send_binary(b"warmup").expect("warmup send");
    let _ = wait_message(client, Duration::from_secs(30));

    // ---- blast phase -----------------------------------------
    let payload = vec![0xABu8; size];
    let started = Instant::now();
    for _ in 0..msgs {
        channel.send_binary(&payload).expect("blast send");
    }
    // The last echo to arrive corresponds to the last message.
    let mut echoes = 0usize;
    while echoes < msgs {
        let _ = wait_message(client, Duration::from_secs(120));
        echoes += 1;
    }
    let blast_s = started.elapsed().as_secs_f64();
    let mib = (msgs * size) as f64 / (1024.0 * 1024.0);
    println!(
        "blast: {msgs} x {size}B echoes in {blast_s:.2}s \
         ({:.0} msgs/s, {:.1} MiB/s echo path)",
        msgs as f64 / blast_s,
        mib / blast_s
    );

    // ---- ping-pong phase -------------------------------------
    let started = Instant::now();
    for _ in 0..pingpongs {
        channel.send_binary(&payload).expect("ping send");
        let _ = wait_message(client, Duration::from_secs(30));
    }
    let pp_s = started.elapsed().as_secs_f64();
    println!(
        "pingpong: {pingpongs} round trips in {pp_s:.2}s \
         ({:.2} ms mean RTT)",
        pp_s * 1000.0 / pingpongs as f64
    );

    for ep in &offerers {
        ep.shutdown();
    }
    for j in joins {
        let _ = j.join();
    }
}
