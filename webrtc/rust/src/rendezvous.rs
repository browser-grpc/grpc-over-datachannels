//! Rendezvous listener: a fixed, pre-published WebRTC endpoint
//! browsers can connect to with no signaling exchange at all.
//!
//! The listener owns one UDP socket, one fixed ICE ufrag/pwd
//! pair, and one fixed DTLS certificate. Those four values plus
//! the public host/port form a rendezvous descriptor, published
//! beforehand (hardcoded, DNS, an HTTPS file — host's choice).
//! A browser synthesizes this endpoint's SDP locally from the
//! descriptor (see the generated rendezvousChannel), answers
//! it in-page, and starts ICE as the controlling agent (the
//! descriptor says ICE-lite). Nothing is ever transmitted out
//! of band after publication.
//!
//! Server side of each dial: the first STUN Binding request
//! carries the dialer's ufrag in its USERNAME. The listener
//! spawns a Peer for it with the fixed credentials/certificate,
//! synthesizes the dialer's offer from the packet's source
//! address (its ICE pwd and DTLS fingerprint are unknown; the
//! peer requires neither), and feeds the packet in. The dialer
//! nominates (USE-CANDIDATE), DTLS runs with this side as
//! server presenting the fixed cert, and the connected
//! DcEndpoint is delivered to on_endpoint like any other
//! peer's.

use crate::endpoint::DcEndpoint;
use crate::ice::Candidate;
use crate::peer::{DatagramIo, Peer, PeerConfig};
use crate::platform::Platform;
use crate::proto_gen::stun_attr;
use crate::sdp::{generate, SessionDescription};
use crate::stun::Message;
use crate::x509::Certificate;
use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The publishable description of a RendezvousListener: the
/// same shape the generated browser rendezvousChannel
/// consumes.
#[derive(Clone, Debug)]
pub struct RendezvousDescriptor {
    pub host: String,
    pub port: u16,
    pub ice_ufrag: String,
    pub ice_pwd: String,
    pub fingerprint: String,
    pub setup: String,
}

impl RendezvousDescriptor {
    /// Render as the JSON object browsers fetch or embed.
    pub fn to_json(&self) -> String {
        format!(
            "{{\"host\":\"{}\",\"port\":{},\"iceUfrag\":\"{}\",\"icePwd\":\"{}\",\"fingerprint\":\"{}\",\"setup\":\"{}\"}}",
            self.host, self.port, self.ice_ufrag, self.ice_pwd, self.fingerprint, self.setup
        )
    }
}

/// Rendezvous listener configuration. Fix ice_ufrag, ice_pwd,
/// and certificate and the published descriptor stays stable
/// across restarts; ephemeral values rotate per process.
pub struct RendezvousOptions {
    pub local_ips: Vec<IpAddr>,
    pub ice_ufrag: Option<String>,
    pub ice_pwd: Option<String>,
    pub certificate: Option<Certificate>,
    /// RFC 7675 consent freshness per session peer. When
    /// either is set, checks run every consent_interval
    /// (default 5 s) and expire after consent_expiry
    /// (default 30 s) without a response.
    pub consent_interval: Option<Duration>,
    pub consent_expiry: Option<Duration>,
    /// Receives each connected session's endpoint.
    pub on_endpoint: Box<dyn Fn(DcEndpoint) + Send + Sync>,
    /// Receives background connect failures.
    pub on_error: Box<dyn Fn(io::Error) + Send + Sync>,
}

impl Default for RendezvousOptions {
    fn default() -> Self {
        Self {
            local_ips: Vec::new(),
            ice_ufrag: None,
            ice_pwd: None,
            certificate: None,
            consent_interval: None,
            consent_expiry: None,
            on_endpoint: Box::new(|_| {}),
            on_error: Box::new(|_| {}),
        }
    }
}

struct RvInner {
    socket: Arc<UdpSocket>,
    addr: SocketAddr,
    ice_ufrag: String,
    ice_pwd: String,
    certificate: Certificate,
    local_ips: Vec<IpAddr>,
    consent_interval: Option<Duration>,
    consent_expiry: Option<Duration>,
    by_remote: Mutex<HashMap<String, Arc<RvEndpoint>>>,
    by_src: Mutex<HashMap<SocketAddr, Arc<RvEndpoint>>>,
    on_endpoint: Box<dyn Fn(DcEndpoint) + Send + Sync>,
    on_error: Box<dyn Fn(io::Error) + Send + Sync>,
    closed: AtomicBool,
}

