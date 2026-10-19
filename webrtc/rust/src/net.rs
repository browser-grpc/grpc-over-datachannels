//! Minimal hand-rolled L2–L4 stack for bare-metal targets:
//! Ethernet II framing, ARP (RFC 826), IPv4 (RFC 791), UDP
//! (RFC 768), and ICMP echo replies. Zero dependencies, like the
//! rest of the crate — this replaces the lwIP/smoltcp assumption
//! below the platform `UdpTransport` seam.
//!
//! Deliberate limits (documented, not silent): IPv4 only, no
//! header options, no fragmentation (fragments are dropped), one
//! address per interface, ARP for the local subnet only (no
//! gateway routing). `IpStack` is a pure state machine — frames
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
    let total = (20 + payload.len()) as u16;
    let mut pkt = Vec::with_capacity(total as usize);
    pkt.push(0x45); // version 4, IHL 5 (no options)
    pkt.push(0); // DSCP/ECN
    pkt.extend_from_slice(&total.to_be_bytes());
    pkt.extend_from_slice(&0x2au16.to_be_bytes()); // identification
    pkt.extend_from_slice(&0x4000u16.to_be_bytes()); // DF, no fragment offset
    pkt.push(64); // TTL
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

/// One-interface IPv4 stack. Frames in via `input`, frames out via
/// `take_output`; UDP payloads queue per local port.
pub struct IpStack {
    mac: MacAddr,
    ip: Ipv4Addr,
    arp: HashMap<Ipv4Addr, MacAddr>,
    pending: Vec<(u16, SocketAddr, Vec<u8>)>,
    outbox: Vec<Vec<u8>>,
    inbox: HashMap<u16, VecDeque<(Vec<u8>, SocketAddr)>>,
}

impl IpStack {
    pub fn new(mac: MacAddr, ip: Ipv4Addr) -> Self {
        Self {
            mac,
            ip,
            arp: HashMap::new(),
            pending: Vec::new(),
            outbox: Vec::new(),
            inbox: HashMap::new(),
        }
    }

    /// Static ARP entry (common on embedded point-to-point links).
    pub fn add_static_arp(&mut self, ip: Ipv4Addr, mac: MacAddr) {
        self.arp.insert(ip, mac);
    }

    /// Queue a UDP datagram; emits an ARP request instead when the
    /// next hop is unresolved (datagram flushes on the reply).
    pub fn send_udp(&mut self, src_port: u16, dst: SocketAddr, payload: &[u8]) {
        let dst_ip = match dst.ip() {
            IpAddr::V4(v4) => v4,
            IpAddr::V6(_) => return,
        };
        match self.arp.get(&dst_ip).copied() {
            Some(mac) => self.emit_udp(mac, src_port, dst_ip, dst.port(), payload),
            None => {
                self.pending.push((src_port, dst, payload.to_vec()));
                let body = arp_body(1, self.mac, self.ip, [0; 6], dst_ip);
                self.outbox.push(ethernet_frame(
                    BROADCAST_MAC,
                    self.mac,
                    ETHERTYPE_ARP,
                    &body,
                ));
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
        self.arp.insert(pkt.spa, pkt.sha);
        // Flush anything waiting on this neighbour.
        let mut still_pending = Vec::new();
        for (src_port, dst, payload) in core::mem::take(&mut self.pending) {
            if dst.ip() == IpAddr::V4(pkt.spa) {
                self.emit_udp(pkt.sha, src_port, pkt.spa, dst.port(), &payload);
            } else {
                still_pending.push((src_port, dst, payload));
            }
        }
        self.pending = still_pending;
        if pkt.oper == 1 && pkt.tpa == self.ip {
            let reply = arp_body(2, self.mac, self.ip, pkt.sha, pkt.spa);
            self.outbox
                .push(ethernet_frame(pkt.sha, self.mac, ETHERTYPE_ARP, &reply));
        }
    }

    fn input_ipv4(&mut self, pkt_bytes: &[u8]) {
        let Some(pkt) = ipv4_parse(pkt_bytes) else { return };
        if pkt.dst != self.ip {
            return; // no forwarding
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

    fn input_icmp(&mut self, pkt: &Ipv4Packet<'_>) {
        // Echo request -> echo reply (type 8 -> 0), same id/seq/data.
        if pkt.payload.len() >= 8 && pkt.payload[0] == 8 && pkt.payload[1] == 0 {
            let Some(dst_mac) = self.arp.get(&pkt.src).copied() else {
                return;
            };
            let mut reply = pkt.payload.to_vec();
            reply[0] = 0;
            reply[2] = 0;
            reply[3] = 0;
            let cksum = internet_checksum(&reply, 0);
            reply[2..4].copy_from_slice(&cksum.to_be_bytes());
            let ip = ipv4_build(self.ip, pkt.src, 1, &reply);
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
