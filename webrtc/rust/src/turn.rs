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
//!
//! With TurnTransport::Tcp or ::Tls the allocation instead runs
//! over a dedicated stream connection (RFC 5766 section 4;
//! relayed traffic still reaches peers over UDP — REQUESTED-
//! TRANSPORT stays 17): a reader thread frames inbound messages
//! (ChannelData padded to a 4-byte boundary) into the client's
//! inbox, which turn_request, the ICE loop, and the demux
//! thread drain exactly like UDP packets from the server.

use crate::crypto::md5;
use crate::proto_gen::{stun_attr, stun_msg};
use crate::stun::Message;
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream, UdpSocket};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// Client<->server transport for a TURN allocation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum TurnTransport {
    /// Over the peer's own UDP socket (the default).
    #[default]
    Udp,
    /// Dedicated TCP connection.
    Tcp,
    /// Dedicated TLS 1.2 connection (see crate::tls12).
    Tls,
}

/// One TURN server with long-term credentials.
#[derive(Clone, Debug)]
pub struct TurnServerConfig {
    pub address: String,
    pub username: String,
    pub password: String,
    pub transport: TurnTransport,
    /// TLS verification name override (default: the host part of
    /// address). Ignored for non-TLS transports.
    pub server_name: Option<String>,
    /// Skip TLS certificate verification (self-signed
    /// deployments/tests). Ignored for non-TLS transports.
    pub insecure_skip_verify: bool,
    /// PEM root certificates to trust for TLS instead of the
    /// system store (self-signed/private-CA deployments).
    /// Ignored for non-TLS transports.
    pub root_certs_pem: Option<Vec<u8>>,
    /// Ask the server for an IPv6 relayed address
    /// (REQUESTED-ADDRESS-FAMILY, RFC 8656). Default: server's
    /// choice (typically IPv4).
    pub request_ipv6_relay: bool,
}

impl TurnServerConfig {
    pub fn new(address: &str, username: &str, password: &str) -> Self {
        Self {
            address: address.to_string(),
            username: username.to_string(),
            password: password.to_string(),
            transport: TurnTransport::Udp,
            server_name: None,
            insecure_skip_verify: false,
            root_certs_pem: None,
            request_ipv6_relay: false,
        }
    }
}

/// Write half of a stream TURN connection.
#[derive(Clone)]
pub enum StreamWriter {
    Plain(Arc<Mutex<TcpStream>>),
    Tls(Arc<Mutex<crate::tls12::TlsWriteHalf>>),
}

impl std::fmt::Debug for StreamWriter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StreamWriter::Plain(_) => write!(f, "StreamWriter::Plain(..)"),
            StreamWriter::Tls(_) => write!(f, "StreamWriter::Tls(..)"),
        }
    }
}

impl StreamWriter {
    /// Write one TURN message; ChannelData frames are padded to
    /// a 4-byte boundary (RFC 5766 section 4).
    pub fn write_frame(&self, frame: &[u8], channel_data: bool) -> io::Result<()> {
        let mut padded;
        let out: &[u8] = if channel_data && frame.len() % 4 != 0 {
            padded = frame.to_vec();
            padded.resize(frame.len() + (4 - frame.len() % 4), 0);
            &padded
        } else {
            frame
        };
        match self {
            StreamWriter::Plain(stream) => stream.lock().unwrap().write_all(out),
            StreamWriter::Tls(half) => half.lock().unwrap().write_all(out),
        }
    }
}

/// Framed inbound messages from the stream reader thread.
pub type StreamInbox = Arc<(Mutex<VecDeque<Vec<u8>>>, Condvar)>;

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
    /// Dedicated stream connection write half (TCP/TLS only).
    pub stream: Option<StreamWriter>,
    /// Inbound framed messages from the stream reader thread.
    pub inbox: Option<StreamInbox>,
}

impl TurnClient {
    /// Take all currently queued stream messages.
    pub fn drain_inbox(&self) -> Vec<Vec<u8>> {
        match &self.inbox {
            None => Vec::new(),
            Some(inbox) => {
                let (lock, _) = &**inbox;
                lock.lock().unwrap().drain(..).collect()
            }
        }
    }

