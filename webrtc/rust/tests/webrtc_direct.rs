//! WebRTC-Direct: signaling-free client->server connections.
//! The dialer needs only the listener's address + certhash
//! (its libp2p multiaddr); a wrong certhash must fail the DTLS
//! handshake (certificate pinning).

use dc_webrtc::crypto::md5;
use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::direct::{
    certhash_of_cert, direct_dial, direct_dial_multiaddr, direct_dial_turn_multiaddr,
    fingerprint_of_digest, parse_certhash, parse_direct_multiaddr, DirectListener,
};
use dc_webrtc::endpoint::{ChannelHandle, EndpointEvent};
use dc_webrtc::proto_gen::{stun_attr, stun_msg};
use dc_webrtc::stun::Message;
use dc_webrtc::turn::TurnServerConfig;
use dc_webrtc::x509::Certificate;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn loopback() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)
}

/// Accept one connection, echo on the first channel, return
/// what arrived.
fn echo_server(listener: DirectListener) -> std::thread::JoinHandle<Vec<u8>> {
    std::thread::spawn(move || {
        let endpoint = listener.accept().expect("direct accept");
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        let mut channel: Option<ChannelHandle> = None;
        let mut got = Vec::new();
        while std::time::Instant::now() < deadline {
            match endpoint.recv_event_timeout(Duration::from_millis(200)) {
                Some(EndpointEvent::ChannelOpened { channel: ch }) => {
                    channel = Some(ch);
                }
                Some(EndpointEvent::Message { data, .. }) => {
                    got = data;
                    break;
                }
                _ => {}
            }
        }
        let ch = channel.expect("channel opened");
        ch.send_binary(b"direct-reply").expect("reply");
        endpoint.shutdown();
        got
    })
}

#[test]
fn certhash_and_multiaddr_round_trip() {
    let cert = Certificate::generate_self_signed("listener");
    let hash = certhash_of_cert(&cert);
    assert!(hash.starts_with("fEi"), "sha2-256 multihash prefix: {hash}");
    let digest = parse_certhash(&hash).expect("parse certhash");
    assert_eq!(fingerprint_of_digest(&digest), cert.fingerprint());
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(203, 0, 113, 7)), 4001);
    let ma = dc_webrtc::direct::direct_multiaddr(addr, &hash);
    assert_eq!(
        ma,
        format!("/ip4/203.0.113.7/udp/4001/webrtc-direct/certhash/{hash}")
    );
    let (parsed_addr, parsed_digest) = parse_direct_multiaddr(&ma).expect("parse multiaddr");
    assert_eq!(parsed_addr, addr);
    assert_eq!(parsed_digest, digest);
    assert!(parse_certhash("fAAA").is_none());
    assert!(parse_direct_multiaddr("/ip4/1.2.3.4/tcp/4001/webrtc-direct").is_none());
}

#[test]
fn direct_client_server_echo() {
    let listener = DirectListener::bind(loopback(), Certificate::generate_self_signed("srv"))
        .expect("bind listener");
    let multiaddr = listener.multiaddr();
    let server = echo_server(listener);

    let client = direct_dial_multiaddr(&multiaddr, Certificate::generate_self_signed("cli"))
        .expect("direct dial");
    let channel = client
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .expect("open channel");
    // The server's reply arrives on the same channel.
    channel.send_binary(b"direct-hello").expect("send");
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut reply = None;
    while std::time::Instant::now() < deadline {
        if let Some(EndpointEvent::Message { data, .. }) =
            client.recv_event_timeout(Duration::from_millis(200))
        {
            reply = Some(data);
            break;
        }
    }
    assert_eq!(reply.as_deref(), Some(&b"direct-reply"[..]));
    assert_eq!(server.join().expect("server thread"), b"direct-hello");
    client.shutdown();
}

