//! Shared fake TURN server fixture (RFC 5766): Allocate
//! with long-term credential auth, CreatePermission,
//! ChannelBind, Send/Data-indication relaying between
//! allocations, plus direct delivery to relayed ports.
//! Used by the TURN tests and the rendezvous TURN tests.
#![allow(dead_code)]

use dc_webrtc::crypto::md5;
use dc_webrtc::proto_gen::{stun_attr, stun_msg};
use dc_webrtc::stun::Message;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const REALM: &str = "dc.test";
pub const NONCE: &str = "nonce-42";
pub const USER: &str = "dcuser";
pub const PASS: &str = "dcpass";

pub fn turn_key() -> Vec<u8> {
    md5(format!("{USER}:{REALM}:{PASS}").as_bytes()).to_vec()
}

#[derive(Clone)]
pub struct FakeAlloc {
pub     client: SocketAddr,
pub     relayed: SocketAddr,
pub     permissions: HashMap<SocketAddr, Instant>, // peer -> expiry
pub     expires_at: Instant,
pub     channels: HashMap<u16, SocketAddr>,
pub     peer_chan: HashMap<SocketAddr, u16>,
}

impl FakeAlloc {
    fn live(&self) -> bool {
        Instant::now() < self.expires_at
    }
    fn perm_ok(&self, peer: &SocketAddr) -> bool {
        self.permissions.get(peer).is_some_and(|exp| Instant::now() < *exp)
    }
}

#[derive(Default)]
pub struct FakeState {
pub     by_client: HashMap<SocketAddr, FakeAlloc>,
pub     by_relay: HashMap<SocketAddr, FakeAlloc>,
pub     next_port: u16,
pub     lifetime_secs: u32,
pub     permission_secs: u64,
pub     refresh_count: usize,
pub     perm_count: usize,
pub     bind_count: usize,
pub     chan_data: usize,
    pub alloc_count: usize,
    pub send_count: usize,
    pub relay_sockets: HashMap<SocketAddr, Arc<UdpSocket>>,
    pub direct_count: usize,
}

impl FakeState {
    fn lifetime_attr(&self) -> Vec<u8> {
        self.lifetime_secs.to_be_bytes().to_vec()
    }
}

pub fn authorized(msg: &Message, raw: &[u8]) -> bool {
    msg.attr(stun_attr::USERNAME).map(|u| String::from_utf8_lossy(u).into_owned())
        == Some(USER.to_string())
        && msg.check_integrity(raw, &turn_key())
}

pub fn fake_turn_server() -> String {
    fake_turn_server_with(600, 300).0
}

/// Fake whose allocations live lifetime_secs and permissions
/// permission_secs, both enforced. Returns the server address
/// and the shared state (for refresh counters).
pub fn fake_turn_server6() -> String {
    fake_turn_server_impl(600, 300, true).0
}

pub fn fake_turn_server_with(lifetime_secs: u32, permission_secs: u64) -> (String, Arc<Mutex<FakeState>>) {
    fake_turn_server_impl(lifetime_secs, permission_secs, false)
}