    /// Pop one stream message, waiting until the deadline.
    fn wait_inbox(&self, deadline: Instant) -> Option<Vec<u8>> {
        let inbox = self.inbox.as_ref()?;
        let (lock, cvar) = &**inbox;
        let mut queue = lock.lock().unwrap();
        loop {
            if let Some(msg) = queue.pop_front() {
                return Some(msg);
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            let (next, _) = cvar.wait_timeout(queue, deadline - now).unwrap();
            queue = next;
        }
    }

    /// Put messages back at the front (turn_request leftovers).
    fn requeue_front(&self, msgs: Vec<Vec<u8>>) {
        if let Some(inbox) = &self.inbox {
            let (lock, cvar) = &**inbox;
            let mut queue = lock.lock().unwrap();
            for msg in msgs.into_iter().rev() {
                queue.push_front(msg);
            }
            cvar.notify_all();
        }
    }
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

/// Encode an XOR-{PEER,RELAYED,MAPPED}-ADDRESS attribute value
/// for a message carrying tid (the IPv6 XOR mask includes the
/// transaction ID).
pub fn xor_address_value(addr: &SocketAddr, tid: &[u8; 12]) -> Vec<u8> {
    crate::stun::xor_mapped_address(addr, tid)
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

/// Read one framed TURN message off a stream (STUN by header
/// length, ChannelData by its length field plus padding).
fn read_framed(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut first = [0u8; 4];
    reader.read_exact(&mut first)?;
    if (0x40..=0x7f).contains(&first[0]) {
        let length = u16::from_be_bytes(first[2..4].try_into().unwrap()) as usize;
        let total = 4 + length;
        let padded = total + (4 - total % 4) % 4;
        let mut rest = vec![0u8; padded - 4];
        reader.read_exact(&mut rest)?;
        let mut msg = first.to_vec();
        msg.extend_from_slice(&rest[..length]);
        Ok(msg)
    } else {
        let mut header = [0u8; 20];
        header[..4].copy_from_slice(&first);
        reader.read_exact(&mut header[4..])?;
        let length = u16::from_be_bytes(header[2..4].try_into().unwrap()) as usize;
        let mut msg = header.to_vec();
        msg.resize(20 + length, 0);
        reader.read_exact(&mut msg[20..])?;
        Ok(msg)
    }
}

/// Stream reader thread: frames inbound messages into the
/// client inbox (capped; oldest dropped past the cap) until
/// the connection closes.
fn spawn_stream_reader(mut reader: Box<dyn Read + Send>, inbox: StreamInbox) {
    std::thread::spawn(move || loop {
        match read_framed(&mut reader) {
            Ok(msg) => {
                let (lock, cvar) = &*inbox;
                let mut queue = lock.lock().unwrap();
                if queue.len() >= 1024 {
                    queue.pop_front();
                }
                queue.push_back(msg);
                cvar.notify_all();
            }
            Err(_) => return,
        }
    });
}

/// Open the dedicated stream connection for a TCP/TLS
/// allocation. Returns the write half, the read half (owned by
/// the reader thread), and a shutdown handle for the raw
/// socket (ends the reader thread on failure paths).
fn connect_stream(
    cfg: &TurnServerConfig,
    server: SocketAddr,
    timeout: Duration,
) -> io::Result<(StreamWriter, Box<dyn Read + Send>, TcpStream)> {
    let stream = TcpStream::connect_timeout(&server, timeout)?;
    let _ = stream.set_nodelay(true);
    let shutdown = stream.try_clone()?;
    match cfg.transport {
        TurnTransport::Tcp => {
            let writer = StreamWriter::Plain(Arc::new(Mutex::new(stream.try_clone()?)));
            Ok((writer, Box::new(stream), shutdown))
        }
        TurnTransport::Tls => {
            let server_name = cfg
                .server_name
                .clone()
                .unwrap_or_else(|| server.ip().to_string());
            let roots = cfg.root_certs_pem.as_ref().map(|pem| {
                let mut store = crate::tls12::RootStore::empty();
                store.add_pem(pem);
                store
            });
            let (read_half, write_half) = crate::tls12::connect_with_roots(
                stream,
                &server_name,
                cfg.insecure_skip_verify,
                roots.as_ref(),
            )
            .map_err(|e| {
                let _ = shutdown.shutdown(Shutdown::Both);
                e
            })?;
            Ok((
                StreamWriter::Tls(Arc::new(Mutex::new(write_half))),
                Box::new(read_half),
                shutdown,
            ))
        }
        TurnTransport::Udp => Err(bad("turn: stream connect for UDP transport")),
    }
}

/// One synchronous TURN control exchange: send, then wait for
/// the response (matched by transaction id) or the deadline.
/// Over UDP this polls the peer socket; over a stream transport
/// it writes to the connection and consumes from the client
/// inbox (non-matching messages are re-queued for the demux).
pub fn turn_request(
    socket: &UdpSocket,
    client: &TurnClient,
    msg: &Message,
    key: Option<&[u8]>,
    timeout: Duration,
) -> io::Result<Message> {
    if let Some(writer) = &client.stream {
        writer.write_frame(&msg.encode(key), false)?;
        let deadline = Instant::now() + timeout;
        let mut leftovers: Vec<Vec<u8>> = Vec::new();
        let result = loop {
            match client.wait_inbox(deadline) {
                Some(raw) => {
                    if let Some(resp) = Message::decode(&raw) {
                        if resp.transaction_id == msg.transaction_id {
                            break Ok(resp);
                        }
                    }
                    leftovers.push(raw);
                }
                None => break Err(bad("turn: timed out waiting for response")),
            }
        };
        client.requeue_front(leftovers);
        return result;
    }
    socket.send_to(&msg.encode(key), client.server)?;
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
        stream: None,
        inbox: None,
    };
    // Stream transports connect first; the reader thread feeds
    // the inbox that turn_request consumes. raw_shutdown closes
    // the connection (and ends the reader) on failure paths.
    let mut raw_shutdown: Option<TcpStream> = None;
    if cfg.transport != TurnTransport::Udp {
        match connect_stream(cfg, server, timeout) {
            Ok((writer, reader, shutdown)) => {
                let inbox: StreamInbox =
                    Arc::new((Mutex::new(VecDeque::new()), Condvar::new()));
                spawn_stream_reader(reader, inbox.clone());
                client.stream = Some(writer);
                client.inbox = Some(inbox);
                raw_shutdown = Some(shutdown);
            }
            Err(e) => return Err(e),
        }
    }
    let shutdown_on_err = |raw: &Option<TcpStream>| {
        if let Some(stream) = raw {
            let _ = stream.shutdown(Shutdown::Both);
        }
    };
    let build = |client: &TurnClient, auth: bool| {
        let mut msg = Message::new(stun_msg::ALLOCATE_REQUEST);
        msg.attrs
            .push((stun_attr::REQUESTED_TRANSPORT, vec![17, 0, 0, 0]));
        if cfg.request_ipv6_relay {
            // REQUESTED-ADDRESS-FAMILY: family 2 (IPv6).
            msg.attrs
                .push((stun_attr::REQUESTED_ADDRESS_FAMILY, vec![2, 0, 0, 0]));
        }
        if auth {
            msg.attrs.push((stun_attr::USERNAME, cfg.username.clone().into_bytes()));
            msg.attrs.push((stun_attr::REALM, client.realm.clone().into_bytes()));
            msg.attrs.push((stun_attr::NONCE, client.nonce.clone().into_bytes()));
        }
        msg
    };

    let mut resp = match turn_request(socket, &client, &build(&client, false), None, timeout) {
        Ok(resp) => resp,
        Err(e) => {
            shutdown_on_err(&raw_shutdown);
            return Err(e);
        }
    };
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
        resp = match turn_request(socket, &client, &build(&client, true), Some(&client.key), timeout) {
            Ok(resp) => resp,
            Err(e) => {
                shutdown_on_err(&raw_shutdown);
                return Err(e);
            }
        };
    }
    if resp.msg_type != stun_msg::ALLOCATE_SUCCESS {
        shutdown_on_err(&raw_shutdown);
        return Err(bad(&format!(
            "turn: allocate failed (type {:#x}, code {})",
            resp.msg_type,
            turn_error_code(&resp)
        )));
    }
    client.relayed = decode_xor_address(&resp, stun_attr::XOR_RELAYED_ADDRESS);
    client.mapped = decode_xor_address(&resp, stun_attr::XOR_MAPPED_ADDRESS);
    if client.relayed.is_none() {
        shutdown_on_err(&raw_shutdown);
        return Err(bad("turn: allocate success without XOR-RELAYED-ADDRESS"));
    }
    client.lifetime = lifetime_of(&resp);
    Ok(client)
}

fn build_create_permission(client: &TurnClient, peers: &[SocketAddr]) -> Option<Message> {
    let mut msg = Message::new(stun_msg::CREATE_PERMISSION_REQUEST);
    let tid = msg.transaction_id;
    let mut seen = std::collections::HashSet::new();
    for cand in peers {
        if !seen.insert(*cand) {
            continue;
        }
        msg.attrs.push((stun_attr::XOR_PEER_ADDRESS, xor_address_value(cand, &tid)));
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
    let _ = turn_request(socket, client, &msg, Some(&client.key), timeout);
}

fn build_channel_bind(client: &TurnClient, channel: u16, peer: &SocketAddr) -> Message {
    let mut msg = Message::new(stun_msg::CHANNEL_BIND_REQUEST);
    let tid = msg.transaction_id;
    let mut chan_attr = channel.to_be_bytes().to_vec();
    chan_attr.extend_from_slice(&[0, 0]);
    msg.attrs.push((stun_attr::CHANNEL_NUMBER, chan_attr));
    msg.attrs.push((stun_attr::XOR_PEER_ADDRESS, xor_address_value(peer, &tid)));
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
        match turn_request(socket, client, &msg, Some(&client.key), timeout) {
            Ok(resp) if resp.msg_type == stun_msg::CHANNEL_BIND_SUCCESS => {
                client.bindings.insert(*peer, channel);
                client.channels.insert(channel, *peer);
            }
            _ => {} // keep Send indications for this peer
        }
    }
}

/// Send-only CreatePermission for one peer trickled in after
/// the connect-time snapshot. The ICE loop owns socket reads
/// then, so this cannot await a response — and a ChannelBind
/// must NOT be issued yet either: inbound traffic would arrive
/// as ChannelData on a channel the loop's client does not know
/// and be dropped. The caller binds channels for trickled
/// peers after nomination via bind_channels; until then
/// Send/Data indications carry their traffic.
pub fn send_permission(socket: &UdpSocket, client: &TurnClient, peer: &SocketAddr) {
    if let Some(msg) = build_create_permission(client, &[*peer]) {
        let _ = send_to_server(socket, client, &msg.encode(Some(&client.key)), false);
    }
}

/// One write to the TURN server: via the stream connection for
/// TCP/TLS allocations, else as a UDP datagram on the socket.
fn send_to_server(
    socket: &dyn crate::peer::DatagramIo,
    client: &TurnClient,
    frame: &[u8],
    channel_data: bool,
) -> io::Result<()> {
    match &client.stream {
        Some(writer) => writer.write_frame(frame, channel_data),
        None => socket.send_to(frame, client.server).map(|_| ()),
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
                ok = send_to_server(&socket, &client, &msg.encode(Some(&client.key)), false).is_ok() && ok;
            }
            for (peer, channel) in &client.bindings {
                let bind = build_channel_bind(&client, *channel, peer);
                ok = send_to_server(&socket, &client, &bind.encode(Some(&client.key)), false).is_ok() && ok;
            }
            let refresh = build_refresh(&client);
            ok = send_to_server(&socket, &client, &refresh.encode(Some(&client.key)), false).is_ok() && ok;
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
#[allow(private_interfaces)]
pub fn send_pair(
    socket: &dyn crate::peer::DatagramIo,
    turn: Option<&TurnClient>,
    relay_active: bool,
    data: &[u8],
    dest: SocketAddr,
) -> io::Result<()> {
    if let (Some(client), true) = (turn, relay_active) {
        if let Some(channel) = client.bindings.get(&dest) {
            send_to_server(socket, client, &wrap_channel_data(*channel, data), true)?;
            return Ok(());
        }
        let mut msg = Message::new(stun_msg::SEND_INDICATION);
        let tid = msg.transaction_id;
        msg.attrs.push((stun_attr::XOR_PEER_ADDRESS, xor_address_value(&dest, &tid)));
        msg.attrs.push((stun_attr::DATA, data.to_vec()));
        send_to_server(socket, client, &msg.encode(None), false)?;
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
