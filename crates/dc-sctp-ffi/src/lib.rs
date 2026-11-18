//! C ABI over the dc-webrtc SCTP association (see
//! include/grpcdc_sctp.h for the contract). The association
//! stays a sans-io state machine; hosts pump datagrams.
//! Panics are contained at the boundary (-100), never unwind
//! into the host.

use dc_webrtc::sctp::{Association, Event, SendOptions};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};

pub struct GrpcdcSctp(Association);

const ERR_NULL: i64 = -1;
const ERR_SMALL: i64 = -2;
const ERR_PANIC: i64 = -100;

fn guard_i64(f: impl FnOnce() -> i64) -> i64 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(ERR_PANIC)
}

fn guard_ptr(f: impl FnOnce() -> *mut GrpcdcSctp) -> *mut GrpcdcSctp {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(std::ptr::null_mut())
}

/// Serialize packets as [u32 BE len][bytes]... into `out`.
/// Returns bytes written, or ERR_SMALL (nothing written).
fn write_packets(packets: &[Vec<u8>], out: *mut u8, cap: usize) -> i64 {
    if out.is_null() && cap > 0 {
        return ERR_NULL;
    }
    let need: usize = packets.iter().map(|p| 4 + p.len()).sum();
    if need > cap {
        return ERR_SMALL;
    }
    let buf = unsafe { std::slice::from_raw_parts_mut(out, cap) };
    let mut pos = 0;
    for p in packets {
        buf[pos..pos + 4].copy_from_slice(&(p.len() as u32).to_be_bytes());
        pos += 4;
        buf[pos..pos + p.len()].copy_from_slice(p);
        pos += p.len();
    }
    pos as i64
}

fn write_events(events: &[Event], out: *mut u8, cap: usize) -> i64 {
    if out.is_null() && cap > 0 {
        return ERR_NULL;
    }
    let need: usize = events
        .iter()
        .map(|e| {
            11 + match e {
                Event::Data { payload, .. } => payload.len(),
                _ => 0,
            }
        })
        .sum();
    if need > cap {
        return ERR_SMALL;
    }
    let buf = unsafe { std::slice::from_raw_parts_mut(out, cap) };
    let mut pos = 0;
    for e in events {
        let (kind, stream, ppid, payload): (u8, u16, u32, &[u8]) = match e {
            Event::Connected => (1, 0, 0, &[]),
            Event::Data {
                stream,
                ppid,
                payload,
            } => (2, *stream, *ppid, payload),
            Event::StreamReset { stream } => (3, *stream, 0, &[]),
            Event::Closed => (4, 0, 0, &[]),
        };
        buf[pos] = kind;
        buf[pos + 1..pos + 3].copy_from_slice(&stream.to_be_bytes());
        buf[pos + 3..pos + 7].copy_from_slice(&ppid.to_be_bytes());
        buf[pos + 7..pos + 11].copy_from_slice(&(payload.len() as u32).to_be_bytes());
        pos += 11;
        buf[pos..pos + payload.len()].copy_from_slice(payload);
        pos += payload.len();
    }
    pos as i64
}

