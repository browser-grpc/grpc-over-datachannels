//! IoT bring-up: two bare-metal-style devices on one virtual
//! Ethernet cable, from power-on to a DataChannel echo — with no
//! OS sockets, no wall clock, and no system entropy anywhere.
//!
//! Each "device" is assembled exactly the way a board port would
//! assemble it, substituting stub-HAL pieces for hardware:
//!
//! | device piece        | on a board            | here (stub HAL)      |
//! |---------------------|-----------------------|----------------------|
//! | clock + entropy     | RTC / hardware TRNG   | `Platform::manual`   |
//! | NIC                 | Ethernet MAC/PHY      | `EthernetCable` port |
//! | IP stack            | (in crate)            | Ethernet/ARP/IPv4/UDP|
//! | signaling           | out-of-band           | exchanged in-process |
//!
//! The tick loop is the device's main loop: pump ICE checks
//! through the cable until nomination, then hand the nominated
//! pair to DTLS and open a channel. Run:
//!   cargo run --example iot_cable

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::dtls::{Dtls, DtlsConfig, DtlsIo, Role};
use dc_webrtc::endpoint::{DcEndpoint, EndpointEvent};
use dc_webrtc::ice::{Candidate, IceAgent};
use dc_webrtc::net::EthernetCable;
use dc_webrtc::platform::{Platform, UdpTransport};
use dc_webrtc::x509::Certificate;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

/// DTLS record transport over the nominated cable pair — the
/// embedded analogue of a UDP socket.
struct CableDtlsIo {
    transport: Arc<dyn UdpTransport>,
    peer: SocketAddr,
}

impl DtlsIo for CableDtlsIo {
    fn send_packet(&mut self, packet: &[u8]) -> io::Result<()> {
        self.transport.send_to(packet, self.peer)
    }

    fn recv_packet(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        Ok(self.transport.recv_from(timeout)?.map(|(bytes, _src)| bytes))
    }
}

fn config() -> DtlsConfig {
    DtlsConfig {
        certificate: Certificate::generate_self_signed("dc-webrtc-iot"),
        expected_peer_fingerprint: None,
        require_peer_certificate: false,
        session_resumption: false,
        session_ticket_key: None,
        connection_id: None,
        pair_hint: None,
    }
}

/// One device main-loop tick: emit due ICE checks, deliver
/// inbound STUN, advance the stub clock.
#[allow(clippy::too_many_arguments)]
fn tick(
    a: &mut IceAgent,
    b: &mut IceAgent,
    ta: &Arc<dyn UdpTransport>,
    tb: &Arc<dyn UdpTransport>,
    clock_a: &dc_webrtc::platform::ManualClock,
    clock_b: &dc_webrtc::platform::ManualClock,
) {
    for (bytes, dest) in a.due_checks() {
        ta.send_to(&bytes, dest).unwrap();
    }
    for (bytes, dest) in b.due_checks() {
        tb.send_to(&bytes, dest).unwrap();
    }
    while let Ok(Some((bytes, src))) = ta.recv_from(Duration::from_millis(1)) {
        for (r, rdest) in a.handle_stun(&bytes, src).0 {
            ta.send_to(&r, rdest).unwrap();
        }
    }
    while let Ok(Some((bytes, src))) = tb.recv_from(Duration::from_millis(1)) {
        for (r, rdest) in b.handle_stun(&bytes, src).0 {
            tb.send_to(&r, rdest).unwrap();
        }
    }
    clock_a.advance(10);
    clock_b.advance(10);
}

fn main() -> io::Result<()> {
    // -- Device bring-up (the stub HAL) -------------------------
    let ip_a = Ipv4Addr::new(10, 0, 0, 1);
    let ip_b = Ipv4Addr::new(10, 0, 0, 2);
    let a_addr = SocketAddr::new(IpAddr::V4(ip_a), 5001);
    let b_addr = SocketAddr::new(IpAddr::V4(ip_b), 5002);

    let (platform_a, clock_a) = Platform::manual(3);
    let (platform_b, clock_b) = Platform::manual(5);
    // Entropy for both devices (one process, one installed RNG —
    // on hardware each device installs its own TRNG at boot).
    dc_webrtc::platform::install_rng(platform_a.rng.clone());

    // One cable, two NICs.
    let cable = Arc::new(EthernetCable::new());
    let ta: Arc<dyn UdpTransport> = cable.endpoint([0x02, 0, 0, 0, 0, 1], a_addr);
    let tb: Arc<dyn UdpTransport> = cable.endpoint([0x02, 0, 0, 0, 0, 2], b_addr);

    // -- ICE over raw Ethernet (ARP resolves on first ticks) ----
    let mut a = IceAgent::new_with_clock(true, platform_a.clock.clone());
    let mut b = IceAgent::new_with_clock(false, platform_b.clock.clone());
    a.local_candidates = vec![Candidate::host(a_addr, "a")];
    b.local_candidates = vec![Candidate::host(b_addr, "b")];
    a.set_remote(&b.local_ufrag.clone(), &b.local_pwd.clone(), b.local_candidates.clone());
    b.set_remote(&a.local_ufrag.clone(), &a.local_pwd.clone(), a.local_candidates.clone());

    let mut ticks = 0;
    while (a.nominated.is_none() || b.nominated.is_none()) && ticks < 400 {
        tick(&mut a, &mut b, &ta, &tb, &clock_a, &clock_b);
        ticks += 1;
    }
    assert_eq!(a.nominated, Some(b_addr), "device A nominates B");
    assert_eq!(b.nominated, Some(a_addr), "device B nominates A");
    println!("iot: nominated {a_addr} <-> {b_addr} over raw ethernet ({ticks} ticks)");

    // -- DTLS over the nominated pair ---------------------------
    let server_io = CableDtlsIo { transport: tb.clone(), peer: a_addr };
    let server_thread = std::thread::spawn(move || {
        let dtls = Dtls::accept(server_io, &config()).expect("device B handshake");
        DcEndpoint::spawn(dtls, Role::Server, 5000)
    });
    let client_io = CableDtlsIo { transport: ta.clone(), peer: b_addr };
    let client_dtls = Dtls::connect(client_io, &config()).expect("device A handshake");
    let client_ep = DcEndpoint::spawn(client_dtls, Role::Client, 5000);
    let server_ep = server_thread.join().unwrap();
    println!("iot: dtls established, sctp associated");

    // -- DataChannel echo ---------------------------------------
    let channel = client_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    let server_channel = match server_ep.recv_event_timeout(Duration::from_secs(5)) {
        Some(EndpointEvent::ChannelOpened { channel }) => channel,
        other => panic!("expected ChannelOpened, got {}", other.map(|_| "other").unwrap_or("timeout")),
    };

    channel.send_text("ping from device A").unwrap();
    let reply = loop {
        match server_ep.recv_event_timeout(Duration::from_secs(5)) {
            Some(EndpointEvent::Message { data, .. }) => {
                server_channel.send_binary(&data).unwrap();
                break match client_ep.recv_event_timeout(Duration::from_secs(5)) {
                    Some(EndpointEvent::Message { data, .. }) => {
                        String::from_utf8_lossy(&data).into_owned()
                    }
                    other => panic!("expected echo reply, got {}", other.map(|_| "other").unwrap_or("timeout")),
                };
            }
            Some(_) => continue,
            None => panic!("device B never received the message"),
        }
    };
    assert_eq!(reply, "ping from device A");
    println!("iot: echo reply: {reply}");

    client_ep.shutdown();
    server_ep.shutdown();
    println!("iot: OK (no sockets, no wall clock, no OS entropy)");
    Ok(())
}
