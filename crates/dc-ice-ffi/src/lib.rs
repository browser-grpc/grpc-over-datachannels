//! C ABI over the dc-webrtc ICE agent (see
//! include/grpcdc_ice.h). The agent is already sans-io;
//! this is the shared-core surface in the SCTP FFI shape:
//! framed (packet, addr) buffers, events, stash-and-drain
//! on too-small, panics contained.

use dc_webrtc::ice::{Candidate, IceAgent, IceEvent};
use std::ffi::{c_char, CStr};
use std::net::SocketAddr;
use std::panic::{catch_unwind, AssertUnwindSafe};

pub struct GrpcdcIce {
    agent: IceAgent,
    last_out: Vec<u8>,
    last_events: Vec<u8>,
}

const ERR_NULL: i64 = -1;
const ERR_SMALL: i64 = -2;
const ERR_PANIC: i64 = -100;

fn guard_i64(f: impl FnOnce() -> i64) -> i64 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(ERR_PANIC)
}

fn frame_pairs(pairs: &[(Vec<u8>, SocketAddr)]) -> Vec<u8> {
    let mut buf = Vec::new();
    for (packet, addr) in pairs {
        let addr = addr.to_string();
        buf.extend_from_slice(&(packet.len() as u32).to_be_bytes());
        buf.extend_from_slice(packet);
        buf.extend_from_slice(&(addr.len() as u16).to_be_bytes());
        buf.extend_from_slice(addr.as_bytes());
    }
    buf
}

fn frame_events(events: &[IceEvent]) -> Vec<u8> {
    let mut buf = Vec::new();
    for ev in events {
        let (kind, addr) = match ev {
            IceEvent::PairValid { remote } => (1u8, remote),
            IceEvent::Nominated { remote } => (2u8, remote),
        };
        let addr = addr.to_string();
        buf.push(kind);
        buf.extend_from_slice(&(addr.len() as u16).to_be_bytes());
        buf.extend_from_slice(addr.as_bytes());
    }
    buf
}

fn copy_out(framed: &[u8], out: *mut u8, cap: usize) -> i64 {
    if framed.len() > cap {
        return ERR_SMALL;
    }
    if !framed.is_empty() {
        if out.is_null() {
            return ERR_NULL;
        }
        let buf = unsafe { std::slice::from_raw_parts_mut(out, cap) };
        buf[..framed.len()].copy_from_slice(framed);
    }
    framed.len() as i64
}

fn copy_str(value: &str, buf: *mut c_char, cap: usize) -> i64 {
    if buf.is_null() || cap == 0 {
        return value.len() as i64;
    }
    let n = value.len().min(cap - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(value.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
    value.len() as i64
}

fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned())
}