pub fn fake_turn_server_impl(lifetime_secs: u32, permission_secs: u64, v6: bool) -> (String, Arc<Mutex<FakeState>>) {
    let socket = Arc::new(if v6 {
        UdpSocket::bind((std::net::Ipv6Addr::LOCALHOST, 0)).unwrap()
    } else {
        UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap()
    });
    let addr = socket.local_addr().unwrap();
    let state = Arc::new(Mutex::new(FakeState {
        next_port: 52100,
        lifetime_secs,
        permission_secs,
        ..Default::default()
    }));
    let state_out = state.clone();
    let server = socket.clone();
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 65536];
        while let Ok((n, src)) = server.recv_from(&mut buf) {
            let raw = buf[..n].to_vec();
            if raw.first().is_some_and(|b| (0x40..=0x7f).contains(b)) {
                on_channel_data(&server, &state, &raw, src);
                continue;
            }
            let Some(msg) = Message::decode(&raw) else { continue };
            match msg.msg_type {
                t if t == stun_msg::ALLOCATE_REQUEST => {
                    if msg.attr(stun_attr::USERNAME).is_none() || !authorized(&msg, &raw) {
                        let mut resp = Message::new(stun_msg::ALLOCATE_ERROR);
                        resp.transaction_id = msg.transaction_id;
                        resp.attrs.push((stun_attr::ERROR_CODE, vec![0, 0, 4, 1]));
                        resp.attrs.push((stun_attr::REALM, REALM.as_bytes().to_vec()));
                        resp.attrs.push((stun_attr::NONCE, NONCE.as_bytes().to_vec()));
                        let _ = server.send_to(&resp.encode(None), src);
                        continue;
                    }
                    let relayed = {
                        let mut st = state.lock().unwrap();
                        st.next_port += 1;
                        // Honor REQUESTED-ADDRESS-FAMILY (IPv6)
                        // when the client asks for it.
                        let wants_v6 = msg
                            .attr(stun_attr::REQUESTED_ADDRESS_FAMILY)
                            .is_some_and(|v| v.first() == Some(&2));
                        if v6 || wants_v6 {
                            SocketAddr::new(IpAddr::V6(std::net::Ipv6Addr::LOCALHOST), st.next_port)
                        } else {
                            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), st.next_port)
                        }
                    };
                    let alloc = FakeAlloc {
                        client: src,
                        relayed,
                        permissions: HashMap::new(),
                        expires_at: Instant::now()
                            + Duration::from_secs(state.lock().unwrap().lifetime_secs as u64),
                        channels: HashMap::new(),
                        peer_chan: HashMap::new(),
                    };
                    {
                        let mut st = state.lock().unwrap();
                        st.alloc_count += 1;
                        st.by_client.insert(src, alloc.clone());
                        st.by_relay.insert(relayed, alloc);
                    }
                    listen_relay(server.clone(), state.clone(), relayed);
                    let mut resp = Message::new(stun_msg::ALLOCATE_SUCCESS);
                    resp.transaction_id = msg.transaction_id;
                    resp.attrs.push((
                        stun_attr::XOR_RELAYED_ADDRESS,
                        dc_webrtc::turn::xor_address_value(&relayed, &msg.transaction_id),
                    ));
                    resp.attrs.push((
                        stun_attr::XOR_MAPPED_ADDRESS,
                        dc_webrtc::stun::xor_mapped_address(&src, &msg.transaction_id),
                    ));
                    resp.attrs.push((
                        stun_attr::LIFETIME,
                        state.lock().unwrap().lifetime_attr(),
                    ));
                    let _ = server.send_to(&resp.encode(Some(&turn_key())), src);
                }
                t if t == stun_msg::REFRESH_REQUEST => {
                    if !authorized(&msg, &raw) {
                        continue;
                    }
                    let ok = {
                        let mut st = state.lock().unwrap();
                        let live_alloc =
                            st.by_client.get(&src).is_some_and(|alloc| alloc.live());
                        if live_alloc {
                            let expiry = Instant::now()
                                + Duration::from_secs(st.lifetime_secs as u64);
                            if let Some(alloc) = st.by_client.get_mut(&src) {
                                alloc.expires_at = expiry;
                            }
                            let relayed = st.by_client.get(&src).map(|alloc| alloc.relayed);
                            if let Some(relayed) = relayed {
                                if let Some(copy) = st.by_relay.get_mut(&relayed) {
                                    copy.expires_at = expiry;
                                }
                            }
                            st.refresh_count += 1;
                        }
                        live_alloc
                    };
                    if ok {
                        let mut resp = Message::new(stun_msg::REFRESH_SUCCESS);
                        resp.transaction_id = msg.transaction_id;
                        resp.attrs.push((
                            stun_attr::LIFETIME,
                            state.lock().unwrap().lifetime_attr(),
                        ));
                        let _ = server.send_to(&resp.encode(Some(&turn_key())), src);
                    } else {
                        let mut resp = Message::new(stun_msg::REFRESH_ERROR);
                        resp.transaction_id = msg.transaction_id;
                        resp.attrs.push((stun_attr::ERROR_CODE, vec![0, 0, 4, 37])); // 437
                        let _ = server.send_to(&resp.encode(Some(&turn_key())), src);
                    }
                }
                t if t == stun_msg::CHANNEL_BIND_REQUEST => {
                    if !authorized(&msg, &raw) {
                        continue;
                    }
                    let chan_value = msg.attr(stun_attr::CHANNEL_NUMBER);
                    let peer = dc_webrtc::turn::decode_xor_address(&msg, stun_attr::XOR_PEER_ADDRESS);
                    let (Some(value), Some(peer)) = (chan_value, peer) else { continue };
                    if value.len() < 2 {
                        continue;
                    }
                    let channel = u16::from_be_bytes(value[..2].try_into().unwrap());
                    {
                        let mut st = state.lock().unwrap();
                        let expiry = Instant::now() + Duration::from_secs(st.permission_secs);
                        let mut updated = None;
                        if let Some(alloc) = st.by_client.get_mut(&src) {
                            if alloc.live() {
                                alloc.channels.insert(channel, peer);
                                alloc.peer_chan.insert(peer, channel);
                                alloc.permissions.insert(peer, expiry);
                                updated = Some(alloc.clone());
                            }
                        }
                        if let Some(alloc) = updated {
                            if let Some(copy) = st.by_relay.get_mut(&alloc.relayed) {
                                copy.channels.insert(channel, peer);
                                copy.peer_chan.insert(peer, channel);
                                copy.permissions.insert(peer, expiry);
                            }
                            st.bind_count += 1;
                        }
                    }
                    let mut resp = Message::new(stun_msg::CHANNEL_BIND_SUCCESS);
                    resp.transaction_id = msg.transaction_id;
                    let _ = server.send_to(&resp.encode(Some(&turn_key())), src);
                }
                t if t == stun_msg::CREATE_PERMISSION_REQUEST => {
                    if !authorized(&msg, &raw) {
                        continue;
                    }
                    {
                        let mut st = state.lock().unwrap();
                        st.perm_count += 1;
                        let expiry =
                            Instant::now() + Duration::from_secs(st.permission_secs);
                        let mut granted: Vec<SocketAddr> = Vec::new();
                        for (ty, value) in &msg.attrs {
                            if *ty != stun_attr::XOR_PEER_ADDRESS {
                                continue;
                            }
                            if let Some(peer) =
                                dc_webrtc::stun::decode_xor_mapped(value, &msg.transaction_id)
                            {
                                granted.push(peer);
                            }
                        }
                        let mut updated: Option<FakeAlloc> = None;
                        if let Some(alloc) = st.by_client.get_mut(&src) {
                            for peer in granted {
                                alloc.permissions.insert(peer, expiry);
                            }
                            updated = Some(alloc.clone());
                        }
                        // Keep the by_relay copy in sync.
                        if let Some(alloc) = updated {
                            if let Some(relay_copy) = st.by_relay.get_mut(&alloc.relayed) {
                                relay_copy.permissions.clone_from(&alloc.permissions);
                            }
                        }
                    }
                    let mut resp = Message::new(stun_msg::CREATE_PERMISSION_SUCCESS);
                    resp.transaction_id = msg.transaction_id;
                    let _ = server.send_to(&resp.encode(Some(&turn_key())), src);
                }
                t if t == stun_msg::SEND_INDICATION => {
                    state.lock().unwrap().send_count += 1;
                    let Some(peer) = dc_webrtc::turn::decode_xor_address(&msg, stun_attr::XOR_PEER_ADDRESS)
                    else { continue };
                    let Some(data) = msg.attr(stun_attr::DATA).map(|d| d.to_vec()) else { continue };
                    let allowed = {
                        let st = state.lock().unwrap();
                        let sender = st.by_client.get(&src);
                        let dest = st.by_relay.get(&peer);
                        matches!(
                            (sender, dest),
                            (Some(sender), Some(dest))
                                if sender.live() && dest.live() && dest.perm_ok(&sender.relayed)
                        )
                    };
                    if allowed {
                        deliver(&server, &state, &peer, src, &data);
                    } else {
                        deliver_direct(&state, &peer, src, &data);
                    }
                }
                _ => {}
            }
        }
    });
    (addr.to_string(), state_out)
}

