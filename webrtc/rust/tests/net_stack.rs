//! Bare-metal path proof: ICE nomination where every STUN packet
//! travels as a raw Ethernet II frame through ARP resolution,
//! IPv4, and UDP — no OS sockets anywhere. Two `IpStack`s on a
//! virtual cable, driven by ticks with manual clocks.

use dc_webrtc::ice::{Candidate, IceAgent};
use dc_webrtc::net::EthernetCable;
use dc_webrtc::platform::{Platform, UdpTransport};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
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

#[test]
fn ice_nomination_over_ipv6_ethernet() {
    let ip_a = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);
    let ip_b = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2);
    let a_addr = SocketAddr::new(IpAddr::V6(ip_a), 5001);
    let b_addr = SocketAddr::new(IpAddr::V6(ip_b), 5002);

    let cable = Arc::new(EthernetCable::new());
    let ta: Arc<dyn UdpTransport> = cable.endpoint6([0x02, 0, 0, 0, 0, 1], a_addr);
    let tb: Arc<dyn UdpTransport> = cable.endpoint6([0x02, 0, 0, 0, 0, 2], b_addr);

    let (platform_a, clock_a) = Platform::manual(3);
    let (platform_b, clock_b) = Platform::manual(5);
    let mut a = IceAgent::new_with_clock(true, platform_a.clock.clone());
    let mut b = IceAgent::new_with_clock(false, platform_b.clock.clone());
    a.local_candidates = vec![Candidate::host(a_addr, "a")];
    b.local_candidates = vec![Candidate::host(b_addr, "b")];
    a.set_remote(&b.local_ufrag.clone(), &b.local_pwd.clone(), b.local_candidates.clone());
    b.set_remote(&a.local_ufrag.clone(), &a.local_pwd.clone(), a.local_candidates.clone());

    // No static NDP entries: STUN checks must wait for neighbour
    // solicitation over the solicited-node multicast.
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

// ---------------------------------------------------------------------------
// DHCP over the virtual cable, then UDP data on the leased address
// ---------------------------------------------------------------------------

use dc_webrtc::net::{ethernet_frame, internet_checksum, DhcpClient, ETHERTYPE_IPV4};

fn bootp_reply(
    server_mac: [u8; 6],
    server_ip: Ipv4Addr,
    xid: u32,
    client_mac: [u8; 6],
    msg_type: u8,
    yiaddr: Ipv4Addr,
) -> Vec<u8> {
    let mut pkt = vec![0u8; 240];
    pkt[0] = 2;
    pkt[1] = 1;
    pkt[2] = 6;
    pkt[4..8].copy_from_slice(&xid.to_be_bytes());
    pkt[16..20].copy_from_slice(&yiaddr.octets());
    pkt[28..34].copy_from_slice(&client_mac);
    pkt[236..240].copy_from_slice(&[0x63, 0x82, 0x53, 0x63]);
    let mut opts = vec![53, 1, msg_type, 54, 4];
    opts.extend_from_slice(&server_ip.octets());
    opts.extend_from_slice(&[51, 4, 0, 0, 0x1c, 0x20]);
    opts.extend_from_slice(&[1, 4, 255, 255, 255, 0]);
    opts.push(255);
    pkt.extend_from_slice(&opts);
    // UDP header (67 -> 68) with pseudo-header checksum.
    let udp_len = (8 + pkt.len()) as u16;
    let mut dgram = Vec::new();
    dgram.extend_from_slice(&67u16.to_be_bytes());
    dgram.extend_from_slice(&68u16.to_be_bytes());
    dgram.extend_from_slice(&udp_len.to_be_bytes());
    dgram.extend_from_slice(&[0, 0]);
    dgram.extend_from_slice(&pkt);
    let mut pseudo = Vec::new();
    pseudo.extend_from_slice(&server_ip.octets());
    pseudo.extend_from_slice(&Ipv4Addr::BROADCAST.octets());
    pseudo.extend_from_slice(&[0, 17]);
    pseudo.extend_from_slice(&udp_len.to_be_bytes());
    let mut joined = pseudo;
    joined.extend_from_slice(&dgram);
    let cksum = internet_checksum(&joined, 0);
    dgram[6..8].copy_from_slice(&cksum.to_be_bytes());
    // IPv4 header.
    let total = (20 + dgram.len()) as u16;
    let mut ip = Vec::new();
    ip.push(0x45);
    ip.push(0);
    ip.extend_from_slice(&total.to_be_bytes());
    ip.extend_from_slice(&[0x2a, 0x00, 0x40, 0x00, 64, 17, 0, 0]);
    ip.extend_from_slice(&server_ip.octets());
    ip.extend_from_slice(&Ipv4Addr::BROADCAST.octets());
    let ip_cksum = internet_checksum(&ip, 0);
    ip[10..12].copy_from_slice(&ip_cksum.to_be_bytes());
    ip.extend_from_slice(&dgram);
    ethernet_frame(client_mac, server_mac, ETHERTYPE_IPV4, &ip)
}