/// One fixed rendezvous endpoint: a single UDP socket
/// demuxing sessions by dialer ufrag.
pub struct RendezvousListener {
    inner: Arc<RvInner>,
}

/// One session's view of the shared socket: sends go straight
/// to the real socket; receives drain the per-session inbox
/// the listener reader fills. Implements the peer's
/// `DatagramIo` seam.
struct RvEndpoint {
    socket: Arc<UdpSocket>,
    tx: Sender<(Vec<u8>, SocketAddr)>,
    rx: Mutex<Receiver<(Vec<u8>, SocketAddr)>>,
    timeout: Mutex<Option<Duration>>,
}

impl RvEndpoint {
    fn enqueue(&self, data: Vec<u8>, src: SocketAddr) {
        let _ = self.tx.send((data, src));
    }
}

impl DatagramIo for RvEndpoint {
    fn send_to(&self, buf: &[u8], dest: SocketAddr) -> io::Result<usize> {
        self.socket.send_to(buf, dest)
    }

    fn recv_from(&self, buf: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
        let timeout = *self.timeout.lock().unwrap();
        let rx = self.rx.lock().unwrap();
        let received = match timeout {
            Some(dur) => match rx.recv_timeout(dur) {
                Ok(v) => Ok(v),
                Err(RecvTimeoutError::Timeout) => {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "rendezvous recv timeout"));
                }
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(io::Error::new(io::ErrorKind::BrokenPipe, "rendezvous closed"));
                }
            },
            None => rx
                .recv()
                .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "rendezvous closed")),
        };
        let (data, src) = received?;
        let n = data.len().min(buf.len());
        buf[..n].copy_from_slice(&data[..n]);
        Ok((n, src))
    }

    fn set_read_timeout(&self, dur: Option<Duration>) -> io::Result<()> {
        *self.timeout.lock().unwrap() = dur;
        Ok(())
    }
}

impl RendezvousListener {
    /// Bind the listener socket and start accepting
    /// rendezvous dials.
    pub fn bind(addr: SocketAddr, options: RendezvousOptions) -> io::Result<Self> {
        let socket = Arc::new(UdpSocket::bind(addr)?);
        let local = socket.local_addr()?;
        let inner = Arc::new(RvInner {
            addr: local,
            ice_ufrag: options
                .ice_ufrag
                .clone()
                .unwrap_or_else(crate::stun::random_ufrag),
            ice_pwd: options
                .ice_pwd
                .clone()
                .unwrap_or_else(crate::stun::random_password),
            certificate: options
                .certificate
                .clone()
                .unwrap_or_else(|| Certificate::generate_self_signed("dc-webrtc")),
            local_ips: options.local_ips.clone(),
            consent_interval: options.consent_interval,
            consent_expiry: options.consent_expiry,
            by_remote: Mutex::new(HashMap::new()),
            by_src: Mutex::new(HashMap::new()),
            on_endpoint: options.on_endpoint,
            on_error: options.on_error,
            closed: AtomicBool::new(false),
            socket,
        });
        let reader = inner.clone();
        std::thread::spawn(move || loop {
            if reader.closed.load(Ordering::SeqCst) {
                return;
            }
            let _ = reader.socket.set_read_timeout(Some(Duration::from_millis(200)));
            let mut buf = vec![0u8; 65536];
            match reader.socket.recv_from(&mut buf) {
                Ok((n, src)) => {
                    buf.truncate(n);
                    if !buf.is_empty() {
                        route(&reader, buf, crate::stun::normalize_addr(src));
                    }
                }
                Err(e)
                    if e.kind() == io::ErrorKind::WouldBlock
                        || e.kind() == io::ErrorKind::TimedOut => {}
                Err(_) => return,
            }
        });
        Ok(Self { inner })
    }

    /// The listener socket's bound address.
    pub fn local_addr(&self) -> SocketAddr {
        self.inner.addr
    }