/// Deliver a relayed payload to the allocation owning
/// `dest_relayed`, from the TURN client at `sender_client`:
/// ChannelData when the destination bound a channel to the
/// sender's relayed address, else a Data indication.
pub fn deliver(
    server: &Arc<UdpSocket>,
    state: &Arc<Mutex<FakeState>>,
    dest_relayed: &SocketAddr,
    sender_client: SocketAddr,
    data: &[u8],
) {
    let framed_or_client = {
        let st = state.lock().unwrap();
        let sender = st.by_client.get(&sender_client);
        let dest = st.by_relay.get(dest_relayed);
        match (sender, dest) {
            (Some(sender), Some(dest)) => Some((
                dest.client,
                sender.relayed,
                dest.peer_chan.get(&sender.relayed).copied(),
            )),
            _ => None,
        }
    };
    let Some((client, sender_relayed, channel)) = framed_or_client else { return };
    match channel {
        Some(channel) => {
            let _ = server.send_to(&dc_webrtc::turn::wrap_channel_data(channel, data), client);
        }
        None => {
            let mut ind = Message::new(stun_msg::DATA_INDICATION);
            let tid = ind.transaction_id;
            ind.attrs.push((
                stun_attr::XOR_PEER_ADDRESS,
                dc_webrtc::turn::xor_address_value(&sender_relayed, &tid),
            ));
            ind.attrs.push((stun_attr::DATA, data.to_vec()));
            let _ = server.send_to(&ind.encode(None), client);
        }
    }
}