// ---------------------------------------------------------------------------
// Minimal fake TURN server for the direct-over-TURN path: Allocate
// (401 dance), CreatePermission, ChannelBind, Send/ChannelData to a
// direct (non-TURN) listener, and relay-port arrivals forwarded back
// as Data/ChannelData. This is the symmetric-NAT shape: dialer and
// listener never exchange a direct packet.
// ---------------------------------------------------------------------------

const TURN_USER: &str = "dcuser";
const TURN_PASS: &str = "dcpass";
const TURN_REALM: &str = "dc.test";
const TURN_NONCE: &str = "nonce-42";

fn turn_key() -> Vec<u8> {
    md5(format!("{TURN_USER}:{TURN_REALM}:{TURN_PASS}").as_bytes()).to_vec()
}

#[derive(Clone)]
struct FakeAlloc {
    relayed: SocketAddr,
    permissions: std::collections::HashSet<SocketAddr>,
    peer_chan: HashMap<SocketAddr, u16>,
    channels: HashMap<u16, SocketAddr>,
    expires_at: std::time::Instant,
}

fn fake_turn_server() -> String {
    fake_turn_server_lifetime(600).0
}

fn fake_turn_server_lifetime(lifetime_secs: u32) -> (String, Arc<std::sync::atomic::AtomicU32>) {
    let counter = Arc::new(std::sync::atomic::AtomicU32::new(0));
    let addr = fake_turn_server_impl(lifetime_secs, counter.clone());
    (addr, counter)
}

