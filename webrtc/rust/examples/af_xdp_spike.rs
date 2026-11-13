//! AF_XDP spike for the rendezvous/Direct listener datagram
//! path (optional, never default — the portable UDP socket
//! stays the default and fallback).
//!
//! Question the spike exists to answer: would replacing the
//! listener's `recvmsg` UDP socket with an AF_XDP socket
//! (XSK) move packet rates enough to matter at gRPC message
//! rates, given DTLS/SCTP crypto and copying dominate there?
//! Working hypothesis (unproven): no material gain below
//! ~100k pps; the spike's job is to prove or refute it.
//!
//! What this binary does today:
//! 1. UDP baseline: loopback datagram throughput with the
//!    same socket calls the listener uses (works anywhere).
//! 2. XDP probe: socket(AF_XDP) -> XDP_UMEM_REG -> ring mmap
//!    -> bind(iface, queue). Each stage reports its errno;
//!    binding needs CAP_NET_ADMIN + a real driver queue, so
//!    inside a sandbox it is expected to stop at bind. Run it
//!    on a host (or privileged host-network container) to get
//!    past the probe.
//!
//! The stack is zero-dependency, so the syscalls are declared
//! directly (`extern "C"` against the libc every std binary
//! already links); no new crates.
//!
//! Usage: af_xdp_spike [iface] [queue] [seconds]
//! Defaults: lo 0 3. Loopback has no driver queue for XDP in
//! most setups; use a real NIC queue on a host for the probe.

use std::io;
use std::net::UdpSocket;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[cfg(target_os = "linux")]
mod xdp {
    #![allow(dead_code)]
    use std::ffi::CString;
    use std::io;
    use std::os::raw::{c_int, c_void};

    const AF_XDP: c_int = 44;
    const SOL_XDP: c_int = 283;
    const XDP_UMEM_REG: c_int = 4;
    const XDP_MMAP_OFFSETS: c_int = 1;
    const XDP_PGOFF_RX_RING: i64 = 0;
    const XDP_UMEM_PGOFF_FILL_RING: i64 = 0x1000_0000;
    const XDP_UMEM_PGOFF_COMPLETION_RING: i64 = 0x1800_0000;

    #[repr(C)]
    #[derive(Default)]
    struct UMemReg {
        addr: u64,
        len: u64,
        chunk_size: u32,
        headroom: u32,
        flags: u32,
    }

    #[repr(C)]
    #[derive(Default)]
    struct RingOffset {
        producer: u64,
        consumer: u64,
        desc: u64,
        flags: u64,
    }

    #[repr(C)]
    #[derive(Default)]
    struct MmapOffsets {
        rx: RingOffset,
        tx: RingOffset,
        fr: RingOffset,
        cr: RingOffset,
    }

    #[repr(C)]
    #[derive(Default)]
    struct SockaddrXdp {
        family: u16,
        flags: u16,
        ifindex: u32,
        queue_id: u32,
        shared_umem_fd: u32,
    }

