//! libp2p-style WebRTC-Direct: signaling-free client->server
//! connections over DTLS + SCTP datachannels.
//!
//! The listener owns a UDP socket and a self-signed certificate.
//! Its identity is the certificate hash ("certhash": multibase
//! base64url of the sha2-256 multihash of the cert DER), as in
//! libp2p multiaddrs:
//! `/ip4/203.0.113.7/udp/4001/webrtc-direct/certhash/f...`
//!
//! The dialer needs only the address and certhash: it starts a
//! DTLS handshake directly over UDP (no ICE, no SDP exchange —
//! the roles are fixed: dialer is DTLS client, listener is
//! DTLS server), pinned to the certhash. This suits servers
//! with a public address; clients behind NAT (including
//! symmetric NAT, via TURN) are Stage 2 (`direct_dial_turn`).

use crate::dtls::{Dtls, DtlsConfig, DtlsIo, Role};
use crate::endpoint::DcEndpoint;
use crate::io;
use crate::x509::Certificate;
use std::net::{SocketAddr, UdpSocket};
use std::sync::Mutex;
use std::time::Duration;

// ---------------------------------------------------------------------------
// certhash (multibase base64url of multihash sha2-256 of cert DER)
// ---------------------------------------------------------------------------

const B64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn b64url_encode(data: &[u8]) -> String {
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(B64URL[(n >> 18) as usize & 63] as char);
        out.push(B64URL[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(B64URL[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(B64URL[n as usize & 63] as char);
        }
    }
    out
}

fn b64url_decode(s: &str) -> Option<Vec<u8>> {
    let val = |c: u8| -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a') as u32 + 26),
            b'0'..=b'9' => Some((c - b'0') as u32 + 52),
            b'-' => Some(62),
            b'_' => Some(63),
            _ => None,
        }
    };
    let mut out = Vec::new();
    let bytes = s.as_bytes();
    for chunk in bytes.chunks(4) {
        if chunk.len() == 1 {
            return None;
        }
        let mut n: u32 = 0;
        for (i, c) in chunk.iter().enumerate() {
            n |= val(*c)? << (18 - 6 * i);
        }
        out.push((n >> 16) as u8);
        if chunk.len() > 2 {
            out.push((n >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(n as u8);
        }
    }
    Some(out)
}

/// The certhash string for a certificate (multibase 'f' +
/// base64url(0x12 0x20 || sha256(cert DER))).
pub fn certhash_of_cert(cert: &Certificate) -> String {
    let digest = crate::crypto::sha256(&cert.der);
    let mut mh = vec![0x12, 0x20];
    mh.extend_from_slice(&digest);
    format!("f{}", b64url_encode(&mh))
}

/// Parse a certhash into the 32-byte sha256 digest it pins.
pub fn parse_certhash(s: &str) -> Option<[u8; 32]> {
    let encoded = s.strip_prefix('f')?;
    let mh = b64url_decode(encoded)?;
    if mh.len() != 34 || mh[0] != 0x12 || mh[1] != 0x20 {
        return None;
    }
    mh[2..].try_into().ok()
}

/// SDP-style colon-hex fingerprint for a sha256 digest, as
/// `DtlsConfig::expected_peer_fingerprint` expects.
pub fn fingerprint_of_digest(digest: &[u8; 32]) -> String {
    digest
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(":")
}

// ---------------------------------------------------------------------------
// multiaddr (the /webrtc-direct subset)
// ---------------------------------------------------------------------------

/// `/ip4/<a>/udp/<port>/webrtc-direct/certhash/<hash>` (also
/// accepts ip6). Returns the socket address and pinned digest.
pub fn parse_direct_multiaddr(s: &str) -> Option<(SocketAddr, [u8; 32])> {
    let parts: Vec<&str> = s.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() != 7 || parts[2] != "udp" || parts[4] != "webrtc-direct" || parts[5] != "certhash" {
        return None;
    }
    let ip: std::net::IpAddr = match parts[0] {
        "ip4" | "ip6" => parts[1].parse().ok()?,
        _ => return None,
    };
    let port: u16 = parts[3].parse().ok()?;
    let digest = parse_certhash(parts[6])?;
    Some((SocketAddr::new(ip, port), digest))
}

/// The direct multiaddr for a listener address + certhash.
pub fn direct_multiaddr(addr: SocketAddr, certhash: &str) -> String {
    let family = if addr.is_ipv6() { "ip6" } else { "ip4" };
    format!("/{family}/{}/udp/{}/webrtc-direct/certhash/{certhash}", addr.ip(), addr.port())
}

// ---------------------------------------------------------------------------
// listener + dialer
// ---------------------------------------------------------------------------

/// Packet IO that learns its peer from the first packet (the
/// listener accepts whoever handshakes first, like libp2p).
struct DirectIo {
    socket: UdpSocket,
    peer: Mutex<Option<SocketAddr>>,
}

impl DtlsIo for DirectIo {
    fn send_packet(&mut self, packet: &[u8]) -> io::Result<()> {
        let peer = self.peer.lock().unwrap().expect("peer learned");
        self.socket.send_to(packet, peer)?;
        Ok(())
    }

    fn recv_packet(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        self.socket.set_read_timeout(Some(timeout))?;
        let mut buf = vec![0u8; 65536];
        match self.socket.recv_from(&mut buf) {
            Ok((n, addr)) => {
                *self.peer.lock().unwrap() = Some(addr);
                buf.truncate(n);
                Ok(Some(buf))
            }
            Err(ref e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                Ok(None)
            }
            Err(e) => Err(io::Error::new(e.kind(), format!("{e}"))),
        }
    }
}

fn server_config(certificate: Certificate) -> DtlsConfig {
    DtlsConfig {
        certificate,
        expected_peer_fingerprint: None,
        require_peer_certificate: false,
        session_resumption: false,
        session_ticket_key: None,
    }
}

fn client_config(certificate: Certificate, digest: &[u8; 32]) -> DtlsConfig {
    DtlsConfig {
        certificate,
        expected_peer_fingerprint: Some(fingerprint_of_digest(digest)),
        require_peer_certificate: true,
        session_resumption: false,
        session_ticket_key: None,
    }
}

/// A WebRTC-Direct listener: one UDP socket, one certificate,
/// any number of sequential or concurrent dialers (one
/// `accept` per connection; call it in a loop/thread).
pub struct DirectListener {
    socket: UdpSocket,
    certificate: Certificate,
}

impl DirectListener {
    pub fn bind(addr: SocketAddr, certificate: Certificate) -> io::Result<Self> {
        Ok(Self { socket: UdpSocket::bind(addr)?, certificate })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.socket.local_addr().expect("bound socket")
    }

    /// This listener's certhash (its libp2p identity pin).
    pub fn certhash(&self) -> String {
        certhash_of_cert(&self.certificate)
    }

    /// The multiaddr dialers use to reach this listener.
    pub fn multiaddr(&self) -> String {
        direct_multiaddr(self.local_addr(), &self.certhash())
    }

    /// Accept one direct connection (blocking DTLS accept) and
    /// spawn its datachannel endpoint.
    pub fn accept(&self) -> io::Result<DcEndpoint> {
        let io = DirectIo {
            socket: self.socket.try_clone()?,
            peer: Mutex::new(None),
        };
        let dtls = Dtls::accept(io, &server_config(self.certificate.clone()))?;
        Ok(DcEndpoint::spawn(dtls, Role::Server, crate::sctp::SCTP_PORT))
    }
}

/// Dial a WebRTC-Direct listener at `addr`, pinning its
/// certificate to `certhash` (the string form, `f...`).
/// `certificate` is our own DTLS identity (self-signed is
/// fine; generate one when in doubt).
pub fn direct_dial(addr: SocketAddr, certhash: &str, certificate: Certificate) -> io::Result<DcEndpoint> {
    let digest = parse_certhash(certhash)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "bad certhash"))?;
    let socket = UdpSocket::bind(if addr.is_ipv6() {
        SocketAddr::new(std::net::Ipv6Addr::UNSPECIFIED.into(), 0)
    } else {
        SocketAddr::new(std::net::Ipv4Addr::UNSPECIFIED.into(), 0)
    })?;
    let io = crate::dtls::UdpDtlsIo { socket, peer: addr };
    let dtls = Dtls::connect(io, &client_config(certificate, &digest))?;
    Ok(DcEndpoint::spawn(dtls, Role::Client, crate::sctp::SCTP_PORT))
}

