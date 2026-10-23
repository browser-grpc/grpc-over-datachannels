//! RTOS-style harness: the ICE core runs with no OS sockets, no
//! threads, and no wall clock. A driver "tick" pumps datagrams
//! between two `MemoryNetwork` endpoints and advances a
//! `ManualClock`; nomination and consent expiry must follow the
//! injected time exactly.

use dc_webrtc::ice::{Candidate, IceAgent};
use dc_webrtc::platform::{
    Clock, ManualClock, MemoryNetwork, Platform, Rng, SeededRng, UdpTransport,
};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

fn addr(port: u16) -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port)
}

/// One tick: collect due checks from both agents, route them
/// through the memory transports, deliver inbound packets.
fn tick(
    a: &mut IceAgent,
    b: &mut IceAgent,
    ta: &Arc<dyn UdpTransport>,
    tb: &Arc<dyn UdpTransport>,
) {
    for (bytes, dest) in a.due_checks() {
        ta.send_to(&bytes, dest).unwrap();
    }
    for (bytes, dest) in b.due_checks() {
        tb.send_to(&bytes, dest).unwrap();
    }
    while let Some((bytes, src)) = ta.recv_from(Duration::ZERO).unwrap() {
        let (responses, _events) = a.handle_stun(&bytes, src);
        for (r, rdest) in responses {
            ta.send_to(&r, rdest).unwrap();
        }
    }
    while let Some((bytes, src)) = tb.recv_from(Duration::ZERO).unwrap() {
        let (responses, _events) = b.handle_stun(&bytes, src);
        for (r, rdest) in responses {
            tb.send_to(&r, rdest).unwrap();
        }
    }
}

#[test]
fn rtos_harness_nominates_on_memory_network() {
    let (platform_a, clock_a) = Platform::manual(7);
    let (_platform_b, clock_b) = Platform::manual(11);
    let net = Arc::new(MemoryNetwork::new());
    let ta: Arc<dyn UdpTransport> = net.endpoint(addr(4100));
    let tb: Arc<dyn UdpTransport> = net.endpoint(addr(4200));

    let mut a = IceAgent::new_with_clock(true, platform_a.clock.clone());
    let mut b = IceAgent::new_with_clock(false, _platform_b.clock.clone());
    a.local_candidates = vec![Candidate::host(addr(4100), "a")];
    b.local_candidates = vec![Candidate::host(addr(4200), "b")];
    a.set_remote(&b.local_ufrag.clone(), &b.local_pwd.clone(), b.local_candidates.clone());
    b.set_remote(&a.local_ufrag.clone(), &a.local_pwd.clone(), a.local_candidates.clone());

    // Tick until nomination, advancing injected time 10 ms/tick.
    let mut ticks = 0;
    while (a.nominated.is_none() || b.nominated.is_none()) && ticks < 200 {
        tick(&mut a, &mut b, &ta, &tb);
        clock_a.advance(10);
        clock_b.advance(10);
        ticks += 1;
    }
    assert_eq!(a.nominated, Some(addr(4200)), "controlling side nominated");
    assert_eq!(b.nominated, Some(addr(4100)), "controlled side nominated");
    assert!(ticks < 200, "nomination completed within the tick budget");

    // Consent stays fresh while traffic flows, then expires once
    // the injected clock runs past the expiry window.
    a.touch_consent();
    assert!(!a.consent_expired(Duration::from_secs(5)));
    clock_a.advance(4_999);
    assert!(!a.consent_expired(Duration::from_secs(5)));
    clock_a.advance(2);
    assert!(a.consent_expired(Duration::from_secs(5)));
}

#[test]
fn seeded_rng_is_deterministic() {
    let r1 = SeededRng::new(42);
    let r2 = SeededRng::new(42);
    let mut x = [0u8; 32];
    let mut y = [0u8; 32];
    r1.fill(&mut x);
    r2.fill(&mut y);
    assert_eq!(x, y, "same seed, same stream");
    let mut z = [0u8; 32];
    r1.fill(&mut z);
    assert_ne!(x, z, "stream advances");
}

#[test]
fn manual_clock_only_moves_when_driven() {
    let clock = ManualClock::new(100);
    assert_eq!(clock.now_ms(), 100);
    clock.advance(25);
    assert_eq!(clock.now_ms(), 125);
    clock.set(7);
    assert_eq!(clock.now_ms(), 7);
}
