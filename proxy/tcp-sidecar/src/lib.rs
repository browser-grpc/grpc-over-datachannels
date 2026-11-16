//! Userspace TCP leg (smoltcp) for the grpc-dc native wrapper.
//!
//! The wrapper contract is `dc <-> http2 <-> stock gRPC
//! server`; the TCP leg between the HTTP/2 side and the stock
//! server is selectable: an OS socket, or this sidecar — two
//! smoltcp stacks joined by a virtual Ethernet pair, driven by
//! one poll thread, with Tokio streams on top. The point of
//! the userspace leg is instrumentation a kernel socket
//! cannot give: every frame crosses the pair in-process, so
//! [`Sidecar::stats`] reports wire-level packet/byte counts
//! and TCP retransmissions (detected by sequence tracking at
//! the bridge) alongside the SCTP `AssociationStats` and
//! HTTP/2 counters in the unified `LinkStats` shape.
//!
//! Deliberate limits: IPv4, one listener, loopback-style
//! virtual link only (this is a test/embedding leg, not a
//! general network stack). `dc-webrtc` stays zero-dependency;
//! smoltcp lives only in this crate.

use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::phy::{Device, Medium, RxToken, TxToken};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr};
use std::collections::{HashMap, VecDeque};
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{mpsc, oneshot};

/// Wire-level TCP counters for the virtual link (both
/// directions aggregated). `tcp_retransmits` counts segments
/// whose sequence range was already covered (bridge-level
/// sequence tracking), `tcp_retransmit_bytes` their overlap.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TcpStats {
    pub frames_sent: u64,
    pub frames_received: u64,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    pub tcp_retransmits: u64,
    pub tcp_retransmit_bytes: u64,
}

#[derive(Default)]
struct WireStats {
    frames_ab: u64,
    frames_ba: u64,
    bytes_ab: u64,
    bytes_ba: u64,
    retransmits: u64,
    retransmit_bytes: u64,
    // direction -> (src,dst) -> highest end-of-sequence seen
    max_seq_end: HashMap<(bool, u32, u16, u32, u16), u32>,
}

impl WireStats {
    fn observe(&mut self, a_to_b: bool, frame: &[u8]) {
        if a_to_b {
            self.frames_ab += 1;
            self.bytes_ab += frame.len() as u64;
        } else {
            self.frames_ba += 1;
            self.bytes_ba += frame.len() as u64;
        }
        // Ethernet II (14) + IPv4 (variable) + TCP: track
        // payload sequence ranges per flow direction.
        if frame.len() < 14 + 20 + 20 || u16::from_be_bytes([frame[12], frame[13]]) != 0x0800 {
            return;
        }
        let ip = &frame[14..];
        let ihl = ((ip[0] & 0x0f) as usize) * 4;
        if ip.len() < ihl + 20 || ip[9] != 6 {
            return;
        }
        let src = u32::from_be_bytes(ip[12..16].try_into().unwrap());
        let dst = u32::from_be_bytes(ip[16..20].try_into().unwrap());
        let tcp = &ip[ihl..];
        let sport = u16::from_be_bytes(tcp[0..2].try_into().unwrap());
        let dport = u16::from_be_bytes(tcp[2..4].try_into().unwrap());
        let seq = u32::from_be_bytes(tcp[4..8].try_into().unwrap());
        let data_len = (ip.len() - ihl - ((tcp[12] >> 4) as usize) * 4) as u32;
        if data_len == 0 {
            return;
        }
        let key = (a_to_b, src, sport, dst, dport);
        let end = seq.wrapping_add(data_len);
        match self.max_seq_end.get(&key) {
            Some(&max) if (seq.wrapping_sub(max) as i32) < 0 => {
                let overlap = max.min(end).wrapping_sub(seq);
                self.retransmits += 1;
                self.retransmit_bytes += overlap as u64;
            }
            _ => {
                self.max_seq_end.insert(key, end);
            }
        }
    }

    fn snapshot(&self) -> TcpStats {
        TcpStats {
            frames_sent: self.frames_ab + self.frames_ba,
            frames_received: self.frames_ab + self.frames_ba,
            bytes_sent: self.bytes_ab + self.bytes_ba,
            bytes_received: self.bytes_ab + self.bytes_ba,
            tcp_retransmits: self.retransmits,
            tcp_retransmit_bytes: self.retransmit_bytes,
        }
    }
}

