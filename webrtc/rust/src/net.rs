//! Minimal hand-rolled L2–L4 stack for bare-metal targets:
//! Ethernet II framing, ARP (RFC 826), IPv4 (RFC 791), UDP
//! (RFC 768), and ICMP echo replies. Zero dependencies, like the
//! rest of the crate — this replaces the lwIP/smoltcp assumption
//! below the platform `UdpTransport` seam.
//!
//! Deliberate limits (documented, not silent): no IP header
//! options, no fragmentation (fragments are dropped), ARP/NDP
//! caches expire on `tick`. IPv4 (`IpStack`) has a routing
//! table with longest-prefix lookup, gateway next hops, and
//! opt-in forwarding; IPv6 (`IpStack6`) sits beside it with NDP
//! neighbour discovery, SLAAC-style EUI-64 addresses, and a
//! default-router next hop (no v6 forwarding). `IpStack` is a pure state machine — frames
//! in, frames out — driven by the caller's tick, and
//! `EthernetUdpTransport` bridges it to `platform::UdpTransport`
//! so the ICE core runs over raw Ethernet frames.

use alloc::vec::Vec;
#[cfg(feature = "std")]
use crate::platform::UdpTransport;
#[cfg(feature = "std")]
use std::collections::HashMap;
#[cfg(not(feature = "std"))]
use alloc::collections::BTreeMap as HashMap;
use alloc::collections::VecDeque;
use core::net::{IpAddr, Ipv4Addr, SocketAddr};
#[cfg(feature = "std")]
use alloc::sync::Arc;
#[cfg(feature = "std")]
use core::time::Duration;
#[cfg(feature = "std")]
use crate::io;
#[cfg(feature = "std")]
use std::sync::{mpsc, Mutex};
#[cfg(feature = "std")]
use std::time::Instant;

// ---------------------------------------------------------------------------
// Ethernet II + ARP
// ---------------------------------------------------------------------------

pub const ETHERTYPE_IPV4: u16 = 0x0800;
pub const ETHERTYPE_ARP: u16 = 0x0806;
pub const BROADCAST_MAC: [u8; 6] = [0xff; 6];

pub type MacAddr = [u8; 6];

/// Serialize one Ethernet II frame.
pub fn ethernet_frame(dst: MacAddr, src: MacAddr, ethertype: u16, payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(14 + payload.len());
    frame.extend_from_slice(&dst);
    frame.extend_from_slice(&src);
    frame.extend_from_slice(&ethertype.to_be_bytes());
    frame.extend_from_slice(payload);
    frame
}

/// Parse an Ethernet II header: (dst, src, ethertype, payload).
pub fn ethernet_parse(frame: &[u8]) -> Option<(MacAddr, MacAddr, u16, &[u8])> {
    if frame.len() < 14 {
        return None;
    }
    let mut dst = [0u8; 6];
    let mut src = [0u8; 6];
    dst.copy_from_slice(&frame[0..6]);
    src.copy_from_slice(&frame[6..12]);
    let ethertype = u16::from_be_bytes([frame[12], frame[13]]);
    Some((dst, src, ethertype, &frame[14..]))
}

/// Build an ARP packet body (Ethernet/IPv4 form, 28 bytes).
fn arp_body(oper: u16, sha: MacAddr, spa: Ipv4Addr, tha: MacAddr, tpa: Ipv4Addr) -> Vec<u8> {
    let mut body = Vec::with_capacity(28);
    body.extend_from_slice(&1u16.to_be_bytes()); // htype: Ethernet
    body.extend_from_slice(&ETHERTYPE_IPV4.to_be_bytes()); // ptype
    body.push(6); // hlen
    body.push(4); // plen
    body.extend_from_slice(&oper.to_be_bytes());
    body.extend_from_slice(&sha);
    body.extend_from_slice(&spa.octets());
    body.extend_from_slice(&tha);
    body.extend_from_slice(&tpa.octets());
    body
}

struct ArpPacket {
    oper: u16,
    sha: MacAddr,
    spa: Ipv4Addr,
    tpa: Ipv4Addr,
}

fn arp_parse(body: &[u8]) -> Option<ArpPacket> {
    if body.len() < 28 || body[0..2] != [0, 1] || body[2..4] != [0x08, 0x00] {
        return None;
    }
    if body[4] != 6 || body[5] != 4 {
        return None;
    }
    let mut sha = [0u8; 6];
    sha.copy_from_slice(&body[8..14]);
    Some(ArpPacket {
        oper: u16::from_be_bytes([body[6], body[7]]),
        sha,
        spa: Ipv4Addr::new(body[14], body[15], body[16], body[17]),
        tpa: Ipv4Addr::new(body[24], body[25], body[26], body[27]),
    })
}

// ---------------------------------------------------------------------------
// IPv4 + UDP
// ---------------------------------------------------------------------------

/// Internet checksum (RFC 1071) over `data` (with `initial` sum
/// for pseudo-header chaining).
pub fn internet_checksum(data: &[u8], initial: u32) -> u16 {
    let mut sum: u32 = initial;
    let mut chunks = data.chunks_exact(2);
    for c in &mut chunks {
        sum += u32::from(u16::from_be_bytes([c[0], c[1]]));
    }
    if let Some(&last) = chunks.remainder().first() {
        sum += u32::from(last) << 8;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

fn ipv4_build(src: Ipv4Addr, dst: Ipv4Addr, protocol: u8, payload: &[u8]) -> Vec<u8> {
    ipv4_build_ttl(src, dst, protocol, payload, 64)
}

fn ipv4_build_ttl(
    src: Ipv4Addr,
    dst: Ipv4Addr,
    protocol: u8,
    payload: &[u8],
    ttl: u8,
) -> Vec<u8> {
    let total = (20 + payload.len()) as u16;
    let mut pkt = Vec::with_capacity(total as usize);
    pkt.push(0x45); // version 4, IHL 5 (no options)
    pkt.push(0); // DSCP/ECN
    pkt.extend_from_slice(&total.to_be_bytes());
    pkt.extend_from_slice(&0x2au16.to_be_bytes()); // identification
    pkt.extend_from_slice(&0x4000u16.to_be_bytes()); // DF, no fragment offset
    pkt.push(ttl); // TTL
    pkt.push(protocol);
    pkt.extend_from_slice(&[0, 0]); // checksum placeholder
    pkt.extend_from_slice(&src.octets());
    pkt.extend_from_slice(&dst.octets());
    let cksum = internet_checksum(&pkt, 0);
    pkt[10..12].copy_from_slice(&cksum.to_be_bytes());
    pkt.extend_from_slice(payload);
    pkt
}

struct Ipv4Packet<'a> {
    src: Ipv4Addr,
    dst: Ipv4Addr,
    protocol: u8,
    payload: &'a [u8],
}

fn ipv4_parse(pkt: &[u8]) -> Option<Ipv4Packet<'_>> {
    if pkt.len() < 20 || pkt[0] != 0x45 {
        return None; // v4, no options only
    }
    let total = u16::from_be_bytes([pkt[2], pkt[3]]) as usize;
    if total < 20 || total > pkt.len() {
        return None;
    }
    let flags_frag = u16::from_be_bytes([pkt[6], pkt[7]]);
    if flags_frag & 0x3fff != 0 {
        return None; // MF set or fragment offset: unsupported, drop
    }
    if internet_checksum(&pkt[..20], 0) != 0 {
        return None;
    }
    Some(Ipv4Packet {
        src: Ipv4Addr::new(pkt[12], pkt[13], pkt[14], pkt[15]),
        dst: Ipv4Addr::new(pkt[16], pkt[17], pkt[18], pkt[19]),
        protocol: pkt[9],
        payload: &pkt[20..total],
    })
}

