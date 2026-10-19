//! TURN over TCP/TLS (RFC 5766 section 4): the allocation
//! runs over a dedicated stream connection while relayed
//! traffic still reaches peers over UDP. TCP is tested against
//! a compact in-Rust stream fake; TLS against the JS stream
//! fake (node:tls, tests/fixtures cert) run standalone — the
//! hand-rolled TLS 1.2 client interoperating with OpenSSL.

use dc_webrtc::crypto::md5;
use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::proto_gen::{stun_attr, stun_msg};
use dc_webrtc::stun::Message;
use dc_webrtc::turn::{
    decode_xor_address, wrap_channel_data, xor_address_value, TurnServerConfig,
    TurnTransport,
};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const REALM: &str = "dc.test";
const NONCE: &str = "nonce-42";
const USER: &str = "dcuser";
const PASS: &str = "dcpass";

fn turn_key() -> Vec<u8> {
    md5(format!("{USER}:{REALM}:{PASS}").as_bytes()).to_vec()
}

// ---------------------------------------------------------------------------
// Compact stream fake TURN server
// ---------------------------------------------------------------------------

struct StreamAlloc {
    writer: TcpStream,
    relayed: Option<SocketAddr>,
    permissions: std::collections::HashSet<SocketAddr>,
    channels: HashMap<u16, SocketAddr>,
    peer_chan: HashMap<SocketAddr, u16>,
}

struct FakeStreamTurn {
    allocs: HashMap<SocketAddr, Arc<Mutex<StreamAlloc>>>, // by relayed addr
    next_port: u16,
    perm_count: usize,
    bind_count: usize,
    chan_data: usize,
}

fn pad4(frame: &mut Vec<u8>) {
    while frame.len() % 4 != 0 {
        frame.push(0);
    }
}

fn write_frame(alloc: &Arc<Mutex<StreamAlloc>>, frame: &[u8], channel_data: bool) {
    let mut alloc = alloc.lock().unwrap();
    let mut out = frame.to_vec();
    if channel_data {
        pad4(&mut out);
    }
    let _ = alloc.writer.write_all(&out);
}