fn parse_bootp(frame: &[u8]) -> Option<(u32, u8, [u8; 6])> {
    // Ethernet(14) IPv4(20) UDP(8) BOOTP: op@0 xid@4 chaddr@28 opts@240
    let bootp = frame.get(14 + 20 + 8..)?;
    let xid = u32::from_be_bytes(bootp.get(4..8)?.try_into().unwrap());
    let mut chaddr = [0u8; 6];
    chaddr.copy_from_slice(bootp.get(28..34)?);
    let mut i = 240;
    while i + 1 < bootp.len() {
        let code = bootp[i];
        if code == 255 {
            break;
        }
        if code == 0 {
            i += 1;
            continue;
        }
        let len = bootp[i + 1] as usize;
        if code == 53 && len == 1 {
            return Some((xid, bootp[i + 2], chaddr));
        }
        i += 2 + len;
    }
    None
}

#[test]
fn dhcp_lease_then_udp_over_cable() {
    let client_mac = [0x02, 0, 0, 0, 0, 9];
    let server_mac = [0x02, 0, 0, 0, 0, 254];
    let server_ip = Ipv4Addr::new(10, 0, 0, 254);
    let offered = Ipv4Addr::new(10, 0, 0, 50);

    let cable = Arc::new(EthernetCable::new());
    let server_port = cable.raw_endpoint(server_mac);
    let client_port = cable.raw_endpoint(client_mac);

    let server = std::thread::spawn(move || {
        for _ in 0..2 {
            let frame = server_port
                .recv_frame(Duration::from_secs(5))
                .expect("server sees DHCP request");
            let (xid, msg_type, chaddr) = parse_bootp(&frame).expect("bootp parse");
            let reply_type = if msg_type == 1 { 2 } else { 5 }; // DISCOVER->OFFER, REQUEST->ACK
            server_port.send_frame(bootp_reply(
                server_mac, server_ip, xid, chaddr, reply_type, offered,
            ));
        }
    });

    let mut dhcp = DhcpClient::new(client_mac, 0xcafe);
    client_port.send_frame(dhcp.discover_frame());
    let mut guard = 0;
    while dhcp.lease().is_none() && guard < 10 {
        guard += 1;
        let frame = client_port
            .recv_frame(Duration::from_secs(5))
            .expect("client sees DHCP reply");
        if let Some(next) = dhcp.handle_frame(&frame) {
            client_port.send_frame(next);
        }
    }
    server.join().unwrap();
    let lease = dhcp.lease().expect("lease granted over the cable");
    assert_eq!(lease.address, offered);
    assert_eq!(lease.router, None); // server offered no router option here
    assert_eq!(lease.subnet_mask, Some(Ipv4Addr::new(255, 255, 255, 0)));

    // Data plane on the leased address.
    let client_addr = SocketAddr::new(IpAddr::V4(lease.address), 7777);
    let server_addr = SocketAddr::new(IpAddr::V4(server_ip), 8888);
    let ta: Arc<dyn UdpTransport> = cable.endpoint(client_mac, client_addr);
    let tb: Arc<dyn UdpTransport> = cable.endpoint(server_mac, server_addr);
    ta.send_to(b"on-lease", server_addr).unwrap();
    // Pump both ends (tick): ARP resolution flushes the queued
    // datagram only when the client stack processes the reply.
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let mut got = None;
    while got.is_none() && std::time::Instant::now() < deadline {
        let _ = ta.recv_from(Duration::from_millis(50)).unwrap();
        got = tb.recv_from(Duration::from_millis(50)).unwrap();
    }
    let (payload, src) = got.expect("UDP delivered on the leased address");
    assert_eq!(payload, b"on-lease");
    assert_eq!(src, client_addr);
}