fn udp_build(src: Ipv4Addr, dst: Ipv4Addr, src_port: u16, dst_port: u16, payload: &[u8]) -> Vec<u8> {
    let len = (8 + payload.len()) as u16;
    let mut dgram = Vec::with_capacity(len as usize);
    dgram.extend_from_slice(&src_port.to_be_bytes());
    dgram.extend_from_slice(&dst_port.to_be_bytes());
    dgram.extend_from_slice(&len.to_be_bytes());
    dgram.extend_from_slice(&[0, 0]); // checksum placeholder
    dgram.extend_from_slice(payload);
    // Pseudo-header: src, dst, zero, protocol=17, UDP length.
    let mut pseudo = Vec::with_capacity(12);
    pseudo.extend_from_slice(&src.octets());
    pseudo.extend_from_slice(&dst.octets());
    pseudo.push(0);
    pseudo.push(17);
    pseudo.extend_from_slice(&len.to_be_bytes());
    let mut joined = pseudo;
    joined.extend_from_slice(&dgram);
    let cksum = internet_checksum(&joined, 0);
    let cksum = if cksum == 0 { 0xffff } else { cksum };
    dgram[6..8].copy_from_slice(&cksum.to_be_bytes());
    dgram
}

fn udp_parse<'a>(src: Ipv4Addr, dst: Ipv4Addr, dgram: &'a [u8]) -> Option<(u16, u16, &'a [u8])> {
    if dgram.len() < 8 {
        return None;
    }
    let len = u16::from_be_bytes([dgram[4], dgram[5]]) as usize;
    if len < 8 || len > dgram.len() {
        return None;
    }
    let body = &dgram[..len];
    let wire_cksum = u16::from_be_bytes([body[6], body[7]]);
    if wire_cksum != 0 {
        let mut pseudo = Vec::with_capacity(12);
        pseudo.extend_from_slice(&src.octets());
        pseudo.extend_from_slice(&dst.octets());
        pseudo.push(0);
        pseudo.push(17);
        pseudo.extend_from_slice(&(len as u16).to_be_bytes());
        let mut joined = pseudo;
        joined.extend_from_slice(body);
        if internet_checksum(&joined, 0) != 0 {
            return None;
        }
    }
    Some((
        u16::from_be_bytes([body[0], body[1]]),
        u16::from_be_bytes([body[2], body[3]]),
        &body[8..],
    ))
}

// ---------------------------------------------------------------------------
// IP stack state machine
// ---------------------------------------------------------------------------

/// How long a learned ARP entry stays fresh (static entries
/// never expire). Drive time via `IpStack::tick`.
pub const ARP_ENTRY_TTL_MS: u64 = 60_000;

#[derive(Clone, Copy)]
struct ArpEntry {
    mac: MacAddr,
    inserted_ms: u64,
    permanent: bool,
}

/// One-interface IPv4 stack with a small routing table. Frames in
/// via `input`, frames out via `take_output`; UDP payloads queue
/// per local port. Without routes, everything is on-link (the
/// original behavior); `set_network` installs the usual
/// subnet + default-via-gateway pair.
pub struct IpStack {
    mac: MacAddr,
    ip: Ipv4Addr,
    extra_addrs: Vec<Ipv4Addr>,
    arp: HashMap<Ipv4Addr, ArpEntry>,
    routes: Vec<(u32, u32, Option<Ipv4Addr>)>, // (network, mask, via)
    forwarding: bool,
    now_ms: u64,
    pending: Vec<(u16, SocketAddr, Vec<u8>)>,
    fwd_pending: Vec<(Ipv4Addr, Vec<u8>)>,
    outbox: Vec<Vec<u8>>,
    inbox: HashMap<u16, VecDeque<(Vec<u8>, SocketAddr)>>,
}

fn prefix_mask(prefix_len: u8) -> u32 {
    if prefix_len == 0 {
        0
    } else {
        u32::MAX << (32 - prefix_len.min(32))
    }
}

impl IpStack {
    pub fn new(mac: MacAddr, ip: Ipv4Addr) -> Self {
        Self {
            mac,
            ip,
            extra_addrs: Vec::new(),
            arp: HashMap::new(),
            routes: Vec::new(),
            forwarding: false,
            now_ms: 0,
            pending: Vec::new(),
            fwd_pending: Vec::new(),
            outbox: Vec::new(),
            inbox: HashMap::new(),
        }
    }

    /// Add a secondary local address (gateways serving two
    /// subnets on one interface).
    pub fn add_address(&mut self, ip: Ipv4Addr) {
        if ip != self.ip && !self.extra_addrs.contains(&ip) {
            self.extra_addrs.push(ip);
        }
    }

    fn is_local(&self, ip: Ipv4Addr) -> bool {
        ip == self.ip || self.extra_addrs.contains(&ip)
    }

    /// Add a route: `network/prefix_len`, on-link when `via` is
    /// None, else via that next hop. Longest prefix wins.
    pub fn add_route(&mut self, network: Ipv4Addr, prefix_len: u8, via: Option<Ipv4Addr>) {
        let mask = prefix_mask(prefix_len);
        self.routes
            .push((u32::from(network) & mask, mask, via));
    }

    /// The standard pair: our subnet on-link, everything else
    /// via `gateway` (when given).
    pub fn set_network(&mut self, subnet_mask: Ipv4Addr, gateway: Option<Ipv4Addr>) {
        let mask = u32::from(subnet_mask);
        let prefix = mask.count_ones() as u8;
        self.routes.clear();
        self.add_route(Ipv4Addr::from(u32::from(self.ip) & mask), prefix, None);
        for extra in &self.extra_addrs.clone() {
            self.add_route(Ipv4Addr::from(u32::from(*extra) & mask), prefix, None);
        }
        if let Some(gw) = gateway {
            self.add_route(Ipv4Addr::UNSPECIFIED, 0, Some(gw));
        }
    }

    /// Configure networking from a DHCP lease (subnet + router).
    pub fn apply_lease(&mut self, lease: &DhcpLease) {
        if let Some(mask) = lease.subnet_mask {
            self.set_network(mask, lease.router);
        }
    }

    /// Forward packets addressed to other hosts (gateway mode).
    pub fn set_forwarding(&mut self, on: bool) {
        self.forwarding = on;
    }

    /// Advance the stack's sense of time; expires learned ARP
    /// entries older than `ARP_ENTRY_TTL_MS`.
    pub fn tick(&mut self, now_ms: u64) {
        self.now_ms = now_ms;
        self.arp.retain(|_, e| {
            e.permanent || now_ms.saturating_sub(e.inserted_ms) < ARP_ENTRY_TTL_MS
        });
    }

    /// Next-hop IP for `dst` (longest-prefix route lookup).
    fn route(&self, dst: Ipv4Addr) -> Ipv4Addr {
        let dst_u = u32::from(dst);
        let mut best: Option<(u32, Option<Ipv4Addr>)> = None;
        for (network, mask, via) in &self.routes {
            if dst_u & mask == *network {
                let better = match &best {
                    Some((best_mask, _)) => mask > best_mask,
                    None => true,
                };
                if better {
                    best = Some((*mask, *via));
                }
            }
        }
        match best {
            Some((_, Some(via))) => via,
            _ => dst,
        }
    }

    fn arp_lookup(&self, ip: Ipv4Addr) -> Option<MacAddr> {
        self.arp.get(&ip).map(|e| e.mac)
    }

    fn arp_request(&mut self, target: Ipv4Addr) {
        let body = arp_body(1, self.mac, self.ip, [0; 6], target);
        self.outbox
            .push(ethernet_frame(BROADCAST_MAC, self.mac, ETHERTYPE_ARP, &body));
    }

    /// Static ARP entry (common on embedded point-to-point links).
    pub fn add_static_arp(&mut self, ip: Ipv4Addr, mac: MacAddr) {
        self.arp.insert(
            ip,
            ArpEntry { mac, inserted_ms: self.now_ms, permanent: true },
        );
    }

    /// Queue a UDP datagram; emits an ARP request instead when the
    /// next hop is unresolved (datagram flushes on the reply).
    pub fn send_udp(&mut self, src_port: u16, dst: SocketAddr, payload: &[u8]) {
        let dst_ip = match dst.ip() {
            IpAddr::V4(v4) => v4,
            IpAddr::V6(_) => return,
        };
        let next = self.route(dst_ip);
        match self.arp_lookup(next) {
            Some(mac) => self.emit_udp(mac, src_port, dst_ip, dst.port(), payload),
            None => {
                self.pending.push((src_port, dst, payload.to_vec()));
                self.arp_request(next);
            }
        }
    }

