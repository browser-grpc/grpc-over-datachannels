//! TURN (RFC 5766) relay support: an Allocate over the peer's own
//! UDP socket yields a relayed candidate; once the peer connects,
//! its traffic for the nominated pair is wrapped in Send/Data
//! indications through the allocation. Long-term credentials
//! (401 REALM/NONCE challenge, MD5 key) are the only auth mode.
//! Permissions are created per remote candidate at connect time
//! and a channel is bound per peer address, so pair traffic uses
//! 4-byte ChannelData framing (Send/Data indications remain the
//! fallback for unbound addresses, and are accepted inbound). A
//! background refresher thread re-issues CreatePermission,
//! ChannelBind, and Refresh for the life of the peer; refreshes
//! are send-only because the demux thread owns reception and
//! consumes the responses.
//!
//! The handshake is a synchronous request/response exchange on
//! the peer socket, mirroring gather_srflx: before connect() owns
//! the receive loop, stray packets are simply not TURN responses
//! and are dropped (ICE retransmits cover the loss).

use crate::crypto::md5;
use crate::proto_gen::{stun_attr, stun_msg};
use crate::stun::Message;
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

/// One TURN server (UDP) with long-term credentials.
#[derive(Clone, Debug)]
pub struct TurnServerConfig {
    pub address: String,
    pub username: String,
    pub password: String,
}

/// One live TURN allocation.
#[derive(Clone, Debug)]
pub struct TurnClient {
    pub server: SocketAddr,
    pub relayed: Option<SocketAddr>,
    pub mapped: Option<SocketAddr>,
    pub username: String,
    pub realm: String,
    pub nonce: String,
    pub key: Vec<u8>, // MD5(username:realm:password)
    /// Server-granted allocation lifetime.
    pub lifetime: Duration,
    /// Channel bindings: peer address -> channel number.
    pub bindings: std::collections::HashMap<SocketAddr, u16>,
    /// Channel bindings, reverse: channel number -> peer address.
    pub channels: std::collections::HashMap<u16, SocketAddr>,
}

/// The LIFETIME attribute of a response (default 600 s).
pub fn lifetime_of(msg: &Message) -> Duration {
    match msg.attr(stun_attr::LIFETIME) {
        Some(value) if value.len() >= 4 => {
            let secs = u32::from_be_bytes(value[..4].try_into().unwrap());
            if secs == 0 {
                Duration::from_secs(600)
            } else {
                Duration::from_secs(secs as u64)
            }
        }
        _ => Duration::from_secs(600),
    }
}

/// How often permissions and the allocation are refreshed: 80%
/// of whichever expires first — permissions (300 s) or the
/// allocation lifetime.
pub fn refresh_interval(client: &TurnClient) -> Duration {
    let interval = client.lifetime * 4 / 5;
    let interval = if interval.is_zero() || interval > Duration::from_secs(240) {
        Duration::from_secs(240)
    } else {
        interval
    };
    interval.max(Duration::from_millis(250))
}

/// Encode an IPv4 XOR-{PEER,RELAYED,MAPPED}-ADDRESS attribute value.
pub fn xor_address_value(addr: &SocketAddr) -> Vec<u8> {
    let mut out = vec![0u8; 8];
    out[1] = 1;
    let ip = match addr.ip() {
        std::net::IpAddr::V4(v4) => u32::from(v4),
        std::net::IpAddr::V6(_) => 0,
    };
    out[2..4].copy_from_slice(&(addr.port() ^ (crate::stun::MAGIC >> 16) as u16).to_be_bytes());
    out[4..8].copy_from_slice(&(ip ^ crate::stun::MAGIC).to_be_bytes());
    out
}

/// Decode an XOR-encoded address attribute of a message.
pub fn decode_xor_address(msg: &Message, attr_type: u16) -> Option<SocketAddr> {
    crate::stun::decode_xor_mapped(msg.attr(attr_type)?, &msg.transaction_id)
}