struct Shared {
    a_in: Arc<Mutex<VecDeque<Vec<u8>>>>,
    b_in: Arc<Mutex<VecDeque<Vec<u8>>>>,
    stats: Mutex<WireStats>,
    drop_every: u64,
    seen: Mutex<u64>,
}

struct VirtualDevice {
    inbound: Arc<Mutex<VecDeque<Vec<u8>>>>,
    peer_inbound: Arc<Mutex<VecDeque<Vec<u8>>>>,
    shared: Arc<Shared>,
    a_to_b: bool,
}

struct VRxToken(Vec<u8>, Arc<Shared>, bool);
struct VTxToken(Arc<Mutex<VecDeque<Vec<u8>>>>, Arc<Shared>, bool);

impl RxToken for VRxToken {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.0)
    }
}

impl TxToken for VTxToken {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut buf = vec![0u8; len];
        let out = f(&mut buf);
        {
            let mut seen = self.1.seen.lock().unwrap();
            *seen += 1;
            let drop = self.1.drop_every > 0 && *seen % self.1.drop_every == 0;
            if !drop {
                self.1.stats.lock().unwrap().observe(self.2, &buf);
                self.0.lock().unwrap().push_back(buf);
            }
        }
        out
    }
}

impl Device for VirtualDevice {
    type RxToken<'a> = VRxToken;
    type TxToken<'a> = VTxToken;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let frame = self.inbound.lock().unwrap().pop_front()?;
        Some((
            VRxToken(frame, self.shared.clone(), self.a_to_b),
            VTxToken(self.peer_inbound.clone(), self.shared.clone(), self.a_to_b),
        ))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        Some(VTxToken(self.peer_inbound.clone(), self.shared.clone(), self.a_to_b))
    }

    fn capabilities(&self) -> smoltcp::phy::DeviceCapabilities {
        let mut caps = smoltcp::phy::DeviceCapabilities::default();
        caps.medium = Medium::Ethernet;
        caps.max_transmission_unit = 1514;
        caps
    }
}

struct StreamEntry {
    handle: SocketHandle,
    to_app: mpsc::UnboundedSender<Vec<u8>>,
    from_app: mpsc::UnboundedReceiver<Vec<u8>>,
    established: Option<oneshot::Sender<()>>,
    listen: bool,
}

enum Request {
    Connect { respond: oneshot::Sender<SidecarStream> },
}

/// One end of a sidecar TCP stream (Tokio AsyncRead/Write).
pub struct SidecarStream {
    tx: mpsc::UnboundedSender<Vec<u8>>,
    rx: mpsc::UnboundedReceiver<Vec<u8>>,
    pending: VecDeque<u8>,
}

impl AsyncRead for SidecarStream {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        loop {
            if !self.pending.is_empty() {
                let n = self.pending.len().min(buf.remaining());
                let chunk: Vec<u8> = self.pending.drain(..n).collect();
                buf.put_slice(&chunk);
                return std::task::Poll::Ready(Ok(()));
            }
            match self.rx.poll_recv(cx) {
                std::task::Poll::Ready(Some(data)) => self.pending.extend(data),
                std::task::Poll::Ready(None) => return std::task::Poll::Ready(Ok(())),
                std::task::Poll::Pending => return std::task::Poll::Pending,
            }
        }
    }
}

impl AsyncWrite for SidecarStream {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        data: &[u8],
    ) -> std::task::Poll<io::Result<usize>> {
        self.tx
            .send(data.to_vec())
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "sidecar closed"))?;
        std::task::Poll::Ready(Ok(data.len()))
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}

impl From<TcpStats> for grpc_dc::link_stats::TcpStats {
    fn from(s: TcpStats) -> Self {
        Self {
            frames_sent: s.frames_sent,
            frames_received: s.frames_received,
            bytes_sent: s.bytes_sent,
            bytes_received: s.bytes_received,
            tcp_retransmits: s.tcp_retransmits,
            tcp_retransmit_bytes: s.tcp_retransmit_bytes,
        }
    }
}