    extern "C" {
        fn socket(domain: c_int, ty: c_int, protocol: c_int) -> c_int;
        fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const c_void, optlen: u32)
            -> c_int;
        fn getsockopt(
            fd: c_int,
            level: c_int,
            optname: c_int,
            optval: *mut c_void,
            optlen: *mut u32,
        ) -> c_int;
        fn mmap(
            addr: *mut c_void,
            length: usize,
            prot: c_int,
            flags: c_int,
            fd: c_int,
            offset: i64,
        ) -> *mut c_void;
        fn bind(fd: c_int, addr: *const SockaddrXdp, len: u32) -> c_int;
        fn if_nametoindex(name: *const std::os::raw::c_char) -> u32;
        fn close(fd: c_int) -> c_int;
    }

    fn last_err(stage: &str) -> String {
        format!("{stage}: {}", io::Error::last_os_error())
    }

    /// Attempt the full XSK setup; return how far it got.
    pub fn probe(iface: &str, queue: u32) -> Result<String, String> {
        const FRAME_COUNT: usize = 4096;
        const FRAME_SIZE: usize = 2048;
        const PROT_READ_WRITE: c_int = 3; // PROT_READ | PROT_WRITE
        const MAP_SHARED_POPULATE: c_int = 0x8001; // MAP_SHARED | MAP_POPULATE

        unsafe {
            let fd = socket(AF_XDP, 0o002, 0); // SOCK_RAW
            if fd < 0 {
                return Err(last_err("socket(AF_XDP)"));
            }
            // UMEM: one anonymous mmap arena carved into frames.
            let umem = mmap(
                std::ptr::null_mut(),
                FRAME_COUNT * FRAME_SIZE,
                PROT_READ_WRITE,
                MAP_SHARED_POPULATE | 0x20, // MAP_ANONYMOUS
                -1,
                0,
            );
            if umem.is_null() || umem as isize == -1 {
                close(fd);
                return Err(last_err("mmap(UMEM)"));
            }
            let reg = UMemReg {
                addr: umem as u64,
                len: (FRAME_COUNT * FRAME_SIZE) as u64,
                chunk_size: FRAME_SIZE as u32,
                headroom: 0,
                flags: 0,
            };
            if setsockopt(fd, SOL_XDP, XDP_UMEM_REG, &reg as *const _ as *const c_void,
                          std::mem::size_of::<UMemReg>() as u32) < 0 {
                close(fd);
                return Err(last_err("setsockopt(XDP_UMEM_REG)"));
            }
            let mut offsets = MmapOffsets::default();
            let mut len = std::mem::size_of::<MmapOffsets>() as u32;
            if getsockopt(fd, SOL_XDP, XDP_MMAP_OFFSETS, &mut offsets as *mut _ as *mut c_void,
                          &mut len) < 0 {
                close(fd);
                return Err(last_err("getsockopt(XDP_MMAP_OFFSETS)"));
            }
            // Ring mmaps (RX + fill/completion): sizes are
            // page multiples; a full spike negotiates ring entry
            // counts via XDP_RX_RING/XDP_UMEM_FILL_RING setsockopt
            // before this point — the probe only proves mapping.
            for (off, what) in [
                (XDP_PGOFF_RX_RING + offsets.rx.desc as i64, "rx ring"),
                (XDP_UMEM_PGOFF_FILL_RING + offsets.fr.desc as i64, "fill ring"),
                (XDP_UMEM_PGOFF_COMPLETION_RING + offsets.cr.desc as i64, "completion ring"),
            ] {
                let page = mmap(
                    std::ptr::null_mut(),
                    4096,
                    PROT_READ_WRITE,
                    0x01, // MAP_SHARED
                    fd,
                    off - offsets.rx.desc as i64 * 0, // base pgoff; desc offset applies within
                );
                let _ = what;
                if page.is_null() || page as isize == -1 {
                    close(fd);
                    return Err(last_err("mmap(ring)"));
                }
            }
            let cname = CString::new(iface).unwrap();
            let ifindex = if_nametoindex(cname.as_ptr());
            if ifindex == 0 {
                close(fd);
                return Err(format!("if_nametoindex({iface}): no such interface"));
            }
            let sxdp = SockaddrXdp {
                family: AF_XDP as u16,
                flags: 0,
                ifindex,
                queue_id: queue,
                shared_umem_fd: 0,
            };
            if bind(fd, &sxdp, std::mem::size_of::<SockaddrXdp>() as u32) < 0 {
                let err = last_err("bind(XSK)");
                close(fd);
                return Err(format!(
                    "{err} (expected without CAP_NET_ADMIN / a real driver queue)"
                ));
            }
            close(fd);
            Ok(format!(
                "XSK bound on {iface} queue {queue}: packet path integration is the next step"
            ))
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod xdp {
    pub fn probe(_iface: &str, _queue: u32) -> Result<String, String> {
        Err("AF_XDP is Linux-only".to_string())
    }
}

fn udp_baseline(seconds: u64) -> io::Result<String> {
    let receiver = UdpSocket::bind("127.0.0.1:0")?;
    let addr = receiver.local_addr()?;
    receiver.set_read_timeout(Some(Duration::from_millis(200)))?;
    let received = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));
    let recv_thread = {
        let received = received.clone();
        let stop = stop.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            while !stop.load(Ordering::Relaxed) {
                if let Ok((n, _)) = receiver.recv_from(&mut buf) {
                    let _ = n;
                    received.fetch_add(1, Ordering::Relaxed);
                }
            }
        })
    };
    let sender = UdpSocket::bind("127.0.0.1:0")?;
    let payload = [0xabu8; 200]; // STUN/DTLS-sized datagram
    let start = Instant::now();
    let mut sent = 0u64;
    while start.elapsed() < Duration::from_secs(seconds) {
        sender.send_to(&payload, addr)?;
        sent += 1;
    }
    let elapsed = start.elapsed().as_secs_f64();
    stop.store(true, Ordering::Relaxed);
    let _ = recv_thread.join();
    let got = received.load(Ordering::Relaxed);
    Ok(format!(
        "UDP baseline (loopback, 200B datagrams): sent {sent} ({:.0}/s), received {got} ({:.0}/s) over {elapsed:.1}s",
        sent as f64 / elapsed,
        got as f64 / elapsed
    ))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let iface = args.get(1).map(String::as_str).unwrap_or("lo");
    let queue: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);
    let seconds: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(3);

    match udp_baseline(seconds) {
        Ok(line) => println!("{line}"),
        Err(e) => println!("UDP baseline failed: {e}"),
    }
    match xdp::probe(iface, queue) {
        Ok(line) => println!("XDP probe: {line}"),
        Err(e) => println!("XDP probe stopped: {e}"),
    }
    println!(
        "verdict so far: unmeasured on a real NIC queue; DTLS/SCTP costs are expected to \
         dominate at gRPC rates, so XDP stays opt-in spike code, never the default path"
    );
    let _ = io::Write::flush(&mut io::stdout());
}