fn read_framed(reader: &mut impl Read) -> std::io::Result<Vec<u8>> {
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

fn authorized(msg: &Message, raw: &[u8]) -> bool {
    msg.attr(stun_attr::USERNAME).map(|v| String::from_utf8_lossy(v).into_owned())
        == Some(USER.to_string())
        && msg.check_integrity(raw, &turn_key())
}

fn respond(alloc: &Arc<Mutex<StreamAlloc>>, req: &Message, ty: u16, key: Option<&[u8]>, attrs: Vec<(u16, Vec<u8>)>) {
    let mut resp = Message::new(ty);
    resp.transaction_id = req.transaction_id;
    resp.attrs = attrs;
    write_frame(alloc, &resp.encode(key), false);
}

fn deliver(state: &Arc<Mutex<FakeStreamTurn>>, sender: &Arc<Mutex<StreamAlloc>>, dest_relayed: SocketAddr, data: &[u8]) -> bool {
    let (dest, channel) = {
        let state = state.lock().unwrap();
        let sender_relayed = sender.lock().unwrap().relayed;
        let Some(dest) = state.allocs.get(&dest_relayed).cloned() else { return false };
        let Some(sender_relayed) = sender_relayed else { return false };
        let channel = {
            let dest_guard = dest.lock().unwrap();
            if !dest_guard.permissions.contains(&sender_relayed) {
                return false;
            }
            dest_guard.peer_chan.get(&sender_relayed).copied()
        };
        (dest, channel)
    };
    let sender_relayed = sender.lock().unwrap().relayed.unwrap();
    match channel {
        Some(channel) => write_frame(&dest, &wrap_channel_data(channel, data), true),
        None => {
            let mut ind = Message::new(stun_msg::DATA_INDICATION);
            let tid = ind.transaction_id;
            ind.attrs.push((stun_attr::XOR_PEER_ADDRESS, xor_address_value(&sender_relayed, &tid)));
            ind.attrs.push((stun_attr::DATA, data.to_vec()));
            write_frame(&dest, &ind.encode(None), false);
        }
    }
    true
}

fn serve_conn(mut stream: TcpStream, state: Arc<Mutex<FakeStreamTurn>>) {
    let alloc = Arc::new(Mutex::new(StreamAlloc {
        writer: stream.try_clone().unwrap(),
        relayed: None,
        permissions: Default::default(),
        channels: HashMap::new(),
        peer_chan: HashMap::new(),
    }));
    loop {
        let Ok(raw) = read_framed(&mut stream) else { return };
        if raw.len() >= 4 && (0x40..=0x7f).contains(&raw[0]) {
            let channel = u16::from_be_bytes(raw[0..2].try_into().unwrap());
            let length = u16::from_be_bytes(raw[2..4].try_into().unwrap()) as usize;
            let dest = alloc.lock().unwrap().channels.get(&channel).copied();
            if let Some(dest) = dest {
                if deliver(&state, &alloc, dest, &raw[4..4 + length.min(raw.len() - 4)]) {
                    state.lock().unwrap().chan_data += 1;
                }
            }
            continue;
        }
        let Some(msg) = Message::decode(&raw) else { continue };
        match msg.msg_type {
            t if t == stun_msg::ALLOCATE_REQUEST => {
                if msg.attr(stun_attr::USERNAME).is_none() || !authorized(&msg, &raw) {
                    respond(&alloc, &msg, stun_msg::ALLOCATE_ERROR, None, vec![
                        (stun_attr::ERROR_CODE, vec![0, 0, 4, 1]),
                        (stun_attr::REALM, REALM.as_bytes().to_vec()),
                        (stun_attr::NONCE, NONCE.as_bytes().to_vec()),
                    ]);
                    continue;
                }
                let relayed = {
                    let mut state = state.lock().unwrap();
                    state.next_port += 1;
                    let relayed = SocketAddr::from((Ipv4Addr::LOCALHOST, state.next_port));
                    state.allocs.insert(relayed, alloc.clone());
                    relayed
                };
                alloc.lock().unwrap().relayed = Some(relayed);
                let mapped = stream.peer_addr().unwrap();
                let tid = msg.transaction_id;
                let mut resp = Message::new(stun_msg::ALLOCATE_SUCCESS);
                resp.transaction_id = tid;
                let key = turn_key();
                // XOR uses the RESPONSE transaction id (same tid here).
                resp.attrs.push((stun_attr::XOR_RELAYED_ADDRESS, xor_address_value(&relayed, &tid)));
                resp.attrs.push((stun_attr::XOR_MAPPED_ADDRESS, xor_address_value(&mapped, &tid)));
                resp.attrs.push((stun_attr::LIFETIME, vec![0, 0, 2, 88]));
                write_frame(&alloc, &resp.encode(Some(&key)), false);
            }
            t if t == stun_msg::REFRESH_REQUEST => {
                if authorized(&msg, &raw) {
                    respond(&alloc, &msg, stun_msg::REFRESH_SUCCESS, Some(&turn_key()), vec![
                        (stun_attr::LIFETIME, vec![0, 0, 2, 88]),
                    ]);
                }
            }
            t if t == stun_msg::CREATE_PERMISSION_REQUEST => {
                if !authorized(&msg, &raw) {
                    continue;
                }
                {
                    let mut alloc = alloc.lock().unwrap();
                    for (ty, value) in &msg.attrs {
                        if *ty == stun_attr::XOR_PEER_ADDRESS {
                            if let Some(peer) = dc_webrtc::stun::decode_xor_mapped(value, &msg.transaction_id) {
                                alloc.permissions.insert(peer);
                            }
                        }
                    }
                }
                state.lock().unwrap().perm_count += 1;
                respond(&alloc, &msg, stun_msg::CREATE_PERMISSION_SUCCESS, Some(&turn_key()), vec![]);
            }
            t if t == stun_msg::CHANNEL_BIND_REQUEST => {
                if !authorized(&msg, &raw) {
                    continue;
                }
                let Some(chan_value) = msg.attr(stun_attr::CHANNEL_NUMBER) else { continue };
                let Some(peer) = decode_xor_address(&msg, stun_attr::XOR_PEER_ADDRESS) else { continue };
                if chan_value.len() < 2 {
                    continue;
                }
                let channel = u16::from_be_bytes(chan_value[..2].try_into().unwrap());
                {
                    let mut alloc = alloc.lock().unwrap();
                    alloc.channels.insert(channel, peer);
                    alloc.peer_chan.insert(peer, channel);
                    alloc.permissions.insert(peer);
                }
                state.lock().unwrap().bind_count += 1;
                respond(&alloc, &msg, stun_msg::CHANNEL_BIND_SUCCESS, Some(&turn_key()), vec![]);
            }
            t if t == stun_msg::SEND_INDICATION => {
                if let (Some(peer), Some(data)) =
                    (decode_xor_address(&msg, stun_attr::XOR_PEER_ADDRESS), msg.attr(stun_attr::DATA))
                {
                    let data = data.to_vec();
                    deliver(&state, &alloc, peer, &data);
                }
            }
            _ => {}
        }
    }
}

fn fake_turn_tcp() -> (SocketAddr, Arc<Mutex<FakeStreamTurn>>) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let addr = listener.local_addr().unwrap();
    let state = Arc::new(Mutex::new(FakeStreamTurn {
        allocs: HashMap::new(),
        next_port: 51100,
        perm_count: 0,
        bind_count: 0,
        chan_data: 0,
    }));
    let accept_state = state.clone();
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            match conn {
                Ok(stream) => {
                    let st = accept_state.clone();
                    std::thread::spawn(move || serve_conn(stream, st));
                }
                Err(_) => return,
            }
        }
    });
    (addr, state)
}