fn fake_turn_server_impl(lifetime_secs: u32, refresh_counter: Arc<std::sync::atomic::AtomicU32>) -> String {
    let server = Arc::new(UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap());
    let addr = server.local_addr().unwrap();
    let allocs: Arc<Mutex<HashMap<SocketAddr, FakeAlloc>>> = Arc::new(Mutex::new(HashMap::new()));
    let srv = server.clone();
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 65536];
        while let Ok((n, src)) = srv.recv_from(&mut buf) {
            let raw = buf[..n].to_vec();
            if raw.first().is_some_and(|b| (0x40..=0x7f).contains(b)) {
                if let Some((chan, data)) = dc_webrtc::turn::unwrap_channel_data(&raw) {
                    let peer = allocs.lock().unwrap().get(&src)
                        .filter(|a| a.expires_at > std::time::Instant::now())
                        .and_then(|a| a.channels.get(&chan).copied());
                    if let Some(peer) = peer {
                        // Forward via the relay socket so the listener replies to it.
                        if let Some(relay) = relay_socket(&allocs, &src) {
                            let _ = relay.send_to(&data, peer);
                        }
                    }
                }
                continue;
            }
            let Some(msg) = Message::decode(&raw) else { continue };
            let authorized = msg.attr(stun_attr::USERNAME).is_some()
                && msg.check_integrity(&raw, &turn_key());
            match msg.msg_type {
                t if t == stun_msg::ALLOCATE_REQUEST => {
                    if !authorized {
                        let mut resp = Message::new(stun_msg::ALLOCATE_ERROR);
                        resp.transaction_id = msg.transaction_id;
                        resp.attrs.push((stun_attr::ERROR_CODE, vec![0, 0, 4, 1]));
                        resp.attrs.push((stun_attr::REALM, TURN_REALM.as_bytes().to_vec()));
                        resp.attrs.push((stun_attr::NONCE, TURN_NONCE.as_bytes().to_vec()));
                        let _ = srv.send_to(&resp.encode(None), src);
                        continue;
                    }
                    let relay = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
                    let relayed = relay.local_addr().unwrap();
                    allocs.lock().unwrap().insert(src, FakeAlloc { relayed, permissions: Default::default(), peer_chan: Default::default(), channels: Default::default(), expires_at: std::time::Instant::now() + Duration::from_secs(lifetime_secs as u64) });
                    register_relay(relayed, Arc::new(relay));
                    // Relay arrivals -> owner client.
                    let srv2 = srv.clone();
                    let allocs2 = allocs.clone();
                    std::thread::spawn(move || {
                        let relay = relay_socket(&allocs2, &src).expect("relay");
                        let mut b = vec![0u8; 65536];
                        while let Ok((m, from)) = relay.recv_from(&mut b) {
                            let frame = {
                                let st = allocs2.lock().unwrap();
                                let alloc = st.values().find(|a| a.relayed == relayed && a.expires_at > std::time::Instant::now());
                                match alloc {
                                    Some(a) if a.permissions.contains(&from) => {
                                        Some(match a.peer_chan.get(&from) {
                                            Some(ch) => dc_webrtc::turn::wrap_channel_data(*ch, &b[..m]),
                                            None => {
                                                let mut ind = Message::new(stun_msg::DATA_INDICATION);
                                                let tid = ind.transaction_id;
                                                ind.attrs.push((stun_attr::XOR_PEER_ADDRESS, dc_webrtc::turn::xor_address_value(&from, &tid)));
                                                ind.attrs.push((stun_attr::DATA, b[..m].to_vec()));
                                                ind.encode(None)
                                            }
                                        })
                                    }
                                    _ => None,
                                }
                            };
                            if let Some(frame) = frame {
                                let _ = srv2.send_to(&frame, src);
                            }
                        }
                    });
                    let mut resp = Message::new(stun_msg::ALLOCATE_SUCCESS);
                    resp.transaction_id = msg.transaction_id;
                    resp.attrs.push((stun_attr::XOR_RELAYED_ADDRESS, dc_webrtc::turn::xor_address_value(&relayed, &msg.transaction_id)));
                    resp.attrs.push((stun_attr::XOR_MAPPED_ADDRESS, dc_webrtc::stun::xor_mapped_address(&src, &msg.transaction_id)));
                    resp.attrs.push((stun_attr::LIFETIME, lifetime_secs.to_be_bytes().to_vec()));
                    let _ = srv.send_to(&resp.encode(Some(&turn_key())), src);
                }
                t if t == stun_msg::CREATE_PERMISSION_REQUEST => {
                    if !authorized { continue; }
                    {
                        let mut st = allocs.lock().unwrap();
                        if let Some(alloc) = st.get_mut(&src) {
                            for (ty, value) in &msg.attrs {
                                if *ty == stun_attr::XOR_PEER_ADDRESS {
                                    if let Some(peer) = dc_webrtc::stun::decode_xor_mapped(value, &msg.transaction_id) {
                                        alloc.permissions.insert(peer);
                                    }
                                }
                            }
                        }
                    }
                    let mut resp = Message::new(stun_msg::CREATE_PERMISSION_SUCCESS);
                    resp.transaction_id = msg.transaction_id;
                    let _ = srv.send_to(&resp.encode(Some(&turn_key())), src);
                }
                t if t == stun_msg::CHANNEL_BIND_REQUEST => {
                    if !authorized { continue; }
                    let chan = msg.attr(stun_attr::CHANNEL_NUMBER).and_then(|v| if v.len() >= 2 { Some(u16::from_be_bytes(v[..2].try_into().unwrap())) } else { None });
                    let peer = dc_webrtc::turn::decode_xor_address(&msg, stun_attr::XOR_PEER_ADDRESS);
                    if let (Some(chan), Some(peer)) = (chan, peer) {
                        let mut st = allocs.lock().unwrap();
                        if let Some(alloc) = st.get_mut(&src) {
                            alloc.channels.insert(chan, peer);
                            alloc.peer_chan.insert(peer, chan);
                            alloc.permissions.insert(peer);
                        }
                    }
                    let mut resp = Message::new(stun_msg::CHANNEL_BIND_SUCCESS);
                    resp.transaction_id = msg.transaction_id;
                    let _ = srv.send_to(&resp.encode(Some(&turn_key())), src);
                }
                t if t == stun_msg::SEND_INDICATION => {
                    let peer = dc_webrtc::turn::decode_xor_address(&msg, stun_attr::XOR_PEER_ADDRESS);
                    let data = msg.attr(stun_attr::DATA).map(|d| d.to_vec());
                    if let (Some(peer), Some(data)) = (peer, data) {
                        if let Some(relay) = relay_socket(&allocs, &src) {
                            let _ = relay.send_to(&data, peer);
                        }
                    }
                }
                t if t == stun_msg::REFRESH_REQUEST => {
                    refresh_counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    if let Some(alloc) = allocs.lock().unwrap().get_mut(&src) {
                        alloc.expires_at = std::time::Instant::now() + Duration::from_secs(lifetime_secs as u64);
                    }
                    let mut resp = Message::new(stun_msg::REFRESH_SUCCESS);
                    resp.transaction_id = msg.transaction_id;
                    resp.attrs.push((stun_attr::LIFETIME, lifetime_secs.to_be_bytes().to_vec()));
                    let _ = srv.send_to(&resp.encode(Some(&turn_key())), src);
                }
                _ => {}
            }
        }
    });
    addr.to_string()
}