/// The sidecar: client + server smoltcp stacks on a virtual
/// Ethernet pair, one listener (port 50051), poll thread
/// owned. `drop_every` > 0 drops every Nth frame at the wire
/// (loss injection for tests/instrumentation proofs).
pub struct Sidecar {
    requests: mpsc::UnboundedSender<Request>,
    accepted: tokio::sync::Mutex<mpsc::UnboundedReceiver<SidecarStream>>,
    shared: Arc<Shared>,
    stop: Arc<AtomicBool>,
}

const SERVER_IP: [u8; 4] = [10, 0, 0, 2];
const CLIENT_IP: [u8; 4] = [10, 0, 0, 1];
pub const LISTEN_PORT: u16 = 50051;

impl Sidecar {
    pub fn new() -> Self {
        Self::with_drop(0)
    }

    pub fn with_drop(drop_every: u64) -> Self {
        let shared = Arc::new(Shared {
            a_in: Arc::new(Mutex::new(VecDeque::new())),
            b_in: Arc::new(Mutex::new(VecDeque::new())),
            stats: Mutex::new(WireStats::default()),
            drop_every,
            seen: Mutex::new(0),
        });
        let (req_tx, req_rx) = mpsc::unbounded_channel();
        let (accept_tx, accept_rx) = mpsc::unbounded_channel();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_shared = shared.clone();
        let thread_stop = stop.clone();
        std::thread::spawn(move || {
            run_stacks(thread_shared, req_rx, accept_tx, thread_stop);
        });
        Self { requests: req_tx, accepted: tokio::sync::Mutex::new(accept_rx), shared, stop }
    }

    /// Connect to the sidecar listener. The returned stream
    /// buffers while the TCP handshake completes inside the
    /// virtual link (poll-thread driven).
    pub async fn connect(&self) -> io::Result<SidecarStream> {
        let (tx, rx) = oneshot::channel();
        self.requests
            .send(Request::Connect { respond: tx })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "sidecar stopped"))?;
        rx.await.map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "sidecar stopped"))
    }

    /// Accept one inbound connection at the listener.
    pub async fn accept(&self) -> io::Result<SidecarStream> {
        let mut rx = self.accepted.lock().await;
        rx.recv()
            .await
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "sidecar stopped"))
    }

    pub fn stats(&self) -> TcpStats {
        self.shared.stats.lock().unwrap().snapshot()
    }

    /// Unified LinkStats snapshot with the TCP leg filled
    /// from this sidecar (SCTP/HTTP2 legs are the caller's to
    /// add via with_sctp/with_http2).
    pub fn link_stats(&self) -> grpc_dc::link_stats::LinkStats {
        grpc_dc::link_stats::LinkStats::new().with_tcp(self.stats().into())
    }
}