/// Packet IO over a TURN allocation: DTLS datagrams are wrapped
/// in Send indications / ChannelData to the listener and
/// unwrapped from Data indications / ChannelData on the way
/// back. This is the symmetric-NAT path: the dialer never sends
/// or receives a direct UDP packet to/from the listener, only
/// to its TURN server, so NAT mapping behavior cannot break it.
struct TurnDtlsIo {
    socket: UdpSocket,
    client: crate::turn::TurnClient,
    remote: SocketAddr,
}

impl DtlsIo for TurnDtlsIo {
    fn send_packet(&mut self, packet: &[u8]) -> io::Result<()> {
        crate::turn::send_pair(&self.socket, Some(&self.client), true, packet, self.remote)
    }

    fn recv_packet(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let now = std::time::Instant::now();
            if now >= deadline {
                return Ok(None);
            }
            self.socket.set_read_timeout(Some(deadline - now))?;
            let mut buf = vec![0u8; 65536];
            match self.socket.recv_from(&mut buf) {
                Ok((n, src)) => {
                    buf.truncate(n);
                    match crate::turn::unwrap_incoming(Some(&self.client), &buf, src) {
                        Some((data, peer)) if peer == self.remote => return Ok(Some(data)),
                        _ => continue, // control traffic or another peer: keep waiting
                    }
                }
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    return Ok(None)
                }
                Err(e) => return Err(io::Error::new(e.kind(), format!("{e}"))),
            }
        }
    }
}