// Relay sockets are kept in a process-wide registry keyed by relayed addr.
static RELAYS: Mutex<Option<HashMap<SocketAddr, Arc<UdpSocket>>>> = Mutex::new(None);
fn register_relay(relayed: SocketAddr, socket: Arc<UdpSocket>) {
    let mut g = RELAYS.lock().unwrap();
    g.get_or_insert_with(HashMap::new).insert(relayed, socket);
}
fn relay_socket(allocs: &Arc<Mutex<HashMap<SocketAddr, FakeAlloc>>>, client: &SocketAddr) -> Option<Arc<UdpSocket>> {
    let relayed = allocs.lock().unwrap().get(client)?.relayed;
    RELAYS.lock().unwrap().as_ref()?.get(&relayed).cloned()
}

#[test]
fn direct_over_turn_echo_symmetric_nat_shape() {
    let turn = fake_turn_server();
    let listener = DirectListener::bind(loopback(), Certificate::generate_self_signed("srv"))
        .expect("bind listener");
    let multiaddr = listener.multiaddr();
    let server = echo_server(listener);
    let cfg = TurnServerConfig::new(&turn, TURN_USER, TURN_PASS);
    let client = direct_dial_turn_multiaddr(&multiaddr, Certificate::generate_self_signed("cli"), &cfg)
        .expect("direct dial over TURN");
    let channel = client
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .expect("open channel");
    channel.send_binary(b"via-turn-direct").expect("send");
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut reply = None;
    while std::time::Instant::now() < deadline {
        if let Some(EndpointEvent::Message { data, .. }) =
            client.recv_event_timeout(Duration::from_millis(200))
        {
            reply = Some(data);
            break;
        }
    }
    assert_eq!(reply.as_deref(), Some(&b"direct-reply"[..]));
    assert_eq!(server.join().expect("server thread"), b"via-turn-direct");
    client.shutdown();
}

