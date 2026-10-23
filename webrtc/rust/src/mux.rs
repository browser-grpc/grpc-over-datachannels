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
//! - Everything else (DTLS) routes by source address, learned
//!   from that peer's STUN traffic. A NAT rebinding can drop a
//!   datagram until the pair's next consent check re-teaches
//!   the route; DTLS/SCTP retransmission covers the gap.
//!
//! Like every single-port mux (Jitsi, Pion), this assumes each
//! remote connection presents a distinct source address — the
//! normal Internet case (one socket/NAT mapping per client).
//! Two muxes peering with each other would present one shared
//! source for several pairs, which DTLS cannot demux without
//! connection IDs (RFC 9146, not implemented); run at most one
//! mux per server<->client relationship.
//! - Unauthenticated STUN probes (srflx gathering has no
//!   username in the response) route to endpoints currently
//!   marked probing via begin_probe/end_probe.
//!
//! All mux peers advertise the shared socket's port as their
//! host-candidate port, which reduces the firewall story to a
//! single opened port. TURN is unavailable on muxed peers (an
//! allocation owns a concrete socket); the mux covers the
//! host/srflx path. IPv6 works when the mux socket is bound to
//! an IPv6 address and peers advertise IPv6 candidates.

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
    probes: Mutex<Vec<Weak<MuxEndpoint>>>,
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

    fn deliver(&self, data: Vec<u8>, src: SocketAddr) {
        // STUN (first byte 0..4 in the peer stacks' convention):
        // route by username ufrag, then by learned source, then
        // to srflx probes. Anything else: by source only.
        let target = if !data.is_empty() && data[0] < 4 {
            let by_name = crate::stun::Message::decode(&data).and_then(|msg| {
                let username = msg.attr(stun_attr::USERNAME)?;
                let text = std::str::from_utf8(username).ok()?;
                let local = text.split(':').next()?;
                self.endpoint(local)
            });
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
            self.endpoint_at(src)
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
            probes: Mutex::new(Vec::new()),
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
        let endpoint = Arc::new(MuxEndpoint {
            inner: self.inner.clone(),
            tx,
            rx: Mutex::new(rx),
            timeout: Mutex::new(None),
            me: Mutex::new(None),
        });
        *endpoint.me.lock().unwrap() = Some(Arc::downgrade(&endpoint));
        let peer = Peer::new_with_io(config, platform, endpoint.clone(), self.inner.addr.port())?;
        self.inner
            .by_ufrag
            .lock()
            .unwrap()
            .insert(peer.local_ufrag(), Arc::downgrade(&endpoint));
        Ok(peer)
    }
}