macro_rules! handle {
    ($h:expr) => {
        match unsafe { ($h as *mut GrpcdcSctp).as_mut() } {
            Some(w) => &mut w.0,
            None => return ERR_NULL,
        }
    };
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_new_client(local_port: u16, peer_port: u16) -> *mut GrpcdcSctp {
    guard_ptr(|| Box::into_raw(Box::new(GrpcdcSctp(Association::new_client(local_port, peer_port)))))
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_new_server(local_port: u16, peer_port: u16) -> *mut GrpcdcSctp {
    guard_ptr(|| Box::into_raw(Box::new(GrpcdcSctp(Association::new_server(local_port, peer_port)))))
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_free(h: *mut GrpcdcSctp) {
    if !h.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(h));
        }));
    }
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_is_established(h: *const GrpcdcSctp) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcSctp).as_ref() } {
            Some(w) => w.0.is_established() as i32,
            None => 0,
        }
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_connect(
    h: *mut GrpcdcSctp,
    now_ms: u64,
    out: *mut u8,
    cap: usize,
) -> i64 {
    guard_i64(|| {
        let assoc = handle!(h);
        if out.is_null() {
            return ERR_NULL;
        }
        let packet = assoc.connect(now_ms);
        if packet.len() > cap {
            return ERR_SMALL;
        }
        let buf = unsafe { std::slice::from_raw_parts_mut(out, cap) };
        buf[..packet.len()].copy_from_slice(&packet);
        packet.len() as i64
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_send_data(
    h: *mut GrpcdcSctp,
    stream: u16,
    ppid: u32,
    data: *const u8,
    len: usize,
    unordered: u8,
    max_retransmits: i32,
    max_lifetime_ms: i64,
    now_ms: u64,
    out: *mut u8,
    cap: usize,
) -> i64 {
    guard_i64(|| {
        let assoc = handle!(h);
        if data.is_null() && len > 0 {
            return ERR_NULL;
        }
        let payload: &[u8] = if len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(data, len) }
        };
        let opts = SendOptions {
            unordered: unordered != 0,
            max_retransmits: if max_retransmits < 0 {
                None
            } else {
                Some(max_retransmits as u32)
            },
            max_lifetime_ms: if max_lifetime_ms < 0 {
                None
            } else {
                Some(max_lifetime_ms as u64)
            },
        };
        let packets = assoc.send_data(stream, ppid, payload, opts, now_ms);
        write_packets(&packets, out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_handle_packet(
    h: *mut GrpcdcSctp,
    packet: *const u8,
    len: usize,
    now_ms: u64,
    out_packets: *mut u8,
    packets_cap: usize,
    out_events: *mut u8,
    events_cap: usize,
    events_len: *mut usize,
) -> i64 {
    guard_i64(|| {
        let assoc = handle!(h);
        if packet.is_null() || events_len.is_null() {
            return ERR_NULL;
        }
        let bytes = unsafe { std::slice::from_raw_parts(packet, len) };
        let (packets, events) = assoc.handle_packet(bytes, now_ms);
        let ev = write_events(&events, out_events, events_cap);
        if ev < 0 {
            return ev;
        }
        unsafe { *events_len = ev as usize };
        write_packets(&packets, out_packets, packets_cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_tick(
    h: *mut GrpcdcSctp,
    now_ms: u64,
    out_packets: *mut u8,
    packets_cap: usize,
    out_events: *mut u8,
    events_cap: usize,
    events_len: *mut usize,
) -> i64 {
    guard_i64(|| {
        let assoc = handle!(h);
        if events_len.is_null() {
            return ERR_NULL;
        }
        let (packets, events) = assoc.tick(now_ms);
        let ev = write_events(&events, out_events, events_cap);
        if ev < 0 {
            return ev;
        }
        unsafe { *events_len = ev as usize };
        write_packets(&packets, out_packets, packets_cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_stats(h: *const GrpcdcSctp, out7: *mut u64) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let w = match unsafe { (h as *const GrpcdcSctp).as_ref() } {
            Some(w) => w,
            None => return -1,
        };
        if out7.is_null() {
            return -1;
        }
        let s = w.0.stats();
        let vals = [
            s.packets_sent,
            s.packets_received,
            s.chunks_sent,
            s.chunks_received,
            s.retransmits,
            s.fast_retransmits,
            s.dup_chunks,
        ];
        unsafe { std::slice::from_raw_parts_mut(out7, 7) }.copy_from_slice(&vals);
        0
    }))
    .unwrap_or(ERR_PANIC as i32)
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_close_stream(
    h: *mut GrpcdcSctp,
    stream: u16,
    out: *mut u8,
    cap: usize,
) -> i64 {
    guard_i64(|| {
        let assoc = handle!(h);
        let packets = assoc.close_stream(stream);
        write_packets(&packets, out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_sctp_close(
    h: *mut GrpcdcSctp,
    now_ms: u64,
    out: *mut u8,
    cap: usize,
) -> i64 {
    guard_i64(|| {
        let assoc = handle!(h);
        let packets = assoc.close(now_ms);
        write_packets(&packets, out, cap)
    })
}

// Keep c_void referenced for future callback-based APIs.
#[allow(dead_code)]
fn _assert_c_void(_: *const c_void) {}