    /// Receive one queued UDP datagram for `port`, if any.
    pub fn recv_udp(&mut self, port: u16) -> Option<(Vec<u8>, SocketAddr)> {
        self.inbox.get_mut(&port)?.pop_front()
    }

    /// Drain frames the stack wants on the wire.
    pub fn take_output(&mut self) -> Vec<Vec<u8>> {
        core::mem::take(&mut self.outbox)
    }

    /// Process one inbound Ethernet frame.
    pub fn input(&mut self, frame: &[u8]) {
        let Some((dst_mac, _src_mac, ethertype, payload)) = ethernet_parse(frame) else {
            return;
        };
        if dst_mac != self.mac && dst_mac != BROADCAST_MAC {
            return; // not for us (no promiscuous mode)
        }
        match ethertype {
            ETHERTYPE_ARP => self.input_arp(payload),
            ETHERTYPE_IPV4 => self.input_ipv4(payload),
            _ => {}
        }
    }

    fn input_arp(&mut self, body: &[u8]) {
        let Some(pkt) = arp_parse(body) else { return };
        self.arp.insert(
            pkt.spa,
            ArpEntry { mac: pkt.sha, inserted_ms: self.now_ms, permanent: false },
        );
        // Flush anything waiting on this neighbour.
        let mut still_pending = Vec::new();
        for (src_port, dst, payload) in core::mem::take(&mut self.pending) {
            let dst_v4 = match dst.ip() {
                IpAddr::V4(v4) => v4,
                IpAddr::V6(_) => continue,
            };
            if self.route(dst_v4) == pkt.spa {
                self.emit_udp(pkt.sha, src_port, dst_v4, dst.port(), &payload);
            } else {
                still_pending.push((src_port, dst, payload));
            }
        }
        self.pending = still_pending;
        // Flush forwarded packets waiting on this neighbour.
        let mut still_fwd = Vec::new();
        for (next, ip) in core::mem::take(&mut self.fwd_pending) {
            if next == pkt.spa {
                self.outbox
                    .push(ethernet_frame(pkt.sha, self.mac, ETHERTYPE_IPV4, &ip));
            } else {
                still_fwd.push((next, ip));
            }
        }
        self.fwd_pending = still_fwd;
        if pkt.oper == 1 && self.is_local(pkt.tpa) {
            let reply = arp_body(2, self.mac, pkt.tpa, pkt.sha, pkt.spa);
            self.outbox
                .push(ethernet_frame(pkt.sha, self.mac, ETHERTYPE_ARP, &reply));
        }
    }

    fn input_ipv4(&mut self, pkt_bytes: &[u8]) {
        let Some(pkt) = ipv4_parse(pkt_bytes) else { return };
        if !self.is_local(pkt.dst) {
            if self.forwarding {
                self.forward(&pkt, pkt_bytes[8]);
            }
            return;
        }
        match pkt.protocol {
            17 => {
                if let Some((src_port, dst_port, payload)) = udp_parse(pkt.src, pkt.dst, pkt.payload)
                {
                    self.inbox.entry(dst_port).or_default().push_back((
                        payload.to_vec(),
                        SocketAddr::new(IpAddr::V4(pkt.src), src_port),
                    ));
                }
            }
            1 => self.input_icmp(&pkt),
            _ => {}
        }
    }

    /// Forward one packet toward its destination (TTL
    /// decremented; queued with an ARP request out when the
    /// next hop is unresolved, flushed when the reply lands).
    fn forward(&mut self, pkt: &Ipv4Packet<'_>, ttl: u8) {
        if ttl <= 1 {
            return;
        }
        let next = self.route(pkt.dst);
        match self.arp_lookup(next) {
            Some(mac) => {
                let ip = ipv4_build_ttl(pkt.src, pkt.dst, pkt.protocol, pkt.payload, ttl - 1);
                self.outbox
                    .push(ethernet_frame(mac, self.mac, ETHERTYPE_IPV4, &ip));
            }
            None => {
                let ip = ipv4_build_ttl(pkt.src, pkt.dst, pkt.protocol, pkt.payload, ttl - 1);
                self.fwd_pending.push((next, ip));
                self.arp_request(next);
            }
        }
    }

    fn input_icmp(&mut self, pkt: &Ipv4Packet<'_>) {
        // Echo request -> echo reply (type 8 -> 0), same id/seq/data.
        if pkt.payload.len() >= 8 && pkt.payload[0] == 8 && pkt.payload[1] == 0 {
            let next = self.route(pkt.src);
            let Some(dst_mac) = self.arp_lookup(next) else {
                return;
            };
            let mut reply = pkt.payload.to_vec();
            reply[0] = 0;
            reply[2] = 0;
            reply[3] = 0;
            let cksum = internet_checksum(&reply, 0);
            reply[2..4].copy_from_slice(&cksum.to_be_bytes());
            let ip = ipv4_build(pkt.dst, pkt.src, 1, &reply);
            self.outbox
                .push(ethernet_frame(dst_mac, self.mac, ETHERTYPE_IPV4, &ip));
        }
    }

    fn emit_udp(&mut self, dst_mac: MacAddr, src_port: u16, dst_ip: Ipv4Addr, dst_port: u16, payload: &[u8]) {
        let dgram = udp_build(self.ip, dst_ip, src_port, dst_port, payload);
        let pkt = ipv4_build(self.ip, dst_ip, 17, &dgram);
        self.outbox
            .push(ethernet_frame(dst_mac, self.mac, ETHERTYPE_IPV4, &pkt));
    }
}

// ---------------------------------------------------------------------------
// DHCPv4 client (RFC 2131 subset)
// ---------------------------------------------------------------------------

/// A granted DHCP lease.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DhcpLease {
    pub address: Ipv4Addr,
    pub server: Ipv4Addr,
    pub lease_secs: u32,
    pub subnet_mask: Option<Ipv4Addr>,
    pub router: Option<Ipv4Addr>,
    pub dns: Option<Ipv4Addr>,
}

const DHCP_MAGIC: [u8; 4] = [0x63, 0x82, 0x53, 0x63];
const DHCP_CLIENT_PORT: u16 = 68;
const DHCP_SERVER_PORT: u16 = 67;

/// Minimal DHCPv4 client state machine:
/// DISCOVER -> OFFER -> REQUEST -> ACK. Frames are raw Ethernet
/// (broadcast); `handle_frame` returns the next frame to put on
/// the wire, if any. No timers — the caller drives retransmits.
pub struct DhcpClient {
    mac: MacAddr,
    xid: u32,
    lease: Option<DhcpLease>,
    offered: Option<Ipv4Addr>,
}

impl DhcpClient {
    pub fn new(mac: MacAddr, xid: u32) -> Self {
        Self { mac, xid, lease: None, offered: None }
    }

    pub fn lease(&self) -> Option<&DhcpLease> {
        self.lease.as_ref()
    }

    /// DHCPREQUEST renewing the current lease (ciaddr set).
    /// Drive it at T1 (half the lease); the ACK refreshes
    /// `lease()` through `handle_frame` like the initial grant.
    pub fn renew_frame(&self) -> Option<Vec<u8>> {
        let lease = self.lease.as_ref()?;
        Some(self.broadcast_frame(&self.bootp(3, Some(lease.address), Some(lease.server))))
    }

    fn bootp(&self, msg_type: u8, requested: Option<Ipv4Addr>, server: Option<Ipv4Addr>) -> Vec<u8> {
        let mut pkt = alloc::vec![0u8; 240];
        pkt[0] = 1; // op: request
        pkt[1] = 1; // htype: Ethernet
        pkt[2] = 6; // hlen
        pkt[4..8].copy_from_slice(&self.xid.to_be_bytes());
        pkt[12..16].copy_from_slice(&requested.unwrap_or(Ipv4Addr::UNSPECIFIED).octets());
        pkt[28..34].copy_from_slice(&self.mac);
        pkt[236..240].copy_from_slice(&DHCP_MAGIC);
        let mut opts = alloc::vec![53, 1, msg_type];
        if msg_type == 1 {
            // DISCOVER: parameter request list (mask, router, dns, lease)
            opts.extend_from_slice(&[55, 4, 1, 3, 6, 51]);
        }
        if let Some(ip) = requested {
            opts.extend_from_slice(&[50, 4]);
            opts.extend_from_slice(&ip.octets());
        }
        if let Some(ip) = server {
            opts.extend_from_slice(&[54, 4]);
            opts.extend_from_slice(&ip.octets());
        }
        opts.push(255);
        pkt.extend_from_slice(&opts);
        pkt
    }

