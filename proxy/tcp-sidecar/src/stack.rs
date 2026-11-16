//! Single-stack front ends: one smoltcp interface over a
//! real device, so a sidecar leg can reach actual stock
//! servers instead of only its in-process virtual pair.
//!
//! - [`Stack::udp`]: Ethernet frames tunnelled in UDP
//!   datagrams between two processes/hosts (no privileges).
//! - [`Stack::tun`] (Linux): a TUN interface, IP medium;
//!   needs CAP_NET_ADMIN or /dev/net/tun access.

use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::phy::{Device, Medium, RxToken, TxToken};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr};
use std::collections::VecDeque;
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::{mpsc, oneshot};

use crate::{SidecarStream, TcpStats, WireStats};

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

pub struct QueueRx(Vec<u8>);
pub struct QueueTx {
    out: Arc<Mutex<VecDeque<Vec<u8>>>>,
    stats: Arc<Mutex<WireStats>>,
    on_tx: Option<Arc<dyn Fn(&[u8]) + Send + Sync>>,
}

impl RxToken for QueueRx {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.0)
    }
}

impl TxToken for QueueTx {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut buf = vec![0u8; len];
        let out = f(&mut buf);
        self.stats.lock().unwrap().observe(true, &buf);
        if let Some(hook) = &self.on_tx {
            hook(&buf);
        } else {
            self.out.lock().unwrap().push_back(buf);
        }
        out
    }
}

/// Ethernet frames over a UDP tunnel (one peer).
pub struct UdpDevice {
    socket: Arc<UdpSocket>,
    peer: SocketAddr,
    rx_queue: Arc<Mutex<VecDeque<Vec<u8>>>>,
    stats: Arc<Mutex<WireStats>>,
}

impl UdpDevice {
    fn pump(&self) {
        let mut buf = [0u8; 65536];
        loop {
            match self.socket.recv_from(&mut buf) {
                Ok((n, from)) if from == self.peer => {
                    let frame = buf[..n].to_vec();
                    self.stats.lock().unwrap().observe_rx(&frame);
                    self.rx_queue.lock().unwrap().push_back(frame);
                }
                _ => return,
            }
        }
    }
}

impl Device for UdpDevice {
    type RxToken<'a> = QueueRx;
    type TxToken<'a> = QueueTx;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        self.pump();
        let frame = self.rx_queue.lock().unwrap().pop_front()?;
        let socket = self.socket.clone();
        let peer = self.peer;
        Some((
            QueueRx(frame),
            QueueTx {
                out: Arc::new(Mutex::new(VecDeque::new())),
                stats: self.stats.clone(),
                on_tx: Some(Arc::new(move |frame: &[u8]| {
                    let _ = socket.send_to(frame, peer);
                })),
            },
        ))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        let socket = self.socket.clone();
        let peer = self.peer;
        Some(QueueTx {
            out: Arc::new(Mutex::new(VecDeque::new())),
            stats: self.stats.clone(),
            on_tx: Some(Arc::new(move |frame: &[u8]| {
                let _ = socket.send_to(frame, peer);
            })),
        })
    }

    fn capabilities(&self) -> smoltcp::phy::DeviceCapabilities {
        let mut caps = smoltcp::phy::DeviceCapabilities::default();
        caps.medium = Medium::Ethernet;
        caps.max_transmission_unit = 1514;
        caps
    }
}

/// TUN device (Linux, IP medium). Frames are bare IP packets.
#[cfg(target_os = "linux")]
pub struct TunDevice {
    file: Arc<Mutex<std::fs::File>>,
    rx_queue: Arc<Mutex<VecDeque<Vec<u8>>>>,
    stats: Arc<Mutex<WireStats>>,
}

#[cfg(target_os = "linux")]
impl TunDevice {
    fn open(name: &str) -> io::Result<Self> {
        use std::os::unix::io::AsRawFd;
        extern "C" {
            fn ioctl(fd: i32, request: u64, arg: *mut IfReq) -> i32;
            fn fcntl(fd: i32, cmd: i32, arg: i32) -> i32;
        }
        #[repr(C)]
        struct IfReq {
            name: [u8; 16],
            flags: u16,
            _pad: [u8; 22],
        }
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/net/tun")?;
        let mut req = IfReq { name: [0; 16], flags: 0x0001 | 0x1000, _pad: [0; 22] };
        let bytes = name.as_bytes();
        req.name[..bytes.len().min(15)].copy_from_slice(&bytes[..bytes.len().min(15)]);
        let rc = unsafe { ioctl(file.as_raw_fd(), 0x400454ca, &mut req) };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        // O_NONBLOCK so the poll loop never parks on read.
        unsafe { fcntl(file.as_raw_fd(), 4, 0o4000) };
        Ok(Self {
            file: Arc::new(Mutex::new(file)),
            rx_queue: Arc::new(Mutex::new(VecDeque::new())),
            stats: Arc::new(Mutex::new(WireStats::single())),
        })
    }