pub fn turn_error_code(msg: &Message) -> u32 {
    match msg.attr(stun_attr::ERROR_CODE) {
        Some(value) if value.len() >= 4 => value[2] as u32 * 100 + value[3] as u32,
        _ => 0,
    }
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}

/// One synchronous TURN control exchange on the peer socket:
/// send, then poll until the response (matched by transaction id)
/// or the deadline. Returns the response message.
pub fn turn_request(
    socket: &UdpSocket,
    server: SocketAddr,
    msg: &Message,
    key: Option<&[u8]>,
    timeout: Duration,
) -> io::Result<Message> {
    socket.send_to(&msg.encode(key), server)?;
    let deadline = Instant::now() + timeout;
    socket.set_read_timeout(Some(Duration::from_millis(50)))?;
    let mut buf = vec![0u8; 65536];
    let result = loop {
        match socket.recv_from(&mut buf) {
            Ok((n, _src)) => {
                if let Some(resp) = Message::decode(&buf[..n]) {
                    if resp.transaction_id == msg.transaction_id {
                        break Ok(resp);
                    }
                }
            }
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::TimedOut =>
            {
                if Instant::now() >= deadline {
                    break Err(bad("turn: timed out waiting for response"));
                }
            }
            Err(e) => break Err(e),
        }
    };
    let _ = socket.set_read_timeout(None);
    result
}

/// Runs the Allocate handshake (with the 401 long-term-credential
/// dance when the server demands it).
pub fn allocate_turn(
    socket: &UdpSocket,
    cfg: &TurnServerConfig,
    timeout: Duration,
) -> io::Result<TurnClient> {
    use std::net::ToSocketAddrs;
    let server = cfg
        .address
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| bad("turn server does not resolve"))?;
    let mut client = TurnClient {
        server,
        relayed: None,
        mapped: None,
        username: cfg.username.clone(),
        realm: String::new(),
        nonce: String::new(),
        key: Vec::new(),
        lifetime: Duration::from_secs(600),
        bindings: std::collections::HashMap::new(),
        channels: std::collections::HashMap::new(),
    };
    let build = |client: &TurnClient, auth: bool| {
        let mut msg = Message::new(stun_msg::ALLOCATE_REQUEST);
        msg.attrs
            .push((stun_attr::REQUESTED_TRANSPORT, vec![17, 0, 0, 0]));
        if auth {
            msg.attrs.push((stun_attr::USERNAME, cfg.username.clone().into_bytes()));
            msg.attrs.push((stun_attr::REALM, client.realm.clone().into_bytes()));
            msg.attrs.push((stun_attr::NONCE, client.nonce.clone().into_bytes()));
        }
        msg
    };

    let mut resp = turn_request(socket, server, &build(&client, false), None, timeout)?;
    if resp.msg_type == stun_msg::ALLOCATE_ERROR && turn_error_code(&resp) == 401 {
        client.realm = resp
            .attr(stun_attr::REALM)
            .map(|v| String::from_utf8_lossy(v).into_owned())
            .unwrap_or_default();
        client.nonce = resp
            .attr(stun_attr::NONCE)
            .map(|v| String::from_utf8_lossy(v).into_owned())
            .unwrap_or_default();
        client.key = md5(format!("{}:{}:{}", cfg.username, client.realm, cfg.password).as_bytes()).to_vec();
        resp = turn_request(socket, server, &build(&client, true), Some(&client.key), timeout)?;
    }
    if resp.msg_type != stun_msg::ALLOCATE_SUCCESS {
        return Err(bad(&format!(
            "turn: allocate failed (type {:#x}, code {})",
            resp.msg_type,
            turn_error_code(&resp)
        )));
    }
    client.relayed = decode_xor_address(&resp, stun_attr::XOR_RELAYED_ADDRESS);
    client.mapped = decode_xor_address(&resp, stun_attr::XOR_MAPPED_ADDRESS);
    if client.relayed.is_none() {
        return Err(bad("turn: allocate success without XOR-RELAYED-ADDRESS"));
    }
    client.lifetime = lifetime_of(&resp);
    Ok(client)
}

