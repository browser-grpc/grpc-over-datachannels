//! Shared-socket multiplexing for signaled peers: many `Peer`s
//! (RTCPeerConnection equivalents) over one bound UDP socket —
//! the single-port server topology (Jitsi's 10000/udp, Pion's
//! UDPMux). One reader thread owns the real socket and routes
//! each datagram to one peer endpoint:
//!
//! - STUN packets route by the ICE username's local ufrag
//!   (registered when the peer is created; after an ICE restart
//!   changes our ufrag, the learned source-address route below
//!   keeps inbound checks flowing).
//! - A Binding Success carries no username, so it is offered
//!   to every endpoint; each agent consumes only its own
//!   (integrity-checked) transaction.
//! - DTLS routes by connection id (RFC 9146): an epoch-0
//!   ClientHello routes by its DcPairHint extension (the
//!   remote peer's ICE ufrag); every later record routes by
//!   the connection id after its header (offset 11), looked
//!   up exactly. The learned source is the fallback for peers
//!   that ignore the extension (e.g. browsers).
//! - Unauthenticated STUN probes (srflx gathering has no
//!   username in the response) route to endpoints currently
//!   marked probing via begin_probe/end_probe.
//!
//! Because DTLS records route by connection id, two muxes can
//! peer with each other over one shared source address, and
//! NAT rebinding does not strand records. All mux peers
//! advertise the shared socket's port as their host-candidate
//! port, which reduces the firewall story to a single opened
//! port. TURN traffic never touches the shared socket: a
//! muxed peer's allocation rides a dedicated per-peer socket
//! (see `Peer::turn_socket`). IPv6 works when the mux socket
//! is bound to an IPv6 address and peers advertise IPv6
//! candidates.

use crate::peer::{DatagramIo, Peer, PeerConfig};
use crate::proto_gen::stun_attr;
use std::collections::HashMap;
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

/// One shared UDP socket hosting many signaled peers.
pub struct PeerMux {
    inner: Arc<MuxInner>,
}

struct MuxInner {
    socket: Arc<UdpSocket>,
    addr: SocketAddr,
    by_ufrag: Mutex<HashMap<String, Weak<MuxEndpoint>>>,
    by_src: Mutex<HashMap<SocketAddr, Weak<MuxEndpoint>>>,
    by_cid: Mutex<HashMap<Vec<u8>, Weak<MuxEndpoint>>>,
    probes: Mutex<Vec<Weak<MuxEndpoint>>>,
    next_cid: std::sync::atomic::AtomicU64,
}

/// One peer's view of the shared socket: sends go straight to
/// the real socket; receives drain the per-endpoint inbox the
/// mux reader fills. Implements the peer's `DatagramIo` seam.
pub(crate) struct MuxEndpoint {
    inner: Arc<MuxInner>,
    tx: Sender<(Vec<u8>, SocketAddr)>,
    rx: Mutex<Receiver<(Vec<u8>, SocketAddr)>>,
    timeout: Mutex<Option<Duration>>,
    me: Mutex<Option<Weak<MuxEndpoint>>>,
    cid: Vec<u8>,
}

impl MuxInner {
    fn endpoint(&self, ufrag: &str) -> Option<Arc<MuxEndpoint>> {
        let mut map = self.by_ufrag.lock().unwrap();
        match map.get(ufrag).and_then(Weak::upgrade) {
            Some(ep) => Some(ep),
            None => {
                map.remove(ufrag);
                None
            }
        }
    }

    fn endpoint_at(&self, src: SocketAddr) -> Option<Arc<MuxEndpoint>> {
        let mut map = self.by_src.lock().unwrap();
        match map.get(&src).and_then(Weak::upgrade) {
            Some(ep) => Some(ep),
            None => {
                map.remove(&src);
                None
            }
        }
    }

    /// Route an epoch-1 DTLS record by the connection id at
    /// offset 11 (after type/version/epoch/sequence).
    fn endpoint_by_cid(&self, data: &[u8]) -> Option<Arc<MuxEndpoint>> {
        if data.len() < 14 || !(20..64).contains(&data[0]) {
            return None;
        }
        let mut map = self.by_cid.lock().unwrap();
        let hit = map.iter().find_map(|(cid, ep)| {
            if data[11..].starts_with(cid) {
                ep.upgrade().map(|e| (cid.clone(), e))
            } else {
                None
            }
        });
        match hit {
            Some((cid, ep)) => {
                let _ = cid;
                Some(ep)
            }
            None => {
                map.retain(|_, ep| ep.upgrade().is_some());
                None
            }
        }
    }

    /// Route an epoch-0 ClientHello by its DcPairHint
    /// extension (the remote peer's ICE ufrag, which our
    /// by_ufrag table already keys).
    fn endpoint_by_hint(&self, data: &[u8]) -> Option<Arc<MuxEndpoint>> {
        let hint = pair_hint_from_client_hello(data)?;
        self.endpoint(&hint)
    }