    fn pump(&self) {
        use std::io::Read;
        let mut buf = [0u8; 65536];
        loop {
            let n = {
                let mut file = self.file.lock().unwrap();
                match file.read(&mut buf) {
                    Ok(0) => return,
                    Ok(n) => n,
                    Err(_) => return,
                }
            };
            let frame = buf[..n].to_vec();
            self.stats.lock().unwrap().observe_rx(&frame);
            self.rx_queue.lock().unwrap().push_back(frame);
        }
    }
}

#[cfg(target_os = "linux")]
impl Device for TunDevice {
    type RxToken<'a> = QueueRx;
    type TxToken<'a> = QueueTx;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        self.pump();
        let frame = self.rx_queue.lock().unwrap().pop_front()?;
        let file = self.file.clone();
        Some((
            QueueRx(frame),
            QueueTx {
                out: Arc::new(Mutex::new(VecDeque::new())),
                stats: self.stats.clone(),
                on_tx: Some(Arc::new(move |frame: &[u8]| {
                    use std::io::Write;
                    let _ = file.lock().unwrap().write_all(frame);
                })),
            },
        ))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        let file = self.file.clone();
        Some(QueueTx {
            out: Arc::new(Mutex::new(VecDeque::new())),
            stats: self.stats.clone(),
            on_tx: Some(Arc::new(move |frame: &[u8]| {
                use std::io::Write;
                let _ = file.lock().unwrap().write_all(frame);
            })),
        })
    }

    fn capabilities(&self) -> smoltcp::phy::DeviceCapabilities {
        let mut caps = smoltcp::phy::DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        caps.max_transmission_unit = 1500;
        caps
    }
}

// ---------------------------------------------------------------------------
// Stack: one interface, listener + outbound streams
// ---------------------------------------------------------------------------

enum StackRequest {
    Connect {
        ip: [u8; 4],
        port: u16,
        respond: oneshot::Sender<SidecarStream>,
    },
}

/// One smoltcp stack over a real device. Streams and stats
/// mirror the paired Sidecar's shape.
pub struct Stack {
    requests: mpsc::UnboundedSender<StackRequest>,
    accepted: tokio::sync::Mutex<mpsc::UnboundedReceiver<SidecarStream>>,
    stats: Arc<Mutex<WireStats>>,
    stop: Arc<AtomicBool>,
}

struct Entry {
    handle: SocketHandle,
    to_app: mpsc::UnboundedSender<Vec<u8>>,
    from_app: mpsc::UnboundedReceiver<Vec<u8>>,
    pending: Vec<u8>,
}

impl Stack {
    /// Ethernet-over-UDP tunnel stack: bind locally, peer at
    /// `peer` (the other Stack's bind address).
    pub fn udp(bind: SocketAddr, peer: SocketAddr, ip: [u8; 4], mac: [u8; 6]) -> io::Result<Self> {
        let socket = UdpSocket::bind(bind)?;
        socket.set_nonblocking(true)?;
        let stats = Arc::new(Mutex::new(WireStats::single()));
        let device = UdpDevice {
            socket: Arc::new(socket),
            peer,
            rx_queue: Arc::new(Mutex::new(VecDeque::new())),
            stats: stats.clone(),
        };
        Ok(Self::spawn(device, ip, Some(mac), stats))
    }

    /// TUN stack (Linux). `name` is the interface name (may be
    /// empty for auto-assign); the caller configures the host
    /// interface address/route for `ip` out of band.
    #[cfg(target_os = "linux")]
    pub fn tun(name: &str, ip: [u8; 4]) -> io::Result<Self> {
        let device = TunDevice::open(name)?;
        let stats = device.stats.clone();
        Ok(Self::spawn(device, ip, None, stats))
    }

