//! TURN relay (RFC 5766) ICE candidates: a fake TURN server on
//! loopback runs the Allocate 401 dance; peers must learn relay
//! candidates, advertise them with type preference 0, and connect
//! through the relay (the host address advertised in the e2e is
//! deliberately unreachable, so a working connection proves the
//! relayed pair carried ICE + DTLS + data).

use dc_webrtc::crypto::md5;
use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::proto_gen::{stun_attr, stun_msg};
use dc_webrtc::stun::Message;
use dc_webrtc::turn::TurnServerConfig;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Fake TURN server (fixture): Allocate with long-term credential
// auth, CreatePermission, Send/Data-indication relaying between
// allocations, plus direct delivery to relayed ports.
// ---------------------------------------------------------------------------

const REALM: &str = "dc.test";
const NONCE: &str = "nonce-42";
const USER: &str = "dcuser";
const PASS: &str = "dcpass";

fn turn_key() -> Vec<u8> {
    md5(format!("{USER}:{REALM}:{PASS}").as_bytes()).to_vec()
}

#[derive(Clone)]
struct FakeAlloc {
    client: SocketAddr,
    relayed: SocketAddr,
    permissions: HashMap<SocketAddr, Instant>, // peer -> expiry
    expires_at: Instant,
    channels: HashMap<u16, SocketAddr>,
    peer_chan: HashMap<SocketAddr, u16>,
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
struct FakeState {
    by_client: HashMap<SocketAddr, FakeAlloc>,
    by_relay: HashMap<SocketAddr, FakeAlloc>,
    next_port: u16,
    lifetime_secs: u32,
    permission_secs: u64,
    refresh_count: usize,
    perm_count: usize,
    bind_count: usize,
    chan_data: usize,
}

impl FakeState {
    fn lifetime_attr(&self) -> Vec<u8> {
        self.lifetime_secs.to_be_bytes().to_vec()
    }
}

fn authorized(msg: &Message, raw: &[u8]) -> bool {
    msg.attr(stun_attr::USERNAME).map(|u| String::from_utf8_lossy(u).into_owned())
        == Some(USER.to_string())
        && msg.check_integrity(raw, &turn_key())
}

fn fake_turn_server() -> String {
    fake_turn_server_with(600, 300).0
}

/// Fake whose allocations live lifetime_secs and permissions
/// permission_secs, both enforced. Returns the server address
/// and the shared state (for refresh counters).
fn fake_turn_server6() -> String {
    fake_turn_server_impl(600, 300, true).0
}

fn fake_turn_server_with(lifetime_secs: u32, permission_secs: u64) -> (String, Arc<Mutex<FakeState>>) {
    fake_turn_server_impl(lifetime_secs, permission_secs, false)
}

fn fake_turn_server_impl(lifetime_secs: u32, permission_secs: u64, v6: bool) -> (String, Arc<Mutex<FakeState>>) {
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
fn deliver(
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

fn on_channel_data(
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
    }
}

/// Direct arrivals at a relayed port (from non-TURN senders) are
/// forwarded to the allocation owner as Data indications when the
/// owner holds a permission for the sender.
fn listen_relay(server: Arc<UdpSocket>, state: Arc<Mutex<FakeState>>, relayed: SocketAddr) {
    let Ok(socket) = UdpSocket::bind(relayed) else { return };
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

fn turn_peer6(server: &str) -> Peer {
    let mut cfg = TurnServerConfig::new(server, USER, PASS);
    cfg.request_ipv6_relay = true;
    Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: vec![cfg],
    })
    .unwrap()
}

fn turn_peer(server: &str) -> Peer {
    Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::new(10, 11, 12, 13))],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: vec![TurnServerConfig::new(server, USER, PASS)],
    })
    .unwrap()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn allocate_gathers_relay_candidate() {
    let server = fake_turn_server();
    let mut peer = Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: Vec::new(),
    })
    .unwrap();
    let cfg = TurnServerConfig::new(&server, USER, PASS);
    assert!(peer.allocate_turn(&cfg, Duration::from_secs(2)).unwrap());
    let offer = peer.create_offer();
    let line = offer
        .lines()
        .find(|l| l.contains("typ relay"))
        .unwrap_or_else(|| panic!("no relay candidate in offer:\n{offer}"));
    assert!(
        line.contains("typ relay raddr 127.0.0.1 rport "),
        "relay line: {line}"
    );
    let priority: u32 = line.split_whitespace().nth(3).unwrap().parse().unwrap();
    assert_eq!(priority >> 24, 0, "relay priority type bits");
}

#[test]
fn allocate_gathers_ipv6_relay_candidate() {
    let server = fake_turn_server6();
    let mut peer = turn_peer6(&server);
    let offer = peer.create_offer();
    let line = offer
        .lines()
        .find(|l| l.contains("typ relay"))
        .unwrap_or_else(|| panic!("no relay candidate in offer:\n{offer}"));
    assert!(
        line.contains("::1") || line.contains("raddr ::1"),
        "IPv6 relay line: {line}"
    );
}