    fn deliver(&self, data: Vec<u8>, src: SocketAddr) {
        // STUN (first byte 0..4 in the peer stacks' convention):
        // route by username ufrag, then (Binding Success, which
        // has no username) offer to every endpoint, then by
        // learned source, then to srflx probes.
        let target = if !data.is_empty() && data[0] < 4 {
            let decoded = crate::stun::Message::decode(&data);
            let by_name = decoded.as_ref().and_then(|msg| {
                let username = msg.attr(stun_attr::USERNAME)?;
                let text = std::str::from_utf8(username).ok()?;
                let local = text.split(':').next()?;
                self.endpoint(local)
            });
            // A Binding Success carries no username. Offer it
            // to every endpoint: each agent consumes only its
            // own (integrity-checked) transaction, and a shared
            // source (mux-to-mux) makes the learned source
            // ambiguous.
            if by_name.is_none()
                && decoded
                    .as_ref()
                    .is_some_and(|m| m.msg_type == crate::proto_gen::stun_msg::BINDING_SUCCESS)
            {
                let endpoints: Vec<Arc<MuxEndpoint>> = self
                    .by_ufrag
                    .lock()
                    .unwrap()
                    .values()
                    .filter_map(Weak::upgrade)
                    .collect();
                for ep in endpoints {
                    ep.enqueue(data.clone(), src);
                }
                return;
            }
            let target = by_name.or_else(|| self.endpoint_at(src));
            match target {
                Some(ep) => {
                    self.by_src.lock().unwrap().insert(src, Arc::downgrade(&ep));
                    Some(ep)
                }
                None => {
                    let probes = self.probes.lock().unwrap();
                    for ep in probes.iter().filter_map(Weak::upgrade) {
                        ep.enqueue(data.clone(), src);
                    }
                    return;
                }
            }
        } else {
            // DTLS: an epoch-1 record carrying a registered
            // connection id routes by cid (source-independent,
            // so mux-to-mux and NAT rebinding keep working);
            // an epoch-0 ClientHello routes by its DcPairHint;
            // anything else falls back to the learned source.
            let by = self.endpoint_by_hint(&data);
            by.or_else(|| self.endpoint_by_cid(&data))
                .or_else(|| self.endpoint_at(src))
        };
        if let Some(ep) = target {
            ep.enqueue(data, src);
        }
    }
}

impl MuxEndpoint {
    fn enqueue(&self, data: Vec<u8>, src: SocketAddr) {
        let _ = self.tx.send((data, src));
    }
}

impl DatagramIo for MuxEndpoint {
    fn send_to(&self, buf: &[u8], dest: SocketAddr) -> io::Result<usize> {
        self.inner.socket.send_to(buf, dest)
    }

    fn recv_from(&self, buf: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
        let timeout = *self.timeout.lock().unwrap();
        let rx = self.rx.lock().unwrap();
        let received = match timeout {
            Some(dur) => match rx.recv_timeout(dur) {
                Ok(v) => Ok(v),
                Err(RecvTimeoutError::Timeout) => {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "mux recv timeout"));
                }
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(io::Error::new(io::ErrorKind::BrokenPipe, "mux closed"));
                }
            },
            None => rx
                .recv()
                .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "mux closed")),
        };
        let (data, src) = received?;
        // Oversized datagrams truncate, like a real socket.
        let n = data.len().min(buf.len());
        buf[..n].copy_from_slice(&data[..n]);
        Ok((n, src))
    }

    fn set_read_timeout(&self, dur: Option<Duration>) -> io::Result<()> {
        *self.timeout.lock().unwrap() = dur;
        Ok(())
    }

    fn local_cid(&self) -> Option<Vec<u8>> {
        Some(self.cid.clone())
    }

    fn begin_probe(&self) {
        let me = self.me.lock().unwrap().clone();
        if let Some(me) = me {
            let ptr = Weak::as_ptr(&me);
            let mut probes = self.inner.probes.lock().unwrap();
            probes.retain(|w| w.upgrade().is_some() && Weak::as_ptr(w) != ptr);
            probes.push(me);
        }
    }

    fn end_probe(&self) {
        let me = self.me.lock().unwrap().clone();
        if let Some(me) = me {
            let ptr = Weak::as_ptr(&me);
            self.inner
                .probes
                .lock()
                .unwrap()
                .retain(|w| Weak::as_ptr(w) != ptr);
        }
    }
}