// ---------------------------------------------------------------------------
// Connect helper (shared by TCP + TLS legs)
// ---------------------------------------------------------------------------

fn stream_peer(server: &str, transport: TurnTransport, insecure: bool, server_name: Option<&str>) -> Peer {
    stream_peer_with_roots(server, transport, insecure, server_name, None)
}

fn stream_peer_with_roots(
    server: &str,
    transport: TurnTransport,
    insecure: bool,
    server_name: Option<&str>,
    roots: Option<Vec<u8>>,
) -> Peer {
    let mut cfg = TurnServerConfig::new(server, USER, PASS);
    cfg.transport = transport;
    cfg.insecure_skip_verify = insecure;
    cfg.server_name = server_name.map(|s| s.to_string());
    cfg.root_certs_pem = roots;
    Peer::new(PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::new(10, 11, 12, 13))],
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

fn connect_and_echo(offerer: Peer, answerer: Peer) {
    let mut offerer = offerer;
    let mut answerer = answerer;
    let offer = offerer.create_offer();
    assert!(offer.contains("typ relay"), "offer lacks relay candidate:\n{offer}");
    let answer = answerer.handle_offer(&offer).unwrap();
    assert!(answer.contains("typ relay"), "answer lacks relay candidate:\n{answer}");
    offerer.handle_answer(&answer).unwrap();
    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let channel = offerer_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    channel.send_binary(b"via-stream-relay").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut received = false;
    while Instant::now() < deadline && !received {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"via-stream-relay");
            received = true;
        }
    }
    assert!(received, "no message arrived over the stream TURN relay");
}

#[test]
fn turn_tcp_relay_connect() {
    let (addr, state) = fake_turn_tcp();
    let server = addr.to_string();
    connect_and_echo(
        stream_peer(&server, TurnTransport::Tcp, false, None),
        stream_peer(&server, TurnTransport::Tcp, false, None),
    );
    let state = state.lock().unwrap();
    assert!(state.perm_count >= 2, "permissions={}", state.perm_count);
    assert!(state.bind_count >= 2, "binds={}", state.bind_count);
    assert!(state.chan_data > 0, "no ChannelData relayed over the stream");
}