#[test]
fn peers_connect_over_turn_relay_ipv6() {
    let server = fake_turn_server6();
    let mut offerer = turn_peer6(&server);
    let mut answerer = turn_peer6(&server);

    let offer = offerer.create_offer();
    assert!(offer.contains("typ relay"), "offer:\n{offer}");
    let answer = answerer.handle_offer(&offer).unwrap();
    assert!(answer.contains("typ relay"), "answer:\n{answer}");
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"via-relay-v6").unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while std::time::Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"via-relay-v6");
            received = true;
        }
    }
    assert!(received, "no message arrived over the IPv6 TURN-relayed peers");
}

#[test]
fn allocate_bad_password_adds_no_candidate() {
    let server = fake_turn_server();
    let mut peer = Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: None,
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: vec![TurnServerConfig::new(&server, USER, "wrong")],
    })
    .unwrap();
    let offer = peer.create_offer();
    assert!(!offer.contains("typ relay"), "unexpected relay candidate:\n{offer}");
}

#[test]
fn peers_connect_over_turn_relay() {
    let server = fake_turn_server();
    let mut offerer = turn_peer(&server);
    let mut answerer = turn_peer(&server);

    let offer = offerer.create_offer();
    assert!(offer.contains("typ relay"), "offer:\n{offer}");
    let answer = answerer.handle_offer(&offer).unwrap();
    assert!(answer.contains("typ relay"), "answer:\n{answer}");
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"via-relay").unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while std::time::Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"via-relay");
            received = true;
        }
    }
    assert!(received, "no message arrived over the TURN-relayed peers");
}

// With a 3 s allocation/permission lifetime enforced by the fake,
// the relayed channel must still work after 5 s — only possible
// if both peers refresh their allocations and permissions.
#[test]
fn refresh_keeps_relay_alive() {
    let (server, state) = fake_turn_server_with(3, 3);
    let mut offerer = turn_peer(&server);
    let mut answerer = turn_peer(&server);

    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"before-expiry").unwrap();

    fn await_message(ep: &dc_webrtc::endpoint::DcEndpoint, want: &[u8]) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if let Some(EndpointEvent::Message { data, .. }) =
                ep.recv_event_timeout(Duration::from_millis(200))
            {
                assert_eq!(data, want);
                return;
            }
        }
        panic!("message {want:?} never arrived over the relay");
    }
    await_message(&answerer_ep, b"before-expiry");

    // Both allocations and all permissions would have expired by
    // now without refresh.
    std::thread::sleep(Duration::from_secs(5));
    channel.send_binary(b"after-expiry").unwrap();
    await_message(&answerer_ep, b"after-expiry");

    let st = state.lock().unwrap();
    assert!(st.refresh_count >= 2, "refreshes={}", st.refresh_count);
    assert!(st.perm_count >= 4, "permissions={}", st.perm_count);
}

#[test]
fn channel_bind_carries_traffic() {
    let (server, state) = fake_turn_server_with(600, 300);
    let mut offerer = turn_peer(&server);
    let mut answerer = turn_peer(&server);

    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();

    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"via-channel").unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"via-channel");
            received = true;
        }
    }
    assert!(received, "no message arrived over the channel-bound relay");
    let st = state.lock().unwrap();
    assert!(st.bind_count >= 2, "binds={}", st.bind_count);
    assert!(st.chan_data > 0, "no ChannelData relayed");
}

// Candidates trickled in after the connect-time snapshot must
// still get TURN permissions and channel bindings. The only
// reachable candidate on each side is the relay candidate,
// withheld from the SDP and trickled over the connect_trickled
// channel while ICE runs; the fake enforces permissions, so
// the message only flows if trickle created them.
#[test]
fn relay_with_trickled_relay_candidates() {
    let (server, state) = fake_turn_server_with(600, 300);
    let mut offerer = turn_peer(&server);
    let mut answerer = turn_peer(&server);

    fn relay_line_of(sdp: &str) -> String {
        sdp.lines()
            .find(|line| line.contains("typ relay"))
            .expect("no relay candidate")
            .to_string()
    }
    fn strip_relay(sdp: &str) -> String {
        sdp.lines()
            .filter(|line| !line.contains("typ relay"))
            .collect::<Vec<_>>()
            .join("\r\n")
            + "\r\n"
    }

    let offer = offerer.create_offer();
    let offer_relay = relay_line_of(&offer);
    let answer = answerer.handle_offer(&strip_relay(&offer)).unwrap();
    let answer_relay = relay_line_of(&answer);
    offerer.handle_answer(&strip_relay(&answer)).unwrap();

    let (offerer_tx, offerer_rx) = std::sync::mpsc::channel::<String>();
    let (answerer_tx, answerer_rx) = std::sync::mpsc::channel::<String>();
    let offerer_thread = std::thread::spawn(move || offerer.connect_trickled(offerer_rx));
    let answerer_thread = std::thread::spawn(move || answerer.connect_trickled(answerer_rx));

    // Trickle only after both connects have snapshotted the
    // SDP-carried candidates.
    std::thread::sleep(Duration::from_millis(250));
    answerer_tx.send(offer_relay).unwrap();
    offerer_tx.send(answer_relay).unwrap();
    drop(offerer_tx);
    drop(answerer_tx);

    let offerer_ep = offerer_thread.join().unwrap().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"trickled-relay").unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"trickled-relay");
            received = true;
        }
    }
    assert!(received, "no message arrived over the trickled relay");
    let st = state.lock().unwrap();
    assert!(st.perm_count >= 2, "permissions={}", st.perm_count);
    assert!(st.bind_count >= 2, "binds={}", st.bind_count);
}