/// Extract the DcPairHint (remote ICE ufrag) from an epoch-0
/// ClientHello datagram, when present. Layout: record header
/// (13) | handshake header (12) | version(2) random(32)
/// session(1+) cookie(1+) suites(2+) compression(1+)
/// extensions(2+): (type, len, data)*.
fn pair_hint_from_client_hello(data: &[u8]) -> Option<String> {
    if data.len() < 13 + 12 || data[0] != 22 || data[3] != 0 || data[4] != 0 {
        return None; // not an epoch-0 handshake record
    }
    let body = &data[13..];
    if body.len() < 12 || body[0] != 1 {
        return None; // not a ClientHello
    }
    let mut pos = 12 + 2 + 32;
    let take = |data: &[u8], pos: &mut usize, n: usize| -> Option<()> {
        if data.len() < *pos + n {
            None
        } else {
            *pos += n;
            Some(())
        }
    };
    let session_len = *body.get(pos)? as usize;
    take(body, &mut pos, 1 + session_len)?;
    let cookie_len = *body.get(pos)? as usize;
    take(body, &mut pos, 1 + cookie_len)?;
    if body.len() < pos + 2 {
        return None;
    }
    let suites_len = u16::from_be_bytes([body[pos], body[pos + 1]]) as usize;
    take(body, &mut pos, 2 + suites_len)?;
    if body.len() < pos + 1 {
        return None;
    }
    let compression_len = body[pos] as usize;
    take(body, &mut pos, 1 + compression_len)?;
    if body.len() < pos + 2 {
        return None;
    }
    let exts_len = u16::from_be_bytes([body[pos], body[pos + 1]]) as usize;
    pos += 2;
    let end = (pos + exts_len).min(body.len());
    while pos + 4 <= end {
        let ty = u16::from_be_bytes([body[pos], body[pos + 1]]);
        let len = u16::from_be_bytes([body[pos + 2], body[pos + 3]]) as usize;
        pos += 4;
        if pos + len > end {
            return None;
        }
        if ty == crate::proto_gen::dtls_ext::DC_PAIR_HINT {
            return String::from_utf8(body[pos..pos + len].to_vec()).ok();
        }
        pos += len;
    }
    None
}

impl PeerMux {
    /// Bind the shared socket and start its reader thread. The
    /// thread lives as long as the socket (process lifetime in
    /// practice); dropping every peer just idles it.
    pub fn bind(addr: SocketAddr) -> io::Result<Self> {
        let socket = Arc::new(UdpSocket::bind(addr)?);
        let local = socket.local_addr()?;
        let inner = Arc::new(MuxInner {
            socket: socket.clone(),
            addr: local,
            by_ufrag: Mutex::new(HashMap::new()),
            by_src: Mutex::new(HashMap::new()),
            by_cid: Mutex::new(HashMap::new()),
            probes: Mutex::new(Vec::new()),
            next_cid: std::sync::atomic::AtomicU64::new(1),
        });
        let reader_inner = inner.clone();
        socket.set_read_timeout(Some(Duration::from_millis(200)))?;
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 65536];
            loop {
                match socket.recv_from(&mut buf) {
                    Ok((n, src)) => {
                        if n > 0 {
                            let src = crate::stun::normalize_addr(src);
                            reader_inner.deliver(buf[..n].to_vec(), src);
                        }
                    }
                    Err(e)
                        if e.kind() == io::ErrorKind::WouldBlock
                            || e.kind() == io::ErrorKind::TimedOut => {}
                    Err(_) => return,
                }
            }
        });
        Ok(Self { inner })
    }

    /// The shared socket's bound address; every peer created
    /// here advertises this port in its host candidates.
    pub fn local_addr(&self) -> SocketAddr {
        self.inner.addr
    }

    /// A peer on the shared socket (system platform).
    pub fn new_peer(&self, config: PeerConfig) -> io::Result<Peer> {
        self.new_peer_with_platform(config, crate::platform::Platform::system())
    }

    /// A peer on the shared socket with an injected platform
    /// (embedded/RTOS clock + entropy).
    pub fn new_peer_with_platform(
        &self,
        config: PeerConfig,
        platform: crate::platform::Platform,
    ) -> io::Result<Peer> {
        let (tx, rx) = channel();
        let n = self
            .inner
            .next_cid
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut cid = self.inner.addr.port().to_be_bytes().to_vec();
        cid.extend_from_slice(&n.to_be_bytes());
        let endpoint = Arc::new(MuxEndpoint {
            inner: self.inner.clone(),
            tx,
            rx: Mutex::new(rx),
            timeout: Mutex::new(None),
            me: Mutex::new(None),
            cid,
        });
        *endpoint.me.lock().unwrap() = Some(Arc::downgrade(&endpoint));
        let peer = Peer::new_with_io(config, platform, endpoint.clone(), self.inner.addr.port())?;
        self.inner
            .by_ufrag
            .lock()
            .unwrap()
            .insert(peer.local_ufrag(), Arc::downgrade(&endpoint));
        self.inner
            .by_cid
            .lock()
            .unwrap()
            .insert(endpoint.cid.clone(), Arc::downgrade(&endpoint));
        Ok(peer)
    }
}