    fn broadcast_frame(&self, payload: &[u8]) -> Vec<u8> {
        let dgram = udp_build(
            Ipv4Addr::UNSPECIFIED,
            Ipv4Addr::BROADCAST,
            DHCP_CLIENT_PORT,
            DHCP_SERVER_PORT,
            payload,
        );
        let pkt = ipv4_build(Ipv4Addr::UNSPECIFIED, Ipv4Addr::BROADCAST, 17, &dgram);
        ethernet_frame(BROADCAST_MAC, self.mac, ETHERTYPE_IPV4, &pkt)
    }

    /// The DHCPDISCOVER frame.
    pub fn discover_frame(&self) -> Vec<u8> {
        self.broadcast_frame(&self.bootp(1, None, None))
    }

    /// Feed one inbound Ethernet frame. On OFFER returns the
    /// DHCPREQUEST frame to send; on ACK records the lease and
    /// returns None. Anything else is ignored.
    pub fn handle_frame(&mut self, frame: &[u8]) -> Option<Vec<u8>> {
        let (_, _, ethertype, ip_bytes) = ethernet_parse(frame)?;
        if ethertype != ETHERTYPE_IPV4 {
            return None;
        }
        let pkt = ipv4_parse(ip_bytes)?;
        if pkt.protocol != 17 {
            return None;
        }
        let (_, dst_port, payload) = udp_parse(pkt.src, pkt.dst, pkt.payload)?;
        if dst_port != DHCP_CLIENT_PORT || payload.len() < 240 {
            return None;
        }
        if payload[0] != 2 || payload[4..8] != self.xid.to_be_bytes() {
            return None; // not a reply to us
        }
        if payload[236..240] != DHCP_MAGIC {
            return None;
        }
        let yiaddr = Ipv4Addr::new(payload[16], payload[17], payload[18], payload[19]);
        // Parse options.
        let mut msg_type = None;
        let mut server = None;
        let mut lease_secs = None;
        let mut mask = None;
        let mut router = None;
        let mut dns = None;
        let mut i = 240;
        while i < payload.len() {
            let code = payload[i];
            if code == 255 {
                break;
            }
            if code == 0 {
                i += 1;
                continue;
            }
            if i + 1 >= payload.len() {
                break;
            }
            let len = payload[i + 1] as usize;
            let val = payload.get(i + 2..i + 2 + len);
            let Some(val) = val else { break };
            match code {
                53 if len == 1 => msg_type = Some(val[0]),
                54 if len == 4 => server = Some(Ipv4Addr::new(val[0], val[1], val[2], val[3])),
                51 if len == 4 => {
                    lease_secs = Some(u32::from_be_bytes(val.try_into().unwrap()))
                }
                1 if len == 4 => mask = Some(Ipv4Addr::new(val[0], val[1], val[2], val[3])),
                3 if len >= 4 => router = Some(Ipv4Addr::new(val[0], val[1], val[2], val[3])),
                6 if len >= 4 => dns = Some(Ipv4Addr::new(val[0], val[1], val[2], val[3])),
                _ => {}
            }
            i += 2 + len;
        }
        match msg_type {
            Some(2) => {
                // OFFER: request the offered address.
                self.offered = Some(yiaddr);
                Some(self.broadcast_frame(&self.bootp(3, Some(yiaddr), server)))
            }
            Some(5) => {
                // ACK: lease granted.
                self.lease = Some(DhcpLease {
                    address: yiaddr,
                    server: server.unwrap_or(pkt.src),
                    lease_secs: lease_secs.unwrap_or(3600),
                    subnet_mask: mask,
                    router,
                    dns,
                });
                None
            }
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// IPv6 (RFC 8200) + NDP (RFC 4861) + UDP/ICMPv6 — beside IPv4
// ---------------------------------------------------------------------------

use core::net::Ipv6Addr;

pub const ETHERTYPE_IPV6: u16 = 0x86DD;

/// Link-local address (fe80::/64) from a MAC via modified EUI-64.
pub fn link_local_addr(mac: MacAddr) -> Ipv6Addr {
    Ipv6Addr::from(eui64_host(0xfe80_0000_0000_0000_0000_0000_0000_0000u128, mac))
}

/// Global address under a /64 prefix from a MAC (SLAAC-style IID).
pub fn slaac_addr(prefix: Ipv6Addr, mac: MacAddr) -> Ipv6Addr {
    Ipv6Addr::from(eui64_host(u128::from(prefix) & !0xffff_ffff_ffff_ffffu128, mac))
}

fn eui64_host(top: u128, mac: MacAddr) -> u128 {
    let iid: u128 = (((mac[0] ^ 0x02) as u128) << 56)
        | ((mac[1] as u128) << 48)
        | ((mac[2] as u128) << 40)
        | (0xfffeu128 << 24)
        | ((mac[3] as u128) << 16)
        | ((mac[4] as u128) << 8)
        | mac[5] as u128;
    // 0xfffe encodes the inserted ff:fe bytes
    top | iid
}

/// Solicited-node multicast address for `target` (ff02::1:ff00:0/104).
pub fn solicited_node_addr(target: Ipv6Addr) -> Ipv6Addr {
    Ipv6Addr::from(0xff02_0000_0000_0000_0000_0001_ff00_0000u128 | (u128::from(target) & 0xff_ffff))
}

fn multicast_mac(ip: Ipv6Addr) -> MacAddr {
    let b = ip.octets();
    [0x33, 0x33, b[12], b[13], b[14], b[15]]
}

fn ipv6_build(src: Ipv6Addr, dst: Ipv6Addr, next_header: u8, payload: &[u8]) -> Vec<u8> {
    ipv6_build_hop(src, dst, next_header, payload, 64)
}

fn ipv6_build_hop(src: Ipv6Addr, dst: Ipv6Addr, next: u8, payload: &[u8], hop: u8) -> Vec<u8> {
    let mut pkt = Vec::with_capacity(40 + payload.len());
    pkt.extend_from_slice(&0x6000_0000u32.to_be_bytes());
    pkt.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    pkt.push(next);
    pkt.push(hop);
    pkt.extend_from_slice(&src.octets());
    pkt.extend_from_slice(&dst.octets());
    pkt.extend_from_slice(payload);
    pkt
}

struct Ipv6Packet<'a> {
    src: Ipv6Addr,
    dst: Ipv6Addr,
    next_header: u8,
    payload: &'a [u8],
}

fn ipv6_parse(pkt: &'_ [u8]) -> Option<Ipv6Packet<'_>> {
    if pkt.len() < 40 || pkt[0] >> 4 != 6 {
        return None;
    }
    let len = u16::from_be_bytes([pkt[4], pkt[5]]) as usize;
    let end = 40usize.checked_add(len)?;
    if pkt.len() < end {
        return None;
    }
    Some(Ipv6Packet {
        src: Ipv6Addr::from(<[u8; 16]>::try_from(&pkt[8..24]).ok()?),
        dst: Ipv6Addr::from(<[u8; 16]>::try_from(&pkt[24..40]).ok()?),
        next_header: pkt[6],
        payload: &pkt[40..end],
    })
}

/// Ones-complement checksum over the IPv6 pseudo-header + payload.
fn ipv6_checksum(src: Ipv6Addr, dst: Ipv6Addr, next: u8, payload: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    for chunk in src.octets().chunks(2).chain(dst.octets().chunks(2)) {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    sum += (payload.len() as u32) >> 16;
    sum += (payload.len() as u32) & 0xffff;
    sum += next as u32;
    internet_checksum(payload, sum)
}

fn udp6_build(src: Ipv6Addr, dst: Ipv6Addr, src_port: u16, dst_port: u16, payload: &[u8]) -> Vec<u8> {
    let mut dgram = Vec::with_capacity(8 + payload.len());
    dgram.extend_from_slice(&src_port.to_be_bytes());
    dgram.extend_from_slice(&dst_port.to_be_bytes());
    dgram.extend_from_slice(&((8 + payload.len()) as u16).to_be_bytes());
    dgram.extend_from_slice(&[0, 0]);
    dgram.extend_from_slice(payload);
    let cksum = ipv6_checksum(src, dst, 17, &dgram);
    // A computed zero is sent as 0xffff (0 means "none" — illegal in v6).
    let cksum = if cksum == 0 { 0xffff } else { cksum };
    dgram[6..8].copy_from_slice(&cksum.to_be_bytes());
    dgram
}

fn udp6_parse<'a>(src: Ipv6Addr, dst: Ipv6Addr, dgram: &'a [u8]) -> Option<(u16, u16, &'a [u8])> {
    if dgram.len() < 8 || ipv6_checksum(src, dst, 17, dgram) != 0 {
        return None;
    }
    Some((
        u16::from_be_bytes([dgram[0], dgram[1]]),
        u16::from_be_bytes([dgram[2], dgram[3]]),
        &dgram[8..],
    ))
}

fn on_link(prefix: Ipv6Addr, prefix_len: u8, dst: Ipv6Addr) -> bool {
    if prefix_len == 0 {
        return true;
    }
    let shift = 128 - prefix_len.min(128);
    (u128::from(prefix) >> shift) == (u128::from(dst) >> shift)
}

/// IPv6 stack: NDP neighbour discovery instead of ARP, ICMPv6
/// echo, UDP with mandatory pseudo-header checksums. Same pure
/// state-machine shape as `IpStack` (frames in, frames out).
pub struct IpStack6 {
    mac: MacAddr,
    addr: Ipv6Addr,
    prefix_len: u8,
    neighbors: HashMap<Ipv6Addr, ArpEntry>,
    pending: Vec<(u16, SocketAddr, Vec<u8>)>,
    inbox: HashMap<u16, VecDeque<(Vec<u8>, SocketAddr)>>,
    outbox: Vec<Vec<u8>>,
    now_ms: u64,
    default_router: Option<Ipv6Addr>,
}

impl IpStack6 {
    pub fn new(mac: MacAddr, addr: Ipv6Addr) -> Self {
        Self {
            mac,
            addr,
            prefix_len: 64,
            neighbors: HashMap::new(),
            pending: Vec::new(),
            inbox: HashMap::new(),
            outbox: Vec::new(),
            now_ms: 0,
            default_router: None,
        }
    }

    pub fn address(&self) -> Ipv6Addr {
        self.addr
    }

    pub fn set_prefix_len(&mut self, prefix_len: u8) {
        self.prefix_len = prefix_len;
    }

    pub fn set_default_router(&mut self, router: Ipv6Addr) {
        self.default_router = Some(router);
    }

    pub fn add_static_neighbor(&mut self, ip: Ipv6Addr, mac: MacAddr) {
        self.neighbors.insert(
            ip,
            ArpEntry { mac, inserted_ms: self.now_ms, permanent: true },
        );
    }

    /// Advance time; expires learned neighbour entries like ARP.
    pub fn tick(&mut self, now_ms: u64) {
        self.now_ms = now_ms;
        self.neighbors.retain(|_, e| {
            e.permanent || now_ms.saturating_sub(e.inserted_ms) < ARP_ENTRY_TTL_MS
        });
    }

    fn next_hop(&self, dst: Ipv6Addr) -> Ipv6Addr {
        if dst.is_multicast() || on_link(self.addr, self.prefix_len, dst) {
            dst
        } else {
            self.default_router.unwrap_or(dst)
        }
    }

    pub fn send_udp(&mut self, src_port: u16, dst: SocketAddr, payload: &[u8]) {
        let dst_ip = match dst.ip() {
            IpAddr::V6(v6) => v6,
            IpAddr::V4(_) => return,
        };
        if dst_ip.is_multicast() {
            self.emit6(multicast_mac(dst_ip), dst_ip, &udp6_build(self.addr, dst_ip, src_port, dst.port(), payload));
            return;
        }
        let next = self.next_hop(dst_ip);
        match self.neighbors.get(&next).map(|e| e.mac) {
            Some(mac) => {
                self.emit6(mac, dst_ip, &udp6_build(self.addr, dst_ip, src_port, dst.port(), payload))
            }
            None => {
                self.pending.push((src_port, dst, payload.to_vec()));
                self.neighbor_solicitation(next);
            }
        }
    }

    pub fn recv_udp(&mut self, port: u16) -> Option<(Vec<u8>, SocketAddr)> {
        self.inbox.get_mut(&port)?.pop_front()
    }

    pub fn take_output(&mut self) -> Vec<Vec<u8>> {
        core::mem::take(&mut self.outbox)
    }

    fn emit6(&mut self, dst_mac: MacAddr, dst_ip: Ipv6Addr, udp: &[u8]) {
        let pkt = ipv6_build(self.addr, dst_ip, 17, udp);
        self.outbox.push(ethernet_frame(dst_mac, self.mac, ETHERTYPE_IPV6, &pkt));
    }

    fn neighbor_solicitation(&mut self, target: Ipv6Addr) {
        let mut icmp = Vec::with_capacity(32);
        icmp.push(135);
        icmp.push(0);
        icmp.extend_from_slice(&[0, 0]); // checksum below
        icmp.extend_from_slice(&[0, 0, 0, 0]); // reserved
        icmp.extend_from_slice(&target.octets());
        icmp.push(1); // source link-layer option
        icmp.push(1);
        icmp.extend_from_slice(&self.mac);
        let mcast = solicited_node_addr(target);
        let cksum = ipv6_checksum(self.addr, mcast, 58, &icmp);
        icmp[2..4].copy_from_slice(&cksum.to_be_bytes());
        let pkt = ipv6_build(self.addr, mcast, 58, &icmp);
        self.outbox
            .push(ethernet_frame(multicast_mac(mcast), self.mac, ETHERTYPE_IPV6, &pkt));
    }

    fn learn_neighbor(&mut self, ip: Ipv6Addr, mac: MacAddr) {
        self.neighbors.insert(
            ip,
            ArpEntry { mac, inserted_ms: self.now_ms, permanent: false },
        );
        let mut still = Vec::new();
        for (src_port, dst, payload) in core::mem::take(&mut self.pending) {
            let dst6 = match dst.ip() {
                IpAddr::V6(v6) => v6,
                IpAddr::V4(_) => continue,
            };
            if self.next_hop(dst6) == ip {
                self.emit6(mac, dst6, &udp6_build(self.addr, dst6, src_port, dst.port(), &payload));
            } else {
                still.push((src_port, dst, payload));
            }
        }
        self.pending = still;
    }

    pub fn input(&mut self, frame: &[u8]) {
        let Some((dst_mac, src_mac, ethertype, payload)) = ethernet_parse(frame) else {
            return;
        };
        if dst_mac != self.mac && dst_mac != BROADCAST_MAC && dst_mac[..2] != [0x33, 0x33] {
            return;
        }
        if ethertype != ETHERTYPE_IPV6 {
            return;
        }
        let Some(pkt) = ipv6_parse(payload) else { return };
        if pkt.dst != self.addr && !pkt.dst.is_multicast() {
            return; // not for us (no v6 forwarding)
        }
        match pkt.next_header {
            17 => {
                if let Some((src_port, dst_port, data)) = udp6_parse(pkt.src, pkt.dst, pkt.payload) {
                    self.inbox.entry(dst_port).or_default().push_back((
                        data.to_vec(),
                        SocketAddr::new(IpAddr::V6(pkt.src), src_port),
                    ));
                }
            }
            58 => self.input_icmpv6(&pkt, src_mac),
            _ => {}
        }
    }

    fn input_icmpv6(&mut self, pkt: &Ipv6Packet<'_>, src_mac: MacAddr) {
        let icmp = pkt.payload;
        if icmp.len() < 4 || ipv6_checksum(pkt.src, pkt.dst, 58, icmp) != 0 {
            return;
        }
        match icmp[0] {
            135 if icmp.len() >= 24 => {
                // Neighbour Solicitation: learn sender, answer if target is us.
                let mut sender_mac = src_mac;
                if icmp.len() >= 32 && icmp[24] == 1 && icmp[25] == 1 {
                    sender_mac.copy_from_slice(&icmp[26..32]);
                }
                if !pkt.src.is_unspecified() {
                    self.learn_neighbor(pkt.src, sender_mac);
                }
                let target = Ipv6Addr::from(<[u8; 16]>::try_from(&icmp[8..24]).unwrap_or([0; 16]));
                if target == self.addr {
                    let mut na = Vec::with_capacity(32);
                    na.push(136);
                    na.push(0);
                    na.extend_from_slice(&[0, 0]);
                    na.push(0x60); // solicited + override
                    na.extend_from_slice(&[0, 0, 0]);
                    na.extend_from_slice(&target.octets());
                    na.push(2); // target link-layer option
                    na.push(1);
                    na.extend_from_slice(&self.mac);
                    let dst_ip = if pkt.src.is_unspecified() {
                        Ipv6Addr::from(0xff02_0000_0000_0000_0000_0000_0000_0001u128)
                    } else {
                        pkt.src
                    };
                    let cksum = ipv6_checksum(self.addr, dst_ip, 58, &na);
                    na[2..4].copy_from_slice(&cksum.to_be_bytes());
                    let out = ipv6_build(self.addr, dst_ip, 58, &na);
                    self.outbox
                        .push(ethernet_frame(sender_mac, self.mac, ETHERTYPE_IPV6, &out));
                }
            }
            136 if icmp.len() >= 32 => {
                // Neighbour Advertisement: target -> sender MAC.
                let target = Ipv6Addr::from(<[u8; 16]>::try_from(&icmp[8..24]).unwrap_or([0; 16]));
                let mut mac = src_mac;
                if icmp[24] == 2 && icmp[25] == 1 {
                    mac.copy_from_slice(&icmp[26..32]);
                }
                self.learn_neighbor(target, mac);
            }
            128 if icmp.len() >= 8 => {
                let mut reply = icmp.to_vec();
                reply[0] = 129;
                reply[2] = 0;
                reply[3] = 0;
                let cksum = ipv6_checksum(pkt.dst, pkt.src, 58, &reply);
                reply[2..4].copy_from_slice(&cksum.to_be_bytes());
                let out = ipv6_build(pkt.dst, pkt.src, 58, &reply);
                self.outbox
                    .push(ethernet_frame(src_mac, self.mac, ETHERTYPE_IPV6, &out));
            }
            _ => {}
        }
    }
}

// ---------------------------------------------------------------------------
// UdpTransport over raw Ethernet (virtual cable for tests/harness)
// ---------------------------------------------------------------------------

#[cfg(feature = "std")]
/// Virtual Ethernet cable: endpoints register by MAC; frames are
/// delivered by destination MAC (broadcast goes to all others).
pub struct EthernetCable {
    inboxes: Mutex<HashMap<MacAddr, mpsc::Sender<Vec<u8>>>>,
}

#[cfg(feature = "std")]
impl EthernetCable {
    pub fn new() -> Self {
        Self { inboxes: Mutex::new(HashMap::new()) }
    }

    /// Route one frame by destination MAC (broadcast to all
    /// other endpoints).
    pub fn deliver(&self, frame: Vec<u8>) {
        let Some((dst_mac, src_mac, _, _)) = ethernet_parse(&frame) else {
            return;
        };
        let inboxes = self.inboxes.lock().unwrap();
        if dst_mac == BROADCAST_MAC {
            for (mac, tx) in inboxes.iter() {
                if *mac != src_mac {
                    let _ = tx.send(frame.clone());
                }
            }
        } else if let Some(tx) = inboxes.get(&dst_mac) {
            let _ = tx.send(frame);
        }
    }

    /// Create a raw frame endpoint (DHCP, custom L2 protocols,
    /// test harnesses scripting a server).
    pub fn raw_endpoint(self: &Arc<Self>, mac: MacAddr) -> Arc<RawEthernetPort> {
        let (tx, rx) = mpsc::channel();
        self.inboxes.lock().unwrap().insert(mac, tx);
        Arc::new(RawEthernetPort {
            mac,
            inbox: Mutex::new(rx),
            cable: self.clone(),
        })
    }

    /// Create a transport endpoint: one IP stack bound to `addr`.
    pub fn endpoint(self: &Arc<Self>, mac: MacAddr, addr: SocketAddr) -> Arc<EthernetUdpTransport> {
        let (tx, rx) = mpsc::channel();
        self.inboxes.lock().unwrap().insert(mac, tx);
        let ip = match addr.ip() {
            IpAddr::V4(v4) => v4,
            IpAddr::V6(_) => Ipv4Addr::UNSPECIFIED,
        };
        Arc::new(EthernetUdpTransport {
            mac,
            addr,
            stack: Mutex::new(IpStack::new(mac, ip)),
            inbox: Mutex::new(rx),
            cable: self.clone(),
        })
    }
}

#[cfg(feature = "std")]
impl Default for EthernetCable {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(feature = "std")]
pub struct EthernetUdpTransport {
    #[allow(dead_code)]
    mac: MacAddr,
    addr: SocketAddr,
    stack: Mutex<IpStack>,
    inbox: Mutex<mpsc::Receiver<Vec<u8>>>,
    cable: Arc<EthernetCable>,
}

#[cfg(feature = "std")]
/// Raw Ethernet frame endpoint on the virtual cable.
#[cfg(feature = "std")]
pub struct RawEthernetPort {
    #[allow(dead_code)]
    mac: MacAddr,
    inbox: Mutex<mpsc::Receiver<Vec<u8>>>,
    cable: Arc<EthernetCable>,
}

#[cfg(feature = "std")]
impl RawEthernetPort {
    pub fn send_frame(&self, frame: Vec<u8>) {
        self.cable.deliver(frame);
    }

    /// Next inbound frame; None on timeout.
    pub fn recv_frame(&self, timeout: Duration) -> Option<Vec<u8>> {
        self.inbox.lock().unwrap().recv_timeout(timeout).ok()
    }
}

#[cfg(feature = "std")]
impl EthernetUdpTransport {
    fn put_on_cable(&self, frame: Vec<u8>) {
        self.cable.deliver(frame);
    }

    fn pump_outbox(&self) {
        let frames = self.stack.lock().unwrap().take_output();
        for frame in frames {
            self.put_on_cable(frame);
        }
    }
}

#[cfg(feature = "std")]
impl UdpTransport for EthernetUdpTransport {
    fn send_to(&self, buf: &[u8], dest: SocketAddr) -> io::Result<()> {
        self.stack.lock().unwrap().send_udp(self.addr.port(), dest, buf);
        self.pump_outbox();
        Ok(())
    }

    fn recv_from(&self, timeout: Duration) -> io::Result<Option<(Vec<u8>, SocketAddr)>> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(packet) = self.stack.lock().unwrap().recv_udp(self.addr.port()) {
                return Ok(Some(packet));
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(None);
            }
            match self.inbox.lock().unwrap().recv_timeout(deadline - now) {
                Ok(frame) => {
                    self.stack.lock().unwrap().input(&frame);
                    self.pump_outbox();
                }
                Err(mpsc::RecvTimeoutError::Timeout) => return Ok(None),
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(io::Error::new(io::ErrorKind::BrokenPipe, "cable closed"));
                }
            }
        }
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.addr)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mac(b: u8) -> MacAddr {
        [0x02, 0, 0, 0, 0, b]
    }

