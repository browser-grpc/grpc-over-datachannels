//! Platform injection for embedded/RTOS-style deployments.
//!
//! The protocol core (ICE agent, DTLS handshake, SCTP) is driven
//! by three platform services, each behind a trait with a std
//! default so existing behavior is unchanged:
//!
//! - `Clock`: monotonic milliseconds (+ wall seconds for cert
//!   validity). The ICE agent's consent and nomination pacing read
//!   time only through its clock; cert code reads the installed
//!   clock's wall time.
//! - `Rng`: entropy. `crate::crypto::random_bytes` (used by the
//!   DTLS handshake, certificate and key generation, SCTP, STUN)
//!   draws through the installed RNG; `install_rng` swaps it once
//!   at startup, e.g. for a hardware TRNG. Default: /dev/urandom
//!   (std); bare-metal builds must install one.
//! - `UdpTransport`: datagram send/receive. Peer's OS path uses
//!   `StdUdpTransport`; tests and RTOS harnesses use
//!   `MemoryNetwork` endpoints and drive the agents by tick.
//!
//! `ManualClock` + `SeededRng` + `MemoryNetwork` make the whole
//! ICE/DTLS core deterministic and socket-free under test. Without
//! the `std` feature only the trait surface and the manual/seeded
//! implementations exist (alloc-only, bare-metal ready).

use crate::io;
use alloc::sync::Arc;
use alloc::vec::Vec;
use core::net::SocketAddr;
use core::time::Duration;

#[cfg(feature = "std")]
use std::collections::HashMap;
#[cfg(feature = "std")]
use std::net::UdpSocket;
#[cfg(feature = "std")]
use std::sync::mpsc;
#[cfg(feature = "std")]
use std::time::Instant;

/// Mutex used by platform internals: std's with the `std`
/// feature (poison unwrapped), a tiny spin lock without it
/// (platform state is low-contention by construction).
#[cfg(feature = "std")]
pub(crate) struct Mutex<T>(std::sync::Mutex<T>);

#[cfg(feature = "std")]
impl<T> Mutex<T> {
    pub const fn new(data: T) -> Self {
        Self(std::sync::Mutex::new(data))
    }

    pub fn lock(&self) -> std::sync::MutexGuard<'_, T> {
        self.0.lock().unwrap()
    }
}

#[cfg(not(feature = "std"))]
pub(crate) use self::spin::Mutex;

#[cfg(not(feature = "std"))]
mod spin {
    use core::cell::UnsafeCell;
    use core::ops::{Deref, DerefMut};
    use core::sync::atomic::{AtomicBool, Ordering};

    pub struct Mutex<T> {
        locked: AtomicBool,
        data: UnsafeCell<T>,
    }

    pub struct MutexGuard<'a, T> {
        mutex: &'a Mutex<T>,
    }

    unsafe impl<T: Send> Send for Mutex<T> {}
    unsafe impl<T: Send> Sync for Mutex<T> {}

    impl<T> Mutex<T> {
        pub const fn new(data: T) -> Self {
            Self { locked: AtomicBool::new(false), data: UnsafeCell::new(data) }
        }

        pub fn lock(&self) -> MutexGuard<'_, T> {
            while self
                .locked
                .compare_exchange_weak(false, true, Ordering::Acquire, Ordering::Relaxed)
                .is_err()
            {
                core::hint::spin_loop();
            }
            MutexGuard { mutex: self }
        }
    }

    impl<T> Deref for MutexGuard<'_, T> {
        type Target = T;
        fn deref(&self) -> &T {
            unsafe { &*self.mutex.data.get() }
        }
    }

    impl<T> DerefMut for MutexGuard<'_, T> {
        fn deref_mut(&mut self) -> &mut T {
            unsafe { &mut *self.mutex.data.get() }
        }
    }

    impl<T> Drop for MutexGuard<'_, T> {
        fn drop(&mut self) {
            self.mutex.locked.store(false, Ordering::Release);
        }
    }
}

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------

pub trait Clock: Send + Sync {
    /// Monotonic time in milliseconds (arbitrary epoch).
    fn now_ms(&self) -> u64;

    /// Wall-clock Unix seconds for certificate validity windows.
    /// Clocks with no wall source return 0 (cert code then treats
    /// validity as unbounded-by-time where it must choose).
    fn wall_now_secs(&self) -> u64 {
        0
    }
}

/// Wall clock backed by `std::time::Instant` (std builds only).
#[cfg(feature = "std")]
pub struct SystemClock {
    start: Instant,
}

#[cfg(feature = "std")]
impl SystemClock {
    pub fn new() -> Self {
        Self { start: Instant::now() }
    }
}

#[cfg(feature = "std")]
impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(feature = "std")]
impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        self.start.elapsed().as_millis() as u64
    }

    fn wall_now_secs(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }
}