/// Real-TURN interop: same symmetric-NAT shape against coturn
/// (skipped when `turnserver` is not on PATH; Dockerfile.ci
/// installs it, so CI always runs this leg).
#[test]
fn direct_over_real_turn_coturn() {
    use std::io::Write as _;
    // turnserver with --listening-port=0 picks an ephemeral port
    // we cannot read back, so spawn_coturn probe-close allocates
    // a port and verifies the child survived startup (retrying
    // on a fresh port when it did not).
    let Some((mut turn, port)) = spawn_coturn(&[
        "--listening-ip=127.0.0.1".to_string(),
        "--relay-ip=127.0.0.1".to_string(),
    ]) else {
        eprintln!("turnserver not on PATH (or failed to start); skipping coturn interop");
        return;
    };
    let result = std::panic::catch_unwind(|| {
        std::thread::sleep(Duration::from_millis(800));
        let listener = DirectListener::bind(loopback(), Certificate::generate_self_signed("srv"))
            .expect("bind listener");
        let multiaddr = listener.multiaddr();
        let server = echo_server(listener);
        let cfg = TurnServerConfig::new(&format!("127.0.0.1:{port}"), TURN_USER, TURN_PASS);
        let mut client = None;
        for _ in 0..10 {
            match direct_dial_turn_multiaddr(&multiaddr, Certificate::generate_self_signed("cli"), &cfg) {
                Ok(ep) => {
                    client = Some(ep);
                    break;
                }
                Err(_) => std::thread::sleep(Duration::from_millis(500)),
            }
        }
        let client = client.expect("direct dial over coturn");
        let channel = client
            .open_channel(dc_webrtc::dcep::ChannelParams { label: "echo".into(), ..Default::default() })
            .expect("open channel");
        channel.send_binary(b"via-coturn").expect("send");
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        let mut reply = None;
        while std::time::Instant::now() < deadline {
            if let Some(EndpointEvent::Message { data, .. }) =
                client.recv_event_timeout(Duration::from_millis(200))
            {
                reply = Some(data);
                break;
            }
        }
        assert_eq!(reply.as_deref(), Some(&b"direct-reply"[..]));
        assert_eq!(server.join().expect("server thread"), b"via-coturn");
        client.shutdown();
        let _ = std::io::stdout().flush();
    });
    let _ = turn.kill();
    result.expect("coturn interop");
}


/// Echo one message on the first channel of an accepted endpoint.
fn echo_one(endpoint: dc_webrtc::endpoint::DcEndpoint) -> Vec<u8> {
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let mut channel: Option<ChannelHandle> = None;
    let mut got = Vec::new();
    while std::time::Instant::now() < deadline {
        match endpoint.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::ChannelOpened { channel: ch }) => channel = Some(ch),
            Some(EndpointEvent::Message { data, .. }) => { got = data; break; }
            _ => {}
        }
    }
    let ch = channel.expect("channel opened");
    ch.send_binary(b"direct-reply").expect("reply");
    endpoint.shutdown();
    got
}

/// Four dialers handshake concurrently against one listener
/// (one accept thread each): every payload must reach its own
/// endpoint, proving the listener demultiplexes by peer address
/// instead of letting endpoints steal each other's packets.
#[test]
fn direct_concurrent_dialers() {
    let listener = Arc::new(
        DirectListener::bind(loopback(), Certificate::generate_self_signed("srv"))
            .expect("bind listener"),
    );
    let multiaddr = listener.multiaddr();
    let mut servers = Vec::new();
    for _ in 0..4 {
        let l = listener.clone();
        servers.push(std::thread::spawn(move || {
            let ep = l.accept().expect("concurrent accept");
            echo_one(ep)
        }));
    }
    let mut clients = Vec::new();
    for i in 0..4 {
        let ma = multiaddr.clone();
        clients.push(std::thread::spawn(move || {
            let client = direct_dial_multiaddr(&ma, Certificate::generate_self_signed("cli"))
                .expect("concurrent dial");
            let channel = client
                .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
                .expect("open channel");
            let payload = format!("hello-{i}");
            channel.send_binary(payload.as_bytes()).expect("send");
            let deadline = std::time::Instant::now() + Duration::from_secs(20);
            let mut reply = None;
            while std::time::Instant::now() < deadline {
                if let Some(EndpointEvent::Message { data, .. }) =
                    client.recv_event_timeout(Duration::from_millis(200))
                {
                    reply = Some(data);
                    break;
                }
            }
            assert_eq!(reply.as_deref(), Some(&b"direct-reply"[..]));
            client.shutdown();
            payload.into_bytes()
        }));
    }
    let mut want: Vec<Vec<u8>> = clients.into_iter().map(|c| c.join().expect("client")).collect();
    let mut got: Vec<Vec<u8>> = servers.into_iter().map(|s| s.join().expect("server")).collect();
    want.sort();
    got.sort();
    assert_eq!(got, want);
}