    #[test]
    fn checksum_known_vector() {
        // RFC 1071 example: 00 01 f2 03 f4 f5 f6 f7 -> 0x220d.
        assert_eq!(
            internet_checksum(&[0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7], 0),
            0x220d
        );
    }

    #[test]
    fn udp_roundtrip_between_stacks() {
        let ip_a = Ipv4Addr::new(10, 0, 0, 1);
        let ip_b = Ipv4Addr::new(10, 0, 0, 2);
        let mut a = IpStack::new(mac(1), ip_a);
        let mut b = IpStack::new(mac(2), ip_b);
        a.add_static_arp(ip_b, mac(2));
        b.add_static_arp(ip_a, mac(1));

        a.send_udp(5000, SocketAddr::new(IpAddr::V4(ip_b), 6000), b"hello");
        let frames = a.take_output();
        assert_eq!(frames.len(), 1);
        b.input(&frames[0]);
        let (payload, src) = b.recv_udp(6000).expect("delivered");
        assert_eq!(payload, b"hello");
        assert_eq!(src, SocketAddr::new(IpAddr::V4(ip_a), 5000));
    }

    #[test]
    fn arp_resolution_flushes_pending() {
        let ip_a = Ipv4Addr::new(10, 0, 0, 1);
        let ip_b = Ipv4Addr::new(10, 0, 0, 2);
        let mut a = IpStack::new(mac(1), ip_a);
        let mut b = IpStack::new(mac(2), ip_b);

        a.send_udp(5000, SocketAddr::new(IpAddr::V4(ip_b), 6000), b"queued");
        let frames = a.take_output();
        assert_eq!(frames.len(), 1, "ARP request first");
        b.input(&frames[0]);
        let replies = b.take_output();
        assert_eq!(replies.len(), 1, "ARP reply");
        a.input(&replies[0]);
        let flushed = a.take_output();
        assert_eq!(flushed.len(), 1, "pending UDP flushed on ARP reply");
        b.input(&flushed[0]);
        assert_eq!(b.recv_udp(6000).unwrap().0, b"queued");
    }