    fn spawn<D: Device + Send + 'static>(mut device: D, ip: [u8; 4], mac: Option<[u8; 6]>, stats: Arc<Mutex<WireStats>>) -> Self {
        let (req_tx, req_rx) = mpsc::unbounded_channel();
        let (accept_tx, accept_rx) = mpsc::unbounded_channel();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        std::thread::spawn(move || {
            let config = match mac {
                Some(mac) => Config::new(EthernetAddress(mac).into()),
                None => Config::new(smoltcp::wire::HardwareAddress::Ip),
            };
            let mut iface = Interface::new(config, &mut device, Instant::now());
            iface.update_ip_addrs(|addrs| {
                let _ = addrs.push(IpCidr::new(IpAddress::v4(ip[0], ip[1], ip[2], ip[3]), 24));
            });
            run_loop(iface, device, req_rx, accept_tx, thread_stop);
        });
        Self {
            requests: req_tx,
            accepted: tokio::sync::Mutex::new(accept_rx),
            stats,
            stop,
        }
    }

    pub async fn connect(&self, ip: [u8; 4], port: u16) -> io::Result<SidecarStream> {
        let (tx, rx) = oneshot::channel();
        self.requests
            .send(StackRequest::Connect { ip, port, respond: tx })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "stack stopped"))?;
        rx.await.map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "stack stopped"))
    }

    pub async fn accept(&self) -> io::Result<SidecarStream> {
        let mut rx = self.accepted.lock().await;
        rx.recv()
            .await
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "stack stopped"))
    }

    pub fn stats(&self) -> TcpStats {
        self.stats.lock().unwrap().snapshot()
    }

    pub fn link_stats(&self) -> grpc_dc::link_stats::LinkStats {
        grpc_dc::link_stats::LinkStats::new().with_tcp(self.stats().into())
    }
}

impl Drop for Stack {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

fn run_loop<D: Device>(
    mut iface: Interface,
    mut device: D,
    mut requests: mpsc::UnboundedReceiver<StackRequest>,
    accepted: mpsc::UnboundedSender<SidecarStream>,
    stop: Arc<AtomicBool>,
) {
    let mut sockets = SocketSet::new(Vec::new());
    let mut listen_handle: Option<SocketHandle> = None;
    let mut entries: Vec<Entry> = Vec::new();
    let start = std::time::Instant::now();
    while !stop.load(Ordering::Relaxed) {
        let now = Instant::from_millis(start.elapsed().as_millis() as i64);
        while let Ok(req) = requests.try_recv() {
            match req {
                StackRequest::Connect { ip, port, respond } => {
                    if listen_handle.is_none() && entries.is_empty() {
                        // First request may also arm the listener
                        // lazily is not assumed; listener is armed
                        // on first Connect to the well-known port
                        // only when configured below.
                        let _ = &listen_handle;
                    }
                    let rx = tcp::SocketBuffer::new(vec![0; 65535]);
                    let tx = tcp::SocketBuffer::new(vec![0; 65535]);
                    let mut sock = tcp::Socket::new(rx, tx);
                    let local = 49152 + (entries.len() as u16);
                    let remote = (IpAddress::v4(ip[0], ip[1], ip[2], ip[3]), port);
                    if sock.connect(iface.context(), remote, local).is_ok() {
                        let handle = sockets.add(sock);
                        let (to_app, app_rx) = mpsc::unbounded_channel();
                        let (app_tx, from_app) = mpsc::unbounded_channel();
                        entries.push(Entry { handle, to_app, from_app, pending: Vec::new() });
                        let _ = respond.send(SidecarStream {
                            tx: app_tx,
                            rx: app_rx,
                            pending: VecDeque::new(),
                        });
                    }
                }
            }
        }
        // Arm listener on the well-known wrapper port once.
        if listen_handle.is_none() {
            let rx = tcp::SocketBuffer::new(vec![0; 65535]);
            let tx = tcp::SocketBuffer::new(vec![0; 65535]);
            let mut sock = tcp::Socket::new(rx, tx);
            if sock.listen(crate::LISTEN_PORT).is_ok() {
                listen_handle = Some(sockets.add(sock));
            }
        }
        iface.poll(now, &mut device, &mut sockets);
        if let Some(handle) = listen_handle {
            let established = sockets.get_mut::<tcp::Socket>(handle).state()
                == smoltcp::socket::tcp::State::Established;
            if established {
                let (to_app, app_rx) = mpsc::unbounded_channel();
                let (app_tx, from_app) = mpsc::unbounded_channel();
                entries.push(Entry { handle, to_app, from_app, pending: Vec::new() });
                let _ = accepted.send(SidecarStream {
                    tx: app_tx,
                    rx: app_rx,
                    pending: VecDeque::new(),
                });
                let rx = tcp::SocketBuffer::new(vec![0; 65535]);
                let tx = tcp::SocketBuffer::new(vec![0; 65535]);
                let mut fresh = tcp::Socket::new(rx, tx);
                let _ = fresh.listen(crate::LISTEN_PORT);
                listen_handle = Some(sockets.add(fresh));
            }
        }
        for entry in entries.iter_mut() {
            let sock = sockets.get_mut::<tcp::Socket>(entry.handle);
            while sock.can_send() {
                if entry.pending.is_empty() {
                    match entry.from_app.try_recv() {
                        Ok(data) => entry.pending = data,
                        Err(_) => break,
                    }
                }
                match sock.send_slice(&entry.pending) {
                    Ok(n) if n >= entry.pending.len() => entry.pending.clear(),
                    Ok(n) => {
                        entry.pending.drain(..n);
                        break;
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
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
}
