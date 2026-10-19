//! Bare-metal path proof: ICE nomination where every STUN packet
//! travels as a raw Ethernet II frame through ARP resolution,
//! IPv4, and UDP — no OS sockets anywhere. Two `IpStack`s on a
//! virtual cable, driven by ticks with manual clocks.

use dc_webrtc::ice::{Candidate, IceAgent};
use dc_webrtc::net::EthernetCable;
use dc_webrtc::platform::{Platform, UdpTransport};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

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
    while let Some((bytes, src)) = ta.recv_from(Duration::from_millis(1)).unwrap() {
        for (r, rdest) in a.handle_stun(&bytes, src).0 {
            ta.send_to(&r, rdest).unwrap();
        }
    }
    while let Some((bytes, src)) = tb.recv_from(Duration::from_millis(1)).unwrap() {
        for (r, rdest) in b.handle_stun(&bytes, src).0 {
            tb.send_to(&r, rdest).unwrap();
        }
    }
}

#[test]
fn ice_nomination_over_raw_ethernet() {
    let ip_a = Ipv4Addr::new(10, 0, 0, 1);
    let ip_b = Ipv4Addr::new(10, 0, 0, 2);
    let a_addr = SocketAddr::new(IpAddr::V4(ip_a), 5001);
    let b_addr = SocketAddr::new(IpAddr::V4(ip_b), 5002);

    let cable = Arc::new(EthernetCable::new());
    let ta: Arc<dyn UdpTransport> = cable.endpoint([0x02, 0, 0, 0, 0, 1], a_addr);
    let tb: Arc<dyn UdpTransport> = cable.endpoint([0x02, 0, 0, 0, 0, 2], b_addr);

    let (platform_a, clock_a) = Platform::manual(3);
    let (platform_b, clock_b) = Platform::manual(5);
    let mut a = IceAgent::new_with_clock(true, platform_a.clock.clone());
    let mut b = IceAgent::new_with_clock(false, platform_b.clock.clone());
    a.local_candidates = vec![Candidate::host(a_addr, "a")];
    b.local_candidates = vec![Candidate::host(b_addr, "b")];
    a.set_remote(&b.local_ufrag.clone(), &b.local_pwd.clone(), b.local_candidates.clone());
    b.set_remote(&a.local_ufrag.clone(), &a.local_pwd.clone(), a.local_candidates.clone());

    // No static ARP entries: the first ticks must ARP-resolve
    // before STUN checks can flow.
    let mut ticks = 0;
    while (a.nominated.is_none() || b.nominated.is_none()) && ticks < 400 {
        tick(&mut a, &mut b, &ta, &tb);
        clock_a.advance(10);
        clock_b.advance(10);
        ticks += 1;
    }
    assert_eq!(a.nominated, Some(b_addr));
    assert_eq!(b.nominated, Some(a_addr));
    assert!(ticks < 400, "nominated within the tick budget");
}