fn bootp_has_option(frame: &[u8], want: u8) -> bool {
    let bootp = &frame[14 + 20 + 8..];
    let mut i = 240;
    while i + 1 < bootp.len() {
        let code = bootp[i];
        if code == 255 {
            break;
        }
        if code == 0 {
            i += 1;
            continue;
        }
        if code == want {
            return true;
        }
        i += 2 + bootp[i + 1] as usize;
    }
    false
}

/// Grant a 7200s lease directly (no cable) at the client's
/// current tick time.
fn grant_lease(dhcp: &mut DhcpClient, client_mac: [u8; 6]) {
    let server_mac = [0x02, 0, 0, 0, 0, 254];
    let server_ip = Ipv4Addr::new(10, 0, 0, 254);
    let offered = Ipv4Addr::new(10, 0, 0, 50);
    let offer = bootp_reply(server_mac, server_ip, 0xcafe, client_mac, 2, offered);
    assert!(dhcp.handle_frame(&offer).is_some(), "OFFER yields REQUEST");
    let ack = bootp_reply(server_mac, server_ip, 0xcafe, client_mac, 5, offered);
    assert!(dhcp.handle_frame(&ack).is_none());
    assert!(dhcp.lease().is_some());
}

#[test]
fn dhcp_t1_renews_t2_rebinds_and_expiry_drops_lease() {
    let client_mac = [0x02, 0, 0, 0, 0, 9];
    // Lease is 7200s: T1 at 3_600_000 ms, T2 at 6_300_000 ms.
    let mut dhcp = DhcpClient::new(client_mac, 0xcafe);
    assert!(dhcp.tick(0).is_none());
    grant_lease(&mut dhcp, client_mac);
    assert!(dhcp.tick(3_599_999).is_none());
    let renew = dhcp.tick(3_600_000).expect("T1 fires a renew");
    let (_, msg_type, _) = parse_bootp(&renew).expect("renew parses");
    assert_eq!(msg_type, 3);
    assert!(bootp_has_option(&renew, 54), "renew carries server id");
    assert!(dhcp.tick(3_600_001).is_none(), "T1 fires once");
    // ACK at T1 re-arms the clock from 3_600_000.
    grant_lease(&mut dhcp, client_mac);
    assert!(dhcp.tick(7_200_000).is_none());
    assert!(dhcp.tick(7_200_001).is_some(), "T1 re-armed after ACK");

    // No ACKs at all: T1, then T2 rebind (no server id), then drop.
    let mut dhcp = DhcpClient::new(client_mac, 0xcafe);
    assert!(dhcp.tick(0).is_none());
    grant_lease(&mut dhcp, client_mac);
    assert!(dhcp.tick(3_600_000).is_some());
    let rebind = dhcp.tick(6_300_000).expect("T2 fires a rebind");
    assert!(!bootp_has_option(&rebind, 54), "rebind omits server id");
    assert!(dhcp.tick(7_200_000).is_none(), "expiry sends nothing");
    assert!(dhcp.lease().is_none(), "expired lease dropped");
}