impl Drop for Sidecar {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

fn make_iface(ip: [u8; 4], mac: [u8; 6], device: &mut VirtualDevice) -> Interface {
    let config = Config::new(EthernetAddress(mac).into());
    let mut iface = Interface::new(config, device, Instant::now());
    iface.update_ip_addrs(|addrs| {
        let _ = addrs.push(IpCidr::new(IpAddress::v4(ip[0], ip[1], ip[2], ip[3]), 24));
    });
    iface
}

fn run_stacks(
    shared: Arc<Shared>,
    mut requests: mpsc::UnboundedReceiver<Request>,
    accepted: mpsc::UnboundedSender<SidecarStream>,
    stop: Arc<AtomicBool>,
) {
    let mut a_dev = VirtualDevice {
        inbound: shared.a_in.clone(),
        peer_inbound: shared.b_in.clone(),
        shared: shared.clone(),
        a_to_b: true,
    };
    let mut b_dev = VirtualDevice {
        inbound: shared.b_in.clone(),
        peer_inbound: shared.a_in.clone(),
        shared: shared.clone(),
        a_to_b: false,
    };
    let mut a_iface = make_iface(CLIENT_IP, [0x02, 0, 0, 0, 0, 1], &mut a_dev);
    let mut b_iface = make_iface(SERVER_IP, [0x02, 0, 0, 0, 0, 2], &mut b_dev);
    let mut a_sockets = SocketSet::new(Vec::new());
    let mut b_sockets = SocketSet::new(Vec::new());

    let mut listen_handle = {
        let rx = tcp::SocketBuffer::new(vec![0; 65535]);
        let tx = tcp::SocketBuffer::new(vec![0; 65535]);
        let mut sock = tcp::Socket::new(rx, tx);
        sock.listen(LISTEN_PORT).expect("listen");
        b_sockets.add(sock)
    };
    let mut entries_a: Vec<StreamEntry> = Vec::new();
    let mut entries_b: Vec<StreamEntry> = Vec::new();
    let start = std::time::Instant::now();

    while !stop.load(Ordering::Relaxed) {
        let now = Instant::from_millis(start.elapsed().as_millis() as i64);
        // New outbound connections.
        while let Ok(req) = requests.try_recv() {
            match req {
                Request::Connect { respond } => {
                    let rx = tcp::SocketBuffer::new(vec![0; 65535]);
                    let tx = tcp::SocketBuffer::new(vec![0; 65535]);
                    let mut sock = tcp::Socket::new(rx, tx);
                    let local = 49152 + (entries_a.len() as u16);
                    let remote = (IpAddress::v4(SERVER_IP[0], SERVER_IP[1], SERVER_IP[2], SERVER_IP[3]), LISTEN_PORT);
                    let _ = sock.connect(a_iface.context(), remote, local);
                    let handle = a_sockets.add(sock);
                    let (to_app, app_rx) = mpsc::unbounded_channel();
                    let (app_tx, from_app) = mpsc::unbounded_channel();
                    let (est_tx, est_rx) = oneshot::channel::<()>();
                    let stream = SidecarStream { tx: app_tx, rx: app_rx, pending: VecDeque::new() };
                    entries_a.push(StreamEntry {
                        handle,
                        to_app,
                        from_app,
                        established: Some(est_tx),
                        listen: false,
                    });
                    // Hand the stream back once established (poll loop
                    // fires the oneshot); the caller awaits data, so
                    // resolve immediately with the pending stream.
                    let _ = est_rx;
                    let _ = respond.send(stream);
                }
            }
        }
        a_iface.poll(now, &mut a_dev, &mut a_sockets);
        b_iface.poll(now, &mut b_dev, &mut b_sockets);
        // Listener accepts: an established listen socket becomes
        // the stream; install a fresh listener in its place.
        {
            let established = {
                let sock = b_sockets.get_mut::<tcp::Socket>(listen_handle);
                sock.state() == smoltcp::socket::tcp::State::Established
            };
            if established {
                let (to_app, app_rx) = mpsc::unbounded_channel();
                let (app_tx, from_app) = mpsc::unbounded_channel();
                let stream = SidecarStream { tx: app_tx, rx: app_rx, pending: VecDeque::new() };
                entries_b.push(StreamEntry {
                    handle: listen_handle,
                    to_app,
                    from_app,
                    established: None,
                    listen: false,
                });
                let _ = accepted.send(stream);
                let rx = tcp::SocketBuffer::new(vec![0; 65535]);
                let tx = tcp::SocketBuffer::new(vec![0; 65535]);
                let mut fresh = tcp::Socket::new(rx, tx);
                let _ = fresh.listen(LISTEN_PORT);
                listen_handle = b_sockets.add(fresh);
            }
        }
        service(&mut a_sockets, &mut entries_a);
        service(&mut b_sockets, &mut entries_b);
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
}

fn service(sockets: &mut SocketSet<'_>, entries: &mut Vec<StreamEntry>) {
    for entry in entries.iter_mut() {
        let sock = sockets.get_mut::<tcp::Socket>(entry.handle);
        if sock.state() == smoltcp::socket::tcp::State::Established {
            if let Some(tx) = entry.established.take() {
                let _ = tx.send(());
            }
        }
        // Only consume app data the socket can take right now;
        // draining into a not-yet-established socket would
        // silently drop the peer's first bytes.
        while sock.can_send() {
            match entry.from_app.try_recv() {
                Ok(data) => {
                    let _ = sock.send_slice(&data);
                }
                Err(_) => break,
            }
        }
        while sock.can_recv() {
            let mut buf = [0u8; 8192];
            match sock.recv_slice(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if entry.to_app.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    }
}