/// Forward a relayed payload to a peer that owns no
/// allocation (a plain UDP endpoint), the way a real TURN
/// server does: out of the sender's relayed socket, gated on
/// the sender holding a permission for the destination.
/// Returns true when forwarded.
pub fn deliver_direct(
    state: &Arc<Mutex<FakeState>>,
    dest: &SocketAddr,
    sender_client: SocketAddr,
    data: &[u8],
) -> bool {
    let socket = {
        let mut st = state.lock().unwrap();
        let relayed = st
            .by_client
            .get(&sender_client)
            .filter(|s| s.live() && s.perm_ok(dest))
            .map(|s| s.relayed);
        let allowed = relayed.is_some() && !st.by_relay.contains_key(dest);
        if !allowed {
            return false;
        }
        st.direct_count += 1;
        relayed.and_then(|r| st.relay_sockets.get(&r).cloned())
    };
    match socket {
        Some(socket) => socket.send_to(data, dest).is_ok(),
        None => false,
    }
}

pub fn on_channel_data(
    server: &Arc<UdpSocket>,
    state: &Arc<Mutex<FakeState>>,
    raw: &[u8],
    src: SocketAddr,
) {
    let Some((channel, data)) = dc_webrtc::turn::unwrap_channel_data(raw) else { return };
    let dest_relayed = {
        let mut st = state.lock().unwrap();
        let allowed = {
            let sender = st.by_client.get(&src);
            let peer = sender.and_then(|s| s.channels.get(&channel).copied());
            match (sender, peer) {
                (Some(sender), Some(peer)) => {
                    let dest = st.by_relay.get(&peer);
                    matches!(dest, Some(dest) if sender.live() && dest.live() && dest.perm_ok(&sender.relayed))
                        .then_some(peer)
                }
                _ => None,
            }
        };
        if allowed.is_some() {
            st.chan_data += 1;
        }
        allowed
    };
    if let Some(peer) = dest_relayed {
        deliver(server, state, &peer, src, &data);
    } else {
        // Channel target with no allocation: direct delivery
        // to the plain endpoint, as a real TURN server does.
        let peer = {
            let st = state.lock().unwrap();
            st.by_client
                .get(&src)
                .and_then(|s| s.channels.get(&channel).copied())
        };
        if let Some(peer) = peer {
            deliver_direct(state, &peer, src, &data);
        }
    }
}

/// Direct arrivals at a relayed port (from non-TURN senders) are
/// forwarded to the allocation owner as Data indications when the
/// owner holds a permission for the sender.
pub fn listen_relay(server: Arc<UdpSocket>, state: Arc<Mutex<FakeState>>, relayed: SocketAddr) {
    let Ok(socket) = UdpSocket::bind(relayed) else { return };
    let socket = Arc::new(socket);
    state
        .lock()
        .unwrap()
        .relay_sockets
        .insert(relayed, socket.clone());
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 65536];
        while let Ok((n, src)) = socket.recv_from(&mut buf) {
            let client = {
                let st = state.lock().unwrap();
                match st.by_relay.get(&relayed) {
                    Some(alloc) if alloc.live() && alloc.perm_ok(&src) => Some(alloc.client),
                    _ => None,
                }
            };
            if let Some(client) = client {
                let framed = {
                    let st = state.lock().unwrap();
                    st.by_relay
                        .get(&relayed)
                        .and_then(|alloc| alloc.peer_chan.get(&src).copied())
                        .map(|channel| dc_webrtc::turn::wrap_channel_data(channel, &buf[..n]))
                };
                match framed {
                    Some(frame) => {
                        let _ = server.send_to(&frame, client);
                    }
                    None => {
                        let mut ind = Message::new(stun_msg::DATA_INDICATION);
                        let tid = ind.transaction_id;
                        ind.attrs.push((
                            stun_attr::XOR_PEER_ADDRESS,
                            dc_webrtc::turn::xor_address_value(&src, &tid),
                        ));
                        ind.attrs.push((stun_attr::DATA, buf[..n].to_vec()));
                        let _ = server.send_to(&ind.encode(None), client);
                    }
                }
            }
        }
    });
}