/// Test/RTOS clock advanced explicitly by the driver. Backed by
/// the platform mutex rather than `AtomicU64`: Cortex-M class
/// targets have no 64-bit atomics.
pub struct ManualClock {
    now: Mutex<u64>,
    wall: Mutex<u64>,
}

impl ManualClock {
    pub fn new(start_ms: u64) -> Self {
        Self { now: Mutex::new(start_ms), wall: Mutex::new(0) }
    }

    pub fn advance(&self, delta_ms: u64) {
        *self.now.lock() += delta_ms;
    }

    pub fn set(&self, now_ms: u64) {
        *self.now.lock() = now_ms;
    }

    pub fn set_wall_secs(&self, secs: u64) {
        *self.wall.lock() = secs;
    }
}

impl Clock for ManualClock {
    fn now_ms(&self) -> u64 {
        *self.now.lock()
    }

    fn wall_now_secs(&self) -> u64 {
        *self.wall.lock()
    }
}

static INSTALLED_CLOCK: Mutex<Option<Arc<dyn Clock>>> = Mutex::new(None);

/// Install the process-wide clock used by cert/time helpers.
/// Returns false when a clock was already installed.
pub fn install_clock(clock: Arc<dyn Clock>) -> bool {
    let mut slot = INSTALLED_CLOCK.lock();
    if slot.is_some() {
        return false;
    }
    *slot = Some(clock);
    true
}

/// The installed clock (std default: `SystemClock`; bare metal:
/// a frozen `ManualClock` until one is installed).
pub fn clock() -> Arc<dyn Clock> {
    let mut slot = INSTALLED_CLOCK.lock();
    if slot.is_none() {
        *slot = Some(default_clock());
    }
    slot.as_ref().expect("clock installed").clone()
}

#[cfg(feature = "std")]
fn default_clock() -> Arc<dyn Clock> {
    Arc::new(SystemClock::new())
}

#[cfg(not(feature = "std"))]
fn default_clock() -> Arc<dyn Clock> {
    Arc::new(ManualClock::new(0))
}

/// Wall-clock Unix seconds from the installed clock.
pub fn wall_now_secs() -> u64 {
    clock().wall_now_secs()
}

// ---------------------------------------------------------------------------
// RNG
// ---------------------------------------------------------------------------

pub trait Rng: Send + Sync {
    fn fill(&self, dest: &mut [u8]);
}

/// Default entropy source: /dev/urandom (std builds; matches
/// historical behavior of `crypto::random_bytes`).
#[cfg(feature = "std")]
pub struct UrandomRng;

#[cfg(feature = "std")]
impl Rng for UrandomRng {
    fn fill(&self, dest: &mut [u8]) {
        use std::io::Read;
        std::fs::File::open("/dev/urandom")
            .expect("open /dev/urandom")
            .read_exact(dest)
            .expect("read /dev/urandom");
    }
}

/// Deterministic xorshift64* RNG for tests and simulations.
/// Not suitable for production key material.
pub struct SeededRng {
    state: Mutex<u64>,
}

impl SeededRng {
    pub fn new(seed: u64) -> Self {
        Self { state: Mutex::new(seed | 1) }
    }
}

impl Rng for SeededRng {
    fn fill(&self, dest: &mut [u8]) {
        let mut state = self.state.lock();
        for chunk in dest.chunks_mut(8) {
            let mut x = *state;
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            *state = x;
            let out = x.wrapping_mul(0x2545F4914F6CDD1D);
            chunk.copy_from_slice(&out.to_be_bytes()[..chunk.len()]);
        }
    }
}

static INSTALLED_RNG: Mutex<Option<Arc<dyn Rng>>> = Mutex::new(None);

/// Install the process-wide RNG used by `crypto::random_bytes`.
/// Call once at startup (embedded: wire a hardware TRNG here).
/// Returns false when an RNG was already installed.
pub fn install_rng(rng: Arc<dyn Rng>) -> bool {
    let mut slot = INSTALLED_RNG.lock();
    if slot.is_some() {
        return false;
    }
    *slot = Some(rng);
    true
}

/// The installed RNG (std default: `UrandomRng`; bare metal must
/// `install_rng` first).
pub fn rng() -> Arc<dyn Rng> {
    let mut slot = INSTALLED_RNG.lock();
    if slot.is_none() {
        *slot = Some(default_rng());
    }
    slot.as_ref().expect("rng installed").clone()
}

#[cfg(feature = "std")]
fn default_rng() -> Arc<dyn Rng> {
    Arc::new(UrandomRng)
}

#[cfg(not(feature = "std"))]
fn default_rng() -> Arc<dyn Rng> {
    panic!("platform: install_rng must be called before crypto use on bare metal")
}

/// Draw `n` random bytes through the installed RNG.
pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = alloc::vec![0u8; n];
    rng().fill(&mut buf);
    buf
}

// ---------------------------------------------------------------------------
// UDP transport (std-backed implementations)
// ---------------------------------------------------------------------------