/// Direct over TURN with a 3 s allocation lifetime enforced by
/// the fake: traffic must still flow after 5 s, which is only
/// possible if the dialer's background refresher re-issues
/// Refresh (and permissions/channel binds) before expiry.
#[test]
fn direct_over_turn_refresh_past_lifetime() {
    let (turn, refreshes) = fake_turn_server_lifetime(3);
    let listener = DirectListener::bind(loopback(), Certificate::generate_self_signed("srv"))
        .expect("bind listener");
    let multiaddr = listener.multiaddr();
    // Server echoes two messages so traffic can be proven both
    // before and after the allocation's original lifetime.
    let server = std::thread::spawn(move || {
        let endpoint = listener.accept().expect("direct accept");
        let deadline = std::time::Instant::now() + Duration::from_secs(30);
        let mut channel: Option<ChannelHandle> = None;
        let mut got = Vec::new();
        while std::time::Instant::now() < deadline && got.len() < 2 {
            match endpoint.recv_event_timeout(Duration::from_millis(200)) {
                Some(EndpointEvent::ChannelOpened { channel: ch }) => channel = Some(ch),
                Some(EndpointEvent::Message { data, .. }) => {
                    got.push(data);
                    channel.as_ref().expect("channel").send_binary(b"direct-reply").expect("reply");
                }
                _ => {}
            }
        }
        endpoint.shutdown();
        got
    });
    let cfg = TurnServerConfig::new(&turn, TURN_USER, TURN_PASS);
    let client = direct_dial_turn_multiaddr(&multiaddr, Certificate::generate_self_signed("cli"), &cfg)
        .expect("direct dial over TURN");
    let channel = client
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .expect("open channel");
    channel.send_binary(b"via-turn-direct").expect("send");
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut reply = None;
    while std::time::Instant::now() < deadline {
        if let Some(EndpointEvent::Message { data, .. }) =
            client.recv_event_timeout(Duration::from_millis(200))
        {
            reply = Some(data);
            break;
        }
    }
    assert_eq!(reply.as_deref(), Some(&b"direct-reply"[..]));

    // Past the 3 s lifetime: the fake drops relayed traffic for
    // expired allocations, so a second echo only works if the
    // dialer's background refresher extended the allocation.
    std::thread::sleep(Duration::from_secs(5));
    channel.send_binary(b"after-expiry").expect("send after expiry");
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut reply2 = None;
    while std::time::Instant::now() < deadline {
        if let Some(EndpointEvent::Message { data, .. }) =
            client.recv_event_timeout(Duration::from_millis(200))
        {
            reply2 = Some(data);
            break;
        }
    }
    assert_eq!(reply2.as_deref(), Some(&b"direct-reply"[..]));
    assert!(
        refreshes.load(std::sync::atomic::Ordering::SeqCst) >= 1,
        "no TURN Refresh issued past the 3s lifetime"
    );
    let got = server.join().expect("server thread");
    assert_eq!(got, vec![b"via-turn-direct".to_vec(), b"after-expiry".to_vec()]);
    client.shutdown();
}

#[test]
fn direct_dial_rejects_wrong_certhash() {
    let listener = DirectListener::bind(loopback(), Certificate::generate_self_signed("srv"))
        .expect("bind listener");
    let addr = listener.local_addr();
    let _server = std::thread::spawn(move || {
        // Accept (and hold) one connection attempt; the client
        // must bail during the handshake, so accept may fail —
        // either outcome is fine here.
        let _ = listener.accept();
    });
    let other = Certificate::generate_self_signed("other");
    let wrong = certhash_of_cert(&other);
    let result = direct_dial(addr, &wrong, Certificate::generate_self_signed("cli"));
    assert!(result.is_err(), "dial with wrong certhash must fail");
}

// ---------------------------------------------------------------------------
// Real-coturn legs: TURNS (TLS client<->server transport) and
// IPv6. Both spawn a private turnserver like
// direct_over_real_turn_coturn and skip when it (or openssl, or
// an IPv6 loopback) is unavailable; Dockerfile.ci provides all.
// ---------------------------------------------------------------------------