fn build_create_permission(client: &TurnClient, peers: &[SocketAddr]) -> Option<Message> {
    let mut msg = Message::new(stun_msg::CREATE_PERMISSION_REQUEST);
    let mut seen = std::collections::HashSet::new();
    for cand in peers {
        if !seen.insert(*cand) {
            continue;
        }
        msg.attrs.push((stun_attr::XOR_PEER_ADDRESS, xor_address_value(cand)));
    }
    if seen.is_empty() {
        return None;
    }
    msg.attrs.push((stun_attr::USERNAME, client.username.clone().into_bytes()));
    msg.attrs.push((stun_attr::REALM, client.realm.clone().into_bytes()));
    msg.attrs.push((stun_attr::NONCE, client.nonce.clone().into_bytes()));
    Some(msg)
}

/// Installs relay permissions for the given remote candidates so
/// the server forwards our relayed traffic (and delivers the
/// peer's). Best-effort, like an unreachable candidate.
pub fn create_permissions(
    socket: &UdpSocket,
    client: &TurnClient,
    candidates: &[SocketAddr],
    timeout: Duration,
) {
    let Some(msg) = build_create_permission(client, candidates) else {
        return;
    };
    let _ = turn_request(socket, client.server, &msg, Some(&client.key), timeout);
}

fn build_channel_bind(client: &TurnClient, channel: u16, peer: &SocketAddr) -> Message {
    let mut msg = Message::new(stun_msg::CHANNEL_BIND_REQUEST);
    let mut chan_attr = channel.to_be_bytes().to_vec();
    chan_attr.extend_from_slice(&[0, 0]);
    msg.attrs.push((stun_attr::CHANNEL_NUMBER, chan_attr));
    msg.attrs.push((stun_attr::XOR_PEER_ADDRESS, xor_address_value(peer)));
    msg.attrs.push((stun_attr::USERNAME, client.username.clone().into_bytes()));
    msg.attrs.push((stun_attr::REALM, client.realm.clone().into_bytes()));
    msg.attrs.push((stun_attr::NONCE, client.nonce.clone().into_bytes()));
    msg
}

/// Binds one channel per peer address (RFC 5766 section 9; a
/// binding also installs the permission), recording successes in
/// the client. Best-effort per address: on failure traffic
/// keeps using Send indications.
pub fn bind_channels(
    socket: &UdpSocket,
    client: &mut TurnClient,
    peers: &[SocketAddr],
    timeout: Duration,
) {
    let mut next: u16 = 0x4000 + client.bindings.len() as u16;
    while client.channels.contains_key(&next) {
        next += 1;
    }
    for peer in peers {
        let channel = match client.bindings.get(peer) {
            Some(channel) => *channel,
            None => {
                let assigned = next;
                next += 1;
                assigned
            }
        };
        let msg = build_channel_bind(client, channel, peer);
        match turn_request(socket, client.server, &msg, Some(&client.key), timeout) {
            Ok(resp) if resp.msg_type == stun_msg::CHANNEL_BIND_SUCCESS => {
                client.bindings.insert(*peer, channel);
                client.channels.insert(channel, *peer);
            }
            _ => {} // keep Send indications for this peer
        }
    }
}

/// Frames one datagram as ChannelData (RFC 5766 section 11):
/// channel number, length, payload (no padding over UDP).
pub fn wrap_channel_data(channel: u16, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + data.len());
    out.extend_from_slice(&channel.to_be_bytes());
    out.extend_from_slice(&(data.len() as u16).to_be_bytes());
    out.extend_from_slice(data);
    out
}

/// Parses a ChannelData message into (channel, payload),
/// tolerating trailing padding beyond the length field.
pub fn unwrap_channel_data(msg: &[u8]) -> Option<(u16, Vec<u8>)> {
    if msg.len() < 4 {
        return None;
    }
    let length = u16::from_be_bytes(msg[2..4].try_into().ok()?) as usize;
    if 4 + length > msg.len() {
        return None;
    }
    Some((u16::from_be_bytes(msg[0..2].try_into().ok()?), msg[4..4 + length].to_vec()))
}