pub trait UdpTransport: Send + Sync {
    fn send_to(&self, buf: &[u8], dest: SocketAddr) -> io::Result<()>;
    /// Receive one datagram; `Ok(None)` on timeout.
    fn recv_from(&self, timeout: Duration) -> io::Result<Option<(Vec<u8>, SocketAddr)>>;
    fn local_addr(&self) -> io::Result<SocketAddr>;
}

/// std::net::UdpSocket-backed transport (the default OS path).
#[cfg(feature = "std")]
pub struct StdUdpTransport {
    socket: UdpSocket,
}

#[cfg(feature = "std")]
impl StdUdpTransport {
    pub fn bind(addr: SocketAddr) -> io::Result<Self> {
        Ok(Self { socket: UdpSocket::bind(addr)? })
    }

    pub fn from_socket(socket: UdpSocket) -> Self {
        Self { socket }
    }
}

#[cfg(feature = "std")]
impl UdpTransport for StdUdpTransport {
    fn send_to(&self, buf: &[u8], dest: SocketAddr) -> io::Result<()> {
        self.socket.send_to(buf, dest).map(|_| ())
    }

    fn recv_from(&self, timeout: Duration) -> io::Result<Option<(Vec<u8>, SocketAddr)>> {
        self.socket.set_read_timeout(Some(timeout))?;
        let mut buf = alloc::vec![0u8; 65536];
        match self.socket.recv_from(&mut buf) {
            Ok((n, src)) => {
                buf.truncate(n);
                Ok(Some((buf, src)))
            }
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::TimedOut =>
            {
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.socket.local_addr()
    }
}

#[cfg(feature = "std")]
type MemoryInbox = mpsc::Receiver<(Vec<u8>, SocketAddr)>;

/// In-memory datagram network for tests and RTOS harnesses:
/// named endpoints exchange packets through the hub with no OS
/// sockets involved. Delivery is FIFO per sender.
#[cfg(feature = "std")]
pub struct MemoryNetwork {
    inboxes: Mutex<HashMap<SocketAddr, mpsc::Sender<(Vec<u8>, SocketAddr)>>>,
}

#[cfg(feature = "std")]
pub struct MemoryUdpTransport {
    addr: SocketAddr,
    inbox: Mutex<MemoryInbox>,
    network: Arc<MemoryNetwork>,
}

#[cfg(feature = "std")]
impl MemoryNetwork {
    pub fn new() -> Self {
        Self { inboxes: Mutex::new(HashMap::new()) }
    }

    /// Create an endpoint bound to `addr` on this network.
    pub fn endpoint(self: &Arc<Self>, addr: SocketAddr) -> Arc<MemoryUdpTransport> {
        let (tx, rx) = mpsc::channel();
        self.inboxes.lock().insert(addr, tx);
        Arc::new(MemoryUdpTransport {
            addr,
            inbox: Mutex::new(rx),
            network: self.clone(),
        })
    }
}

#[cfg(feature = "std")]
impl Default for MemoryNetwork {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(feature = "std")]
impl UdpTransport for MemoryUdpTransport {
    fn send_to(&self, buf: &[u8], dest: SocketAddr) -> io::Result<()> {
        let inboxes = self.network.inboxes.lock();
        match inboxes.get(&dest) {
            Some(tx) => tx
                .send((buf.to_vec(), self.addr))
                .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "peer gone")),
            None => Ok(()), // no listener: packet drops, like UDP
        }
    }

    fn recv_from(&self, timeout: Duration) -> io::Result<Option<(Vec<u8>, SocketAddr)>> {
        match self.inbox.lock().recv_timeout(timeout) {
            Ok(packet) => Ok(Some(packet)),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                Err(io::Error::new(io::ErrorKind::BrokenPipe, "network closed"))
            }
        }
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.addr)
    }
}

// ---------------------------------------------------------------------------
// Platform bundle
// ---------------------------------------------------------------------------

/// The injectable platform services used by the protocol core.
#[derive(Clone)]
pub struct Platform {
    pub clock: Arc<dyn Clock>,
    pub rng: Arc<dyn Rng>,
}

impl Platform {
    #[cfg(feature = "std")]
    pub fn system() -> Self {
        Self {
            clock: Arc::new(SystemClock::new()),
            rng: rng(),
        }
    }

    /// Deterministic platform for tests/simulations.
    pub fn manual(seed: u64) -> (Self, Arc<ManualClock>) {
        let clock = Arc::new(ManualClock::new(0));
        (
            Self {
                clock: clock.clone(),
                rng: Arc::new(SeededRng::new(seed)),
            },
            clock,
        )
    }
}

impl Default for Platform {
    fn default() -> Self {
        #[cfg(feature = "std")]
        {
            Self::system()
        }
        #[cfg(not(feature = "std"))]
        {
            Self {
                clock: default_clock(),
                rng: default_rng(),
            }
        }
    }
}