    /// The publishable descriptor for `host` (the public IP
    /// browsers should dial).
    pub fn descriptor(&self, host: &str) -> RendezvousDescriptor {
        RendezvousDescriptor {
            host: host.to_string(),
            port: self.inner.addr.port(),
            ice_ufrag: self.inner.ice_ufrag.clone(),
            ice_pwd: self.inner.ice_pwd.clone(),
            fingerprint: self.inner.certificate.fingerprint(),
            setup: "passive".to_string(),
        }
    }

    /// Stop accepting new dials (live sessions keep their
    /// endpoints; drop them to end sessions).
    pub fn close(&self) {
        self.inner.closed.store(true, Ordering::SeqCst);
    }
}

fn synthesized_offer(src: SocketAddr, remote_ufrag: &str) -> String {
    let desc = SessionDescription {
        ufrag: remote_ufrag.to_string(),
        pwd: "rendezvousUnknownPwd0000".to_string(),
        fingerprint:
            "00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00"
                .to_string(),
        setup: "actpass".to_string(),
        candidates: vec![Candidate::host(src, "1")],
        sctp_port: crate::sctp::SCTP_PORT,
    };
    generate(&desc, true)
}

fn spawn_session(inner: &Arc<RvInner>, src: SocketAddr, remote_ufrag: &str, first: Vec<u8>) {
    let (tx, rx) = channel::<(Vec<u8>, SocketAddr)>();
    let endpoint = Arc::new(RvEndpoint {
        socket: inner.socket.clone(),
        tx,
        rx: Mutex::new(rx),
        timeout: Mutex::new(None),
    });
    {
        let mut by_remote = inner.by_remote.lock().unwrap();
        by_remote.insert(remote_ufrag.to_string(), endpoint.clone());
        inner
            .by_src
            .lock()
            .unwrap()
            .insert(src, endpoint.clone());
    }
    let config = PeerConfig {
        local_ips: inner.local_ips.clone(),
        require_peer_certificate: false,
        certificate: Some(inner.certificate.clone()),
        ..Default::default()
    };
    let port = inner.addr.port();
    let mut peer = match Peer::new_with_io(config, Platform::system(), endpoint.clone(), port) {
        Ok(peer) => peer,
        Err(e) => {
            (inner.on_error)(e);
            return;
        }
    };
    peer.set_local_credentials(&inner.ice_ufrag, &inner.ice_pwd);
    if inner.consent_interval.is_some() || inner.consent_expiry.is_some() {
        peer.set_consent(
            inner.consent_interval.or(Some(Duration::from_secs(5))),
            inner.consent_expiry.unwrap_or(Duration::from_secs(30)),
            || {},
        );
    }
    if let Err(e) = peer.handle_rendezvous_offer(&synthesized_offer(src, remote_ufrag)) {
        (inner.on_error)(e);
        return;
    }
    endpoint.enqueue(first, src);
    let inner2 = inner.clone();
    std::thread::spawn(move || match peer.connect() {
        Ok(dc_endpoint) => (inner2.on_endpoint)(dc_endpoint),
        Err(e) => (inner2.on_error)(e),
    });
}

fn route(inner: &Arc<RvInner>, msg: Vec<u8>, src: SocketAddr) {
    if !msg.is_empty() && msg[0] < 4 {
        if let Some(stun) = Message::decode(&msg) {
            if let Some(username) = stun.attr(stun_attr::USERNAME) {
                if let Ok(username) = std::str::from_utf8(username) {
                    if let Some((local, remote)) = username.split_once(':') {
                        if local == inner.ice_ufrag && !remote.is_empty() {
                            let existing = {
                                let by_remote = inner.by_remote.lock().unwrap();
                                by_remote.get(remote).cloned()
                            };
                            match existing {
                                Some(endpoint) => {
                                    inner
                                        .by_src
                                        .lock()
                                        .unwrap()
                                        .insert(src, endpoint.clone());
                                    endpoint.enqueue(msg, src);
                                }
                                None => spawn_session(inner, src, remote, msg),
                            }
                            return;
                        }
                        return;
                    }
                }
            }
        }
        let endpoint = inner.by_src.lock().unwrap().get(&src).cloned();
        if let Some(endpoint) = endpoint {
            endpoint.enqueue(msg, src);
        }
        return;
    }
    let endpoint = inner.by_src.lock().unwrap().get(&src).cloned();
    if let Some(endpoint) = endpoint {
        endpoint.enqueue(msg, src);
    }
}