// coturn takes a numeric port, so the port is probe-close
// allocated (see free-port note in dtls_openssl.rs): the race
// is covered by verifying the child survived startup and
// retrying on a fresh port when it did not (e.g. the probed
// port was taken before coturn bound it).
fn spawn_coturn(extra: &[String]) -> Option<(std::process::Child, u16)> {
    for _ in 0..3 {
        let probe = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).ok()?;
        let port = probe.local_addr().ok()?.port();
        drop(probe);
        let mut args: Vec<String> = vec![
            "-n".into(),
            format!("--listening-port={port}"),
            "--realm=dc.test".into(),
            "--user=dcuser:dcpass".into(),
            "--lt-cred-mech".into(),
            "--allow-loopback-peers".into(),
            "--no-cli".into(),
        ];
        args.extend(extra.iter().cloned());
        let mut child = std::process::Command::new("turnserver")
            .args(&args)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .ok()?;
        std::thread::sleep(Duration::from_millis(800));
        match child.try_wait() {
            Ok(None) => return Some((child, port)),
            _ => continue,
        }
    }
    None
}


fn spawn_coturn_turns(cert: &std::path::Path, key: &std::path::Path) -> Option<(std::process::Child, u16)> {
    // Probe-close port + startup-liveness retry, as spawn_coturn.
    for _ in 0..3 {
        let probe = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).ok()?;
        let tls_port = probe.local_addr().ok()?.port();
        drop(probe);
        let mut child = std::process::Command::new("turnserver")
            .args([
                "-n".to_string(),
                "--listening-ip=127.0.0.1".to_string(),
                "--relay-ip=127.0.0.1".to_string(),
                format!("--tls-listening-port={tls_port}"),
                format!("--cert={}", cert.display()),
                format!("--pkey={}", key.display()),
                "--realm=dc.test".to_string(),
                "--user=dcuser:dcpass".to_string(),
                "--lt-cred-mech".to_string(),
                "--allow-loopback-peers".to_string(),
                "--no-cli".to_string(),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .ok()?;
        std::thread::sleep(Duration::from_millis(800));
        match child.try_wait() {
            Ok(None) => return Some((child, tls_port)),
            _ => continue,
        }
    }
    None
}

fn echo_round_trip(client: &dc_webrtc::endpoint::DcEndpoint, payload: &[u8]) {
    let channel = client
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .expect("open channel");
    channel.send_binary(payload).expect("send");
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut reply = None;
    while std::time::Instant::now() < deadline {
        if let Some(EndpointEvent::Message { data, .. }) =
            client.recv_event_timeout(Duration::from_millis(200))
        {
            reply = Some(data);
            break;
        }
    }
    assert_eq!(reply.as_deref(), Some(&b"direct-reply"[..]));
}

#[test]
fn direct_over_turns_coturn() {
    // Self-signed cert for coturn's TLS listener.
    let dir = std::env::temp_dir().join(format!("dc-turns-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let cert = dir.join("cert.pem");
    let key = dir.join("key.pem");
    let made = std::process::Command::new("openssl")
        .args([
            // RSA cert: the common TURNS case. The homegrown TLS
        // client must offer ECDHE-RSA + rsa_pkcs1 signature
        // algorithms and verify the RSA ServerKeyExchange
        // signature (verified below via root_certs_pem, not
        // insecure_skip_verify).
        "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", key.to_str().unwrap(), "-out", cert.to_str().unwrap(),
            "-days", "1", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost",
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !made {
        eprintln!("openssl unavailable; skipping TURNS coturn leg");
        return;
    }
    let Some((mut turn, port)) = spawn_coturn_turns(&cert, &key) else {
        eprintln!("turnserver not on PATH; skipping TURNS coturn leg");
        return;
    };
    let result = std::panic::catch_unwind(|| {
        let listener = DirectListener::bind(loopback(), Certificate::generate_self_signed("srv"))
            .expect("bind listener");
        let multiaddr = listener.multiaddr();
        let server = echo_server(listener);
        let mut cfg = TurnServerConfig::new(&format!("127.0.0.1:{port}"), TURN_USER, TURN_PASS);
        cfg.transport = dc_webrtc::turn::TurnTransport::Tls;
        cfg.server_name = Some("localhost".to_string());
        cfg.root_certs_pem = Some(std::fs::read(&cert).expect("read coturn cert"));
        let mut client = None;
        for _ in 0..10 {
            match direct_dial_turn_multiaddr(&multiaddr, Certificate::generate_self_signed("cli"), &cfg) {
                Ok(ep) => { client = Some(ep); break; }
                Err(e) => { eprintln!("TURNS dial retry: {e}"); std::thread::sleep(Duration::from_millis(500)) },
            }
        }
        let client = client.expect("direct dial over TURNS");
        echo_round_trip(&client, b"via-turns");
        assert_eq!(server.join().expect("server thread"), b"via-turns");
        client.shutdown();
    });
    let _ = turn.kill();
    result.expect("TURNS coturn interop");
}

#[test]
fn direct_over_turn_ipv6_coturn() {
    if UdpSocket::bind((std::net::Ipv6Addr::LOCALHOST, 0)).is_err() {
        eprintln!("no IPv6 loopback; skipping IPv6 coturn leg");
        return;
    }
    let Some((mut turn, port)) = spawn_coturn(&[
        "--listening-ip=::1".into(),
        "--relay-ip=::1".into(),
    ]) else {
        eprintln!("turnserver not on PATH; skipping IPv6 coturn leg");
        return;
    };
    let result = std::panic::catch_unwind(|| {
        let v6_loopback = SocketAddr::new(IpAddr::V6(std::net::Ipv6Addr::LOCALHOST), 0);
        let listener = DirectListener::bind(v6_loopback, Certificate::generate_self_signed("srv"))
            .expect("bind v6 listener");
        let multiaddr = listener.multiaddr();
        assert!(multiaddr.starts_with("/ip6/::1/udp/"), "{multiaddr}");
        let server = echo_server(listener);
        let mut cfg = TurnServerConfig::new(&format!("[::1]:{port}"), TURN_USER, TURN_PASS);
        cfg.request_ipv6_relay = true;
        let mut client = None;
        for _ in 0..10 {
            match direct_dial_turn_multiaddr(&multiaddr, Certificate::generate_self_signed("cli"), &cfg) {
                Ok(ep) => { client = Some(ep); break; }
                Err(e) => { eprintln!("IPv6 TURN dial retry: {e}"); std::thread::sleep(Duration::from_millis(500)) },
            }
        }
        let client = client.expect("direct dial over IPv6 TURN");
        echo_round_trip(&client, b"via-ipv6-turn");
        assert_eq!(server.join().expect("server thread"), b"via-ipv6-turn");
        client.shutdown();
    });
    let _ = turn.kill();
    result.expect("IPv6 coturn interop");
}

#[test]
fn direct_ipv6_echo() {
    let v6_loopback = SocketAddr::new(IpAddr::V6(std::net::Ipv6Addr::LOCALHOST), 0);
    let Ok(listener) = DirectListener::bind(v6_loopback, Certificate::generate_self_signed("srv"))
    else {
        eprintln!("no IPv6 loopback; skipping direct IPv6 echo");
        return;
    };
    let multiaddr = listener.multiaddr();
    assert!(multiaddr.starts_with("/ip6/::1/udp/"), "{multiaddr}");
    let server = echo_server(listener);
    let client = direct_dial_multiaddr(&multiaddr, Certificate::generate_self_signed("cli"))
        .expect("direct v6 dial");
    echo_round_trip(&client, b"direct-v6");
    assert_eq!(server.join().expect("server thread"), b"direct-v6");
    client.shutdown();
}
