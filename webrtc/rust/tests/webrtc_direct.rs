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
}

fn fake_turn_server() -> String {
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
                    let peer = allocs.lock().unwrap().get(&src).and_then(|a| a.channels.get(&chan).copied());
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
                    allocs.lock().unwrap().insert(src, FakeAlloc { relayed, permissions: Default::default(), peer_chan: Default::default(), channels: Default::default() });
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
                                let alloc = st.values().find(|a| a.relayed == relayed);
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
                    resp.attrs.push((stun_attr::LIFETIME, 600u32.to_be_bytes().to_vec()));
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
                    let mut resp = Message::new(stun_msg::REFRESH_SUCCESS);
                    resp.transaction_id = msg.transaction_id;
                    resp.attrs.push((stun_attr::LIFETIME, 600u32.to_be_bytes().to_vec()));
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