    fn dhcp_reply(xid: u32, client_mac: MacAddr, msg_type: u8, yiaddr: Ipv4Addr) -> Vec<u8> {
        let server_ip = Ipv4Addr::new(10, 0, 0, 254);
        let mut pkt = vec![0u8; 240];
        pkt[0] = 2; // reply
        pkt[1] = 1;
        pkt[2] = 6;
        pkt[4..8].copy_from_slice(&xid.to_be_bytes());
        pkt[16..20].copy_from_slice(&yiaddr.octets());
        pkt[28..34].copy_from_slice(&client_mac);
        pkt[236..240].copy_from_slice(&DHCP_MAGIC);
        let mut opts = vec![53, 1, msg_type, 54, 4];
        opts.extend_from_slice(&server_ip.octets());
        opts.extend_from_slice(&[51, 4, 0, 0, 0x1c, 0x20]); // 7200s
        opts.extend_from_slice(&[1, 4, 255, 255, 255, 0]);
        opts.extend_from_slice(&[3, 4]);
        opts.extend_from_slice(&server_ip.octets());
        opts.push(255);
        pkt.extend_from_slice(&opts);
        let dgram = udp_build(server_ip, Ipv4Addr::BROADCAST, 67, 68, &pkt);
        let ip = ipv4_build(server_ip, Ipv4Addr::BROADCAST, 17, &dgram);
        ethernet_frame(client_mac, [0x02, 0, 0, 0, 0, 254], ETHERTYPE_IPV4, &ip)
    }