#[test]
fn turn_tcp_bad_password_fails() {
    let (addr, _state) = fake_turn_tcp();
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
    let mut cfg = TurnServerConfig::new(&addr.to_string(), USER, "wrong");
    cfg.transport = TurnTransport::Tcp;
    let result = peer.allocate_turn(&cfg, Duration::from_secs(2));
    assert!(
        matches!(result, Err(_) | Ok(false)),
        "bad-password allocate should fail, got {result:?}"
    );
}

// ---------------------------------------------------------------------------
// TLS leg against the Node fake (OpenSSL), standalone mode
// ---------------------------------------------------------------------------

struct NodeFake {
    child: Child,
    addr: String,
}

impl Drop for NodeFake {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn spawn_node_fake(mode: &str) -> Option<NodeFake> {
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../js/test/fake_turn_stream.js");
    let mut child = Command::new("node")
        .args([script, mode])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let addr = line.trim().strip_prefix("READY ")?.to_string();
    std::thread::spawn(move || loop {
        let mut sink = String::new();
        if reader.read_line(&mut sink).unwrap_or(0) == 0 {
            return;
        }
    });
    Some(NodeFake { child, addr })
}

#[test]
fn turn_tls_relay_connect_insecure() {
    let Some(fake) = spawn_node_fake("tls") else {
        eprintln!("skipping: node not available");
        return;
    };
    connect_and_echo(
        stream_peer(&fake.addr, TurnTransport::Tls, true, None),
        stream_peer(&fake.addr, TurnTransport::Tls, true, None),
    );
}

fn fixture_cert_pem() -> Vec<u8> {
    std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../js/test/fixtures/turn_tls_cert.pem"
    ))
    .unwrap()
}

#[test]
fn turn_tls_p384_relay_connect_verified() {
    // Live handshake against a P-384-certificate OpenSSL
    // server, with chain verification against an explicit root.
    let Some(fake) = spawn_node_fake("tls384") else {
        eprintln!("skipping: node not available");
        return;
    };
    let root = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../js/test/fixtures/turn_tls384_cert.pem"
    ))
    .unwrap();
    connect_and_echo(
        stream_peer_with_roots(&fake.addr, TurnTransport::Tls, false, Some("localhost"), Some(root.clone())),
        stream_peer_with_roots(&fake.addr, TurnTransport::Tls, false, Some("localhost"), Some(root)),
    );
}

#[test]
fn turn_tls_relay_connect_verified() {
    // Root trust + SAN verification on: the fixture cert is
    // self-signed with SAN DNS:localhost, trusted here by
    // handing it to the client as an explicit root.
    let Some(fake) = spawn_node_fake("tls") else {
        eprintln!("skipping: node not available");
        return;
    };
    connect_and_echo(
        stream_peer_with_roots(
            &fake.addr,
            TurnTransport::Tls,
            false,
            Some("localhost"),
            Some(fixture_cert_pem()),
        ),
        stream_peer_with_roots(
            &fake.addr,
            TurnTransport::Tls,
            false,
            Some("localhost"),
            Some(fixture_cert_pem()),
        ),
    );
}

#[test]
fn turn_tls_untrusted_root_rejected() {
    // Same fixture cert and correct name, but no trusted root:
    // the self-signed chain must not verify.
    let Some(fake) = spawn_node_fake("tls") else {
        eprintln!("skipping: node not available");
        return;
    };
    let mut peer = stream_peer(&fake.addr, TurnTransport::Tls, false, Some("localhost"));
    let offer = peer.create_offer();
    assert!(!offer.contains("typ relay"), "relay candidate despite untrusted root:\n{offer}");
}

#[test]
fn turn_tls_wrong_name_rejected() {
    let Some(fake) = spawn_node_fake("tls") else {
        eprintln!("skipping: node not available");
        return;
    };
    let mut peer = stream_peer(&fake.addr, TurnTransport::Tls, false, Some("wrong.example"));
    let offer = peer.create_offer();
    assert!(!offer.contains("typ relay"), "relay candidate despite bad cert name:\n{offer}");
}