fn build_refresh(client: &TurnClient) -> Message {
    let mut msg = Message::new(stun_msg::REFRESH_REQUEST);
    msg.attrs.push((stun_attr::LIFETIME, 600u32.to_be_bytes().to_vec()));
    msg.attrs.push((stun_attr::USERNAME, client.username.clone().into_bytes()));
    msg.attrs.push((stun_attr::REALM, client.realm.clone().into_bytes()));
    msg.attrs.push((stun_attr::NONCE, client.nonce.clone().into_bytes()));
    msg
}

/// Background refresher: every refresh interval, re-issues
/// CreatePermission for the known peers and Refresh for the
/// allocation. Send-only (the demux thread consumes responses),
/// best-effort, for the life of the peer — the thread exits
/// after repeated send failures (e.g. socket teardown).
pub fn spawn_refresher(socket: UdpSocket, client: TurnClient, peers: Vec<SocketAddr>) {
    let interval = refresh_interval(&client);
    std::thread::spawn(move || {
        let mut failures = 0;
        loop {
            std::thread::sleep(interval);
            let mut ok = true;
            if let Some(msg) = build_create_permission(&client, &peers) {
                ok = socket.send_to(&msg.encode(Some(&client.key)), client.server).is_ok() && ok;
            }
            for (peer, channel) in &client.bindings {
                let bind = build_channel_bind(&client, *channel, peer);
                ok = socket.send_to(&bind.encode(Some(&client.key)), client.server).is_ok() && ok;
            }
            let refresh = build_refresh(&client);
            ok = socket.send_to(&refresh.encode(Some(&client.key)), client.server).is_ok() && ok;
            failures = if ok { 0 } else { failures + 1 };
            if failures >= 5 {
                return;
            }
        }
    });
}

/// Send pair traffic (ICE checks/responses, DTLS): wrapped in a
/// TURN Send indication when a relay is active — ChannelData
/// framing when a channel is bound for the destination.
pub fn send_pair(
    socket: &UdpSocket,
    turn: Option<&TurnClient>,
    relay_active: bool,
    data: &[u8],
    dest: SocketAddr,
) -> io::Result<()> {
    if let (Some(client), true) = (turn, relay_active) {
        if let Some(channel) = client.bindings.get(&dest) {
            socket.send_to(&wrap_channel_data(*channel, data), client.server)?;
            return Ok(());
        }
        let mut msg = Message::new(stun_msg::SEND_INDICATION);
        msg.attrs.push((stun_attr::XOR_PEER_ADDRESS, xor_address_value(&dest)));
        msg.attrs.push((stun_attr::DATA, data.to_vec()));
        socket.send_to(&msg.encode(None), client.server)?;
        return Ok(());
    }
    socket.send_to(data, dest)?;
    Ok(())
}

/// If `packet` (from `src`) is relayed traffic from the
/// allocation's server (ChannelData frame or Data indication),
/// unwraps it to (payload, peer). Other traffic from the server
/// (control responses past their exchange) is consumed.
pub fn unwrap_incoming(
    turn: Option<&TurnClient>,
    packet: &[u8],
    src: SocketAddr,
) -> Option<(Vec<u8>, SocketAddr)> {
    let Some(client) = turn else {
        return Some((packet.to_vec(), src));
    };
    if src != client.server {
        return Some((packet.to_vec(), src));
    }
    if packet.first().is_some_and(|b| (0x40..=0x7f).contains(b)) {
        let (channel, data) = unwrap_channel_data(packet)?;
        let peer = client.channels.get(&channel)?;
        return Some((data, *peer));
    }
    let msg = Message::decode(packet)?;
    if msg.msg_type != stun_msg::DATA_INDICATION {
        return None; // control traffic: consume
    }
    let peer = decode_xor_address(&msg, stun_attr::XOR_PEER_ADDRESS)?;
    let data = msg.attr(stun_attr::DATA)?.to_vec();
    Some((data, peer))
}