    #[test]
    fn dhcp_acquires_lease() {
        let mut client = DhcpClient::new(mac(9), 0xdead_beef);
        let discover = client.discover_frame();
        assert_eq!(ethernet_parse(&discover).unwrap().0, BROADCAST_MAC);

        // Wrong xid is ignored.
        let foreign = dhcp_reply(0x1234, mac(9), 2, Ipv4Addr::new(10, 0, 0, 50));
        assert!(client.handle_frame(&foreign).is_none());
        assert!(client.lease().is_none());

        let offer = dhcp_reply(0xdead_beef, mac(9), 2, Ipv4Addr::new(10, 0, 0, 50));
        let request = client.handle_frame(&offer).expect("REQUEST after OFFER");
        assert!(client.lease().is_none());
        let _ = request;

        let ack = dhcp_reply(0xdead_beef, mac(9), 5, Ipv4Addr::new(10, 0, 0, 50));
        assert!(client.handle_frame(&ack).is_none());
        let lease = client.lease().expect("lease after ACK");
        assert_eq!(lease.address, Ipv4Addr::new(10, 0, 0, 50));
        assert_eq!(lease.server, Ipv4Addr::new(10, 0, 0, 254));
        assert_eq!(lease.lease_secs, 7200);
        assert_eq!(lease.subnet_mask, Some(Ipv4Addr::new(255, 255, 255, 0)));
        assert_eq!(lease.router, Some(Ipv4Addr::new(10, 0, 0, 254)));
    }

    #[test]
    fn gateway_routing_frames_to_gateway_mac() {
        let gw_ip = Ipv4Addr::new(10, 0, 0, 1);
        let remote = Ipv4Addr::new(192, 168, 1, 7);
        let mut a = IpStack::new(mac(1), Ipv4Addr::new(10, 0, 0, 5));
        a.set_network(Ipv4Addr::new(255, 255, 255, 0), Some(gw_ip));
        a.add_static_arp(gw_ip, mac(254));
        // Even with the remote's MAC statically known, off-subnet
        // traffic must go to the gateway's MAC, IP dst unchanged.
        a.add_static_arp(remote, mac(7));
        a.send_udp(5000, SocketAddr::new(IpAddr::V4(remote), 6000), b"routed");
        let frames = a.take_output();
        assert_eq!(frames.len(), 1);
        let (dst_mac, _, ethertype, ip_bytes) = ethernet_parse(&frames[0]).unwrap();
        assert_eq!(dst_mac, mac(254), "frame addressed to the gateway");
        assert_eq!(ethertype, ETHERTYPE_IPV4);
        let pkt = ipv4_parse(ip_bytes).unwrap();
        assert_eq!(pkt.dst, remote, "IP destination preserved");
    }

    #[test]
    fn forwarding_delivers_across_subnets() {
        let client_ip = Ipv4Addr::new(10, 0, 0, 5);
        let server_ip = Ipv4Addr::new(192, 168, 1, 7);
        let mut client = IpStack::new(mac(1), client_ip);
        client.set_network(
            Ipv4Addr::new(255, 255, 255, 0),
            Some(Ipv4Addr::new(10, 0, 0, 1)),
        );
        let mut router = IpStack::new(mac(254), Ipv4Addr::new(10, 0, 0, 1));
        router.add_address(Ipv4Addr::new(192, 168, 1, 1));
        router.set_forwarding(true);
        router.add_route(Ipv4Addr::new(10, 0, 0, 0), 24, None);
        router.add_route(Ipv4Addr::new(192, 168, 1, 0), 24, None);
        let mut server = IpStack::new(mac(7), server_ip);
        server.set_network(
            Ipv4Addr::new(255, 255, 255, 0),
            Some(Ipv4Addr::new(192, 168, 1, 1)),
        );

        fn pump(stacks: &mut [&mut IpStack; 3]) {
            for _ in 0..60 {
                let mut frames: Vec<(usize, Vec<u8>)> = Vec::new();
                for (i, s) in stacks.iter_mut().enumerate() {
                    for f in s.take_output() {
                        frames.push((i, f));
                    }
                }
                if frames.is_empty() {
                    break;
                }

                for (from, frame) in frames {
                    for (j, s) in stacks.iter_mut().enumerate() {
                        if j != from {
                            s.input(&frame);
                        }
                    }
                }
            }
        }
        let mut stacks: [&mut IpStack; 3] = [&mut client, &mut router, &mut server];

        stacks[0].send_udp(
            5000,
            SocketAddr::new(IpAddr::V4(server_ip), 6000),
            b"across",
        );
        pump(&mut stacks);
        let (payload, src) = stacks[2]
            .recv_udp(6000)
            .expect("server received via gateway");
        assert_eq!(payload, b"across");
        assert_eq!(src, SocketAddr::new(IpAddr::V4(client_ip), 5000));

        stacks[2].send_udp(
            6000,
            SocketAddr::new(IpAddr::V4(client_ip), 5000),
            b"back",
        );
        pump(&mut stacks);
        let (payload, _) = stacks[0]
            .recv_udp(5000)
            .expect("client received the reply");
        assert_eq!(payload, b"back");
    }