macro_rules! handle {
    ($h:expr) => {
        match unsafe { ($h as *mut GrpcdcIce).as_mut() } {
            Some(w) => w,
            None => return ERR_NULL,
        }
    };
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_new(controlling: u8) -> *mut GrpcdcIce {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(GrpcdcIce {
            agent: IceAgent::new(controlling != 0),
            last_out: Vec::new(),
            last_events: Vec::new(),
        }))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_free(h: *mut GrpcdcIce) {
    if !h.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(h));
        }));
    }
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_restart(h: *mut GrpcdcIce) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(w) = unsafe { (h as *mut GrpcdcIce).as_mut() } {
            w.agent.restart();
        }
    }));
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_local_ufrag(h: *const GrpcdcIce, buf: *mut c_char, cap: usize) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcIce).as_ref() } {
            Some(w) => copy_str(&w.agent.local_ufrag, buf, cap),
            None => ERR_NULL,
        }
    }))
    .unwrap_or(ERR_PANIC)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_local_pwd(h: *const GrpcdcIce, buf: *mut c_char, cap: usize) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcIce).as_ref() } {
            Some(w) => copy_str(&w.agent.local_pwd, buf, cap),
            None => ERR_NULL,
        }
    }))
    .unwrap_or(ERR_PANIC)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_add_local_host(h: *mut GrpcdcIce, addr: *const c_char) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let w = match unsafe { (h as *mut GrpcdcIce).as_mut() } {
            Some(w) => w,
            None => return ERR_NULL as i32,
        };
        let Some(addr) = cstr(addr) else {
            return ERR_NULL as i32;
        };
        let Ok(addr) = addr.parse::<SocketAddr>() else {
            return ERR_NULL as i32;
        };
        let foundation = format!("h{}", w.agent.local_candidates.len());
        w.agent
            .local_candidates
            .push(Candidate::host(addr, &foundation));
        0
    }))
    .unwrap_or(ERR_PANIC as i32)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_set_local_credentials(
    h: *mut GrpcdcIce,
    ufrag: *const c_char,
    pwd: *const c_char,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let w = match unsafe { (h as *mut GrpcdcIce).as_mut() } {
            Some(w) => w,
            None => return ERR_NULL as i32,
        };
        let (Some(ufrag), Some(pwd)) = (cstr(ufrag), cstr(pwd)) else {
            return ERR_NULL as i32;
        };
        w.agent.local_ufrag = ufrag;
        w.agent.local_pwd = pwd;
        0
    }))
    .unwrap_or(ERR_PANIC as i32)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_add_local_candidate(
    h: *mut GrpcdcIce,
    sdp_line: *const c_char,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let w = match unsafe { (h as *mut GrpcdcIce).as_mut() } {
            Some(w) => w,
            None => return ERR_NULL as i32,
        };
        let Some(line) = cstr(sdp_line) else {
            return ERR_NULL as i32;
        };
        let line = line.strip_prefix("a=").unwrap_or(&line);
        let Some(cand) = Candidate::from_sdp(line) else {
            return ERR_NULL as i32;
        };
        w.agent.local_candidates.push(cand);
        0
    }))
    .unwrap_or(ERR_PANIC as i32)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_set_controlling(h: *mut GrpcdcIce, controlling: u8) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(w) = unsafe { (h as *mut GrpcdcIce).as_mut() } {
            w.agent.controlling = controlling != 0;
        }
    }));
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_controlling(h: *const GrpcdcIce) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcIce).as_ref() } {
            Some(w) => w.agent.controlling as i32,
            None => 0,
        }
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_generation(h: *const GrpcdcIce) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcIce).as_ref() } {
            Some(w) => w.agent.generation(),
            None => 0,
        }
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_renominated(h: *const GrpcdcIce) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcIce).as_ref() } {
            Some(w) => w.agent.renominated() as i32,
            None => 0,
        }
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_set_remote(
    h: *mut GrpcdcIce,
    ufrag: *const c_char,
    pwd: *const c_char,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let w = match unsafe { (h as *mut GrpcdcIce).as_mut() } {
            Some(w) => w,
            None => return ERR_NULL as i32,
        };
        let (Some(ufrag), Some(pwd)) = (cstr(ufrag), cstr(pwd)) else {
            return ERR_NULL as i32;
        };
        w.agent.set_remote(&ufrag, &pwd, Vec::new());
        0
    }))
    .unwrap_or(ERR_PANIC as i32)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_add_remote_candidate(
    h: *mut GrpcdcIce,
    sdp_line: *const c_char,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let w = match unsafe { (h as *mut GrpcdcIce).as_mut() } {
            Some(w) => w,
            None => return ERR_NULL as i32,
        };
        let Some(line) = cstr(sdp_line) else {
            return ERR_NULL as i32;
        };
        let Some(cand) = Candidate::from_sdp(&line) else {
            return ERR_NULL as i32;
        };
        w.agent.add_remote_candidate(cand) as i32
    }))
    .unwrap_or(ERR_PANIC as i32)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_due_checks(h: *mut GrpcdcIce, out: *mut u8, cap: usize) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        let checks = w.agent.due_checks();
        w.last_out = frame_pairs(&checks);
        let framed = w.last_out.clone();
        copy_out(&framed, out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_handle_stun(
    h: *mut GrpcdcIce,
    packet: *const u8,
    len: usize,
    src: *const c_char,
    out: *mut u8,
    cap: usize,
    out_events: *mut u8,
    events_cap: usize,
    events_len: *mut usize,
) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        if packet.is_null() || events_len.is_null() {
            return ERR_NULL;
        }
        let Some(src) = cstr(src).and_then(|s| s.parse::<SocketAddr>().ok()) else {
            return ERR_NULL;
        };
        let bytes = unsafe { std::slice::from_raw_parts(packet, len) };
        let (responses, events) = w.agent.handle_stun(bytes, src);
        w.last_out = frame_pairs(&responses);
        w.last_events = frame_events(&events);
        if w.last_events.len() > events_cap {
            return ERR_SMALL;
        }
        if !w.last_events.is_empty() {
            if out_events.is_null() {
                return ERR_NULL;
            }
            let buf = unsafe { std::slice::from_raw_parts_mut(out_events, events_cap) };
            buf[..w.last_events.len()].copy_from_slice(&w.last_events.clone());
        }
        unsafe { *events_len = w.last_events.len() };
        let framed = w.last_out.clone();
        copy_out(&framed, out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_drain(h: *mut GrpcdcIce, out: *mut u8, cap: usize) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        let framed = w.last_out.clone();
        copy_out(&framed, out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_consent_check(h: *mut GrpcdcIce, out: *mut u8, cap: usize) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        let pairs: Vec<(Vec<u8>, SocketAddr)> = w.agent.consent_check().into_iter().collect();
        w.last_out = frame_pairs(&pairs);
        let framed = w.last_out.clone();
        copy_out(&framed, out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_touch_consent(h: *mut GrpcdcIce) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(w) = unsafe { (h as *mut GrpcdcIce).as_mut() } {
            w.agent.touch_consent();
        }
    }));
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_consent_expired(h: *const GrpcdcIce, expiry_ms: u64) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcIce).as_ref() } {
            Some(w) => {
                w.agent
                    .consent_expired(std::time::Duration::from_millis(expiry_ms))
                    as i32
            }
            None => 0,
        }
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn grpcdc_ice_nominated(h: *const GrpcdcIce, buf: *mut c_char, cap: usize) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcIce).as_ref() } {
            Some(w) => match w.agent.nominated {
                Some(addr) => copy_str(&addr.to_string(), buf, cap),
                None => 0,
            },
            None => ERR_NULL,
        }
    }))
    .unwrap_or(ERR_PANIC)
}