/// Dial a WebRTC-Direct listener through a TURN allocation —
/// the path for a dialer behind a symmetric NAT (or any NAT
/// where direct UDP to the listener fails). `turn_cfg` carries
/// the TURN server + credentials; the allocation, permission
/// and channel binding for `addr` are set up before the DTLS
/// handshake, and a background refresher keeps them alive for
/// the life of the endpoint.
pub fn direct_dial_turn(
    addr: SocketAddr,
    certhash: &str,
    certificate: Certificate,
    turn_cfg: &crate::turn::TurnServerConfig,
) -> io::Result<DcEndpoint> {
    let digest = parse_certhash(certhash)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "bad certhash"))?;
    let timeout = Duration::from_secs(5);
    let socket = UdpSocket::bind(if addr.is_ipv6() {
        SocketAddr::new(std::net::Ipv6Addr::UNSPECIFIED.into(), 0)
    } else {
        SocketAddr::new(std::net::Ipv4Addr::UNSPECIFIED.into(), 0)
    })?;
    let mut client = crate::turn::allocate_turn(&socket, turn_cfg, timeout)?;
    if client.relayed.is_none() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "turn: no relayed address"));
    }
    crate::turn::create_permissions(&socket, &client, &[addr], timeout);
    crate::turn::bind_channels(&socket, &mut client, &[addr], timeout);
    crate::turn::spawn_refresher(socket.try_clone()?, client.clone(), vec![addr]);
    let io = TurnDtlsIo { socket, client, remote: addr };
    let dtls = Dtls::connect(io, &client_config(certificate, &digest))?;
    Ok(DcEndpoint::spawn(dtls, Role::Client, crate::sctp::SCTP_PORT))
}

/// Dial by multiaddr through a TURN allocation (see
/// `direct_dial_turn`).
pub fn direct_dial_turn_multiaddr(
    multiaddr: &str,
    certificate: Certificate,
    turn_cfg: &crate::turn::TurnServerConfig,
) -> io::Result<DcEndpoint> {
    let (addr, digest) = parse_direct_multiaddr(multiaddr)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "bad direct multiaddr"))?;
    let certhash = {
        let mut mh = vec![0x12, 0x20];
        mh.extend_from_slice(&digest);
        format!("f{}", b64url_encode(&mh))
    };
    direct_dial_turn(addr, &certhash, certificate, turn_cfg)
}

/// Dial by multiaddr: `/ip4/.../udp/.../webrtc-direct/certhash/f...`.
pub fn direct_dial_multiaddr(multiaddr: &str, certificate: Certificate) -> io::Result<DcEndpoint> {
    let (addr, digest) = parse_direct_multiaddr(multiaddr)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "bad direct multiaddr"))?;
    let certhash = {
        let mut mh = vec![0x12, 0x20];
        mh.extend_from_slice(&digest);
        format!("f{}", b64url_encode(&mh))
    };
    direct_dial(addr, &certhash, certificate)
}