    #[test]
    fn arp_entries_expire_with_tick() {
        let ip_b = Ipv4Addr::new(10, 0, 0, 2);
        let mut a = IpStack::new(mac(1), Ipv4Addr::new(10, 0, 0, 1));
        let mut b = IpStack::new(mac(2), ip_b);
        b.add_static_arp(Ipv4Addr::new(10, 0, 0, 1), mac(1));

        a.tick(1_000);
        a.send_udp(5000, SocketAddr::new(IpAddr::V4(ip_b), 6000), b"one");
        let arp_req = a.take_output();
        assert_eq!(arp_req.len(), 1, "first send ARPs");
        b.input(&arp_req[0]);
        let reply = b.take_output();
        // b's queued payload was never queued (send happened on b's
        // side only via its own calls); deliver the ARP reply.
        a.input(&reply[0]);
        let data_frames = a.take_output();
        assert_eq!(data_frames.len(), 1, "flush after ARP reply");

        // Still fresh just before the TTL.
        a.tick(1_000 + ARP_ENTRY_TTL_MS - 1);
        a.send_udp(5000, SocketAddr::new(IpAddr::V4(ip_b), 6000), b"two");
        assert_eq!(a.take_output().len(), 1, "fresh entry: direct send");

        // Expired after it: next send ARPs again.
        a.tick(1_000 + ARP_ENTRY_TTL_MS + 1);
        a.send_udp(5000, SocketAddr::new(IpAddr::V4(ip_b), 6000), b"three");
        let frames = a.take_output();
        assert_eq!(frames.len(), 1);
        let (_, _, ethertype, _) = ethernet_parse(&frames[0]).unwrap();
        assert_eq!(ethertype, ETHERTYPE_ARP, "expired entry re-ARPs");
    }

    #[test]
    fn dhcp_renewal_refreshes_lease() {
        let mut client = DhcpClient::new(mac(9), 0xabc);
        let offer = dhcp_reply(0xabc, mac(9), 2, Ipv4Addr::new(10, 0, 0, 50));
        client.handle_frame(&offer).unwrap();
        let ack = dhcp_reply(0xabc, mac(9), 5, Ipv4Addr::new(10, 0, 0, 50));
        client.handle_frame(&ack);
        assert_eq!(client.lease().unwrap().lease_secs, 7200);

        let renew = client.renew_frame().expect("renewal frame");
        let (_, _, ethertype, ip_bytes) = ethernet_parse(&renew).unwrap();
        assert_eq!(ethertype, ETHERTYPE_IPV4);
        let pkt = ipv4_parse(ip_bytes).unwrap();
        let (_, _, bootp) = udp_parse(pkt.src, pkt.dst, pkt.payload).unwrap();
        assert_eq!(bootp[0], 1);
        assert_eq!(&bootp[12..16], &[10, 0, 0, 50], "ciaddr is the leased address");

        // ACK the renewal with a longer lease.
        let mut ack2 = dhcp_reply(0xabc, mac(9), 5, Ipv4Addr::new(10, 0, 0, 50));
        // bump lease option 7200 -> 14400 (0x3840)
        let pos = ack2.windows(2).position(|w| w == [51, 4]).unwrap();
        ack2[pos + 2..pos + 6].copy_from_slice(&14400u32.to_be_bytes());
        // fix UDP checksum after mutation: rebuild via zero-checksum acceptance
        // (udp_parse accepts zero checksum only when field is 0; recompute not
        // needed because we zero it below)
        let ip_off = 14;
        let udp_off = ip_off + 20;
        ack2[udp_off + 6] = 0;
        ack2[udp_off + 7] = 0;
        client.handle_frame(&ack2);
        assert_eq!(client.lease().unwrap().lease_secs, 14400);
    }

    #[test]
    fn ipv6_link_local_from_mac() {
        let addr = link_local_addr(mac(1));
        assert_eq!(addr.segments()[0], 0xfe80);
        assert_eq!(addr.octets()[8], 0x00); // U/L bit flipped: mac(1)[0]=2 -> 0
        assert_eq!(&addr.octets()[11..13], &[0xff, 0xfe]);
    }

    #[test]
    fn ipv6_udp_roundtrip_via_ndp() {
        let ip_a = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5);
        let ip_b = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 7);
        let mut a = IpStack6::new(mac(1), ip_a);
        let mut b = IpStack6::new(mac(7), ip_b);
        a.send_udp(5000, SocketAddr::new(IpAddr::V6(ip_b), 6000), b"v6 hello");
        // First output: NDP solicitation to the solicited-node multicast.
        let ns = a.take_output();
        assert_eq!(ns.len(), 1);
        let (dst_mac, _, ethertype, _) = ethernet_parse(&ns[0]).unwrap();
        assert_eq!(ethertype, ETHERTYPE_IPV6);
        assert_eq!(&dst_mac[..2], &[0x33, 0x33]);
        b.input(&ns[0]);
        let na = b.take_output();
        assert_eq!(na.len(), 1, "B answers the solicitation");
        a.input(&na[0]);
        let data = a.take_output();
        assert_eq!(data.len(), 1, "pending datagram flushed after NA");
        b.input(&data[0]);
        let (payload, src) = b.recv_udp(6000).expect("B received v6 datagram");
        assert_eq!(payload, b"v6 hello");
        assert_eq!(src, SocketAddr::new(IpAddr::V6(ip_a), 5000));
    }

    #[test]
    fn ipv6_offlink_solicits_default_router() {
        let router = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);
        let remote = Ipv6Addr::new(0x2001, 0xdb8, 1, 0, 0, 0, 0, 9);
        let mut a = IpStack6::new(mac(1), Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5));
        a.set_default_router(router);
        a.send_udp(5000, SocketAddr::new(IpAddr::V6(remote), 6000), b"off");
        let frames = a.take_output();
        assert_eq!(frames.len(), 1);
        let (_, _, _, ip_bytes) = ethernet_parse(&frames[0]).unwrap();
        let pkt = ipv6_parse(ip_bytes).unwrap();
        assert_eq!(pkt.dst, solicited_node_addr(router), "solicits the router, not the remote");
        assert_eq!(pkt.payload[0], 135);
    }

    #[test]
    fn ipv6_echo_reply() {
        let ip_a = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5);
        let ip_b = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 7);
        let mut b = IpStack6::new(mac(7), ip_b);
        let mut icmp = alloc::vec![128u8, 0, 0, 0, 0, 1, 0, 1];
        icmp.extend_from_slice(b"ping6");
        let cksum = ipv6_checksum(ip_a, ip_b, 58, &icmp);
        icmp[2..4].copy_from_slice(&cksum.to_be_bytes());
        let frame = ethernet_frame(mac(7), mac(1), ETHERTYPE_IPV6, &ipv6_build(ip_a, ip_b, 58, &icmp));
        b.input(&frame);
        let out = b.take_output();
        assert_eq!(out.len(), 1);
        let (_, _, _, ip_bytes) = ethernet_parse(&out[0]).unwrap();
        let pkt = ipv6_parse(ip_bytes).unwrap();
        assert_eq!(pkt.payload[0], 129, "echo reply");
        assert_eq!(&pkt.payload[8..], b"ping6");
    }

    #[test]
    fn corrupt_udp_checksum_dropped() {
        let ip_a = Ipv4Addr::new(10, 0, 0, 1);
        let ip_b = Ipv4Addr::new(10, 0, 0, 2);
        let mut a = IpStack::new(mac(1), ip_a);
        let mut b = IpStack::new(mac(2), ip_b);
        a.add_static_arp(ip_b, mac(2));
        a.send_udp(5000, SocketAddr::new(IpAddr::V4(ip_b), 6000), b"data");
        let mut frame = a.take_output().pop().unwrap();
        let last = frame.len() - 1;
        frame[last] ^= 0xff;
        b.input(&frame);
        assert!(b.recv_udp(6000).is_none());
    }
}
