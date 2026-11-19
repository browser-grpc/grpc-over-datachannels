//! C ABI over the dc-webrtc DTLS handshake and established
//! core (see include/grpcdc_dtls.h). Sans-io pump, the
//! SCTP FFI shape: framed packet buffers, outputs stashed
//! in the handle on too-small (-2) for drain re-reads,
//! panics contained at the boundary.

use dc_webrtc::dtls::{DtlsConfig, DtlsHandshake, DtlsSession};
use dc_webrtc::p256::PrivateKey;
use dc_webrtc::x509::Certificate;
use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};

pub struct GrpcdcDtls {
    machine: DtlsHandshake,
    initial: Vec<Vec<u8>>,
    last_out: Vec<u8>,
}

pub struct GrpcdcDtlsSession(DtlsSession);

const ERR_NULL: i64 = -1;
const ERR_SMALL: i64 = -2;
const ERR_NO_DATA: i64 = -3;
const ERR_PANIC: i64 = -100;
const ERR_CRYPTO: i64 = -4;

fn guard_i64(f: impl FnOnce() -> i64) -> i64 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(ERR_PANIC)
}

fn frame_packets(packets: &[Vec<u8>]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(packets.iter().map(|p| 4 + p.len()).sum());
    for p in packets {
        buf.extend_from_slice(&(p.len() as u32).to_be_bytes());
        buf.extend_from_slice(p);
    }
    buf
}

fn copy_framed(framed: &[u8], out: *mut u8, cap: usize) -> i64 {
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

#[repr(C)]
pub struct GrpcdcDtlsConfig {
    pub cert_der: *const u8,
    pub cert_der_len: usize,
    pub key_scalar: *const u8,
    pub expected_fingerprint: *const c_char,
    pub require_peer_certificate: u8,
    pub session_resumption: u8,
    pub ticket_key: *const u8,
    pub connection_id: *const u8,
    pub connection_id_len: usize,
    pub pair_hint: *const u8,
    pub pair_hint_len: usize,
}

fn bytes(ptr: *const u8, len: usize) -> Option<Vec<u8>> {
    if ptr.is_null() || len == 0 {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec())
}

fn build_config(cfg: &GrpcdcDtlsConfig) -> Option<DtlsConfig> {
    let der = bytes(cfg.cert_der, cfg.cert_der_len)?;
    let scalar: [u8; 32] = bytes(cfg.key_scalar, 32)?.try_into().ok()?;
    let private = PrivateKey::from_bytes(&scalar)?;
    let public = private.public_key();
    let expected_fingerprint = if cfg.expected_fingerprint.is_null() {
        None
    } else {
        Some(
            unsafe { CStr::from_ptr(cfg.expected_fingerprint) }
                .to_string_lossy()
                .into_owned(),
        )
    };
    let ticket_key: Option<[u8; 32]> = if cfg.ticket_key.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(cfg.ticket_key, 32) }.try_into().ok()?)
    };
    Some(DtlsConfig {
        certificate: Certificate {
            der,
            private,
            public,
        },
        expected_peer_fingerprint: expected_fingerprint,
        require_peer_certificate: cfg.require_peer_certificate != 0,
        session_resumption: cfg.session_resumption != 0,
        session_ticket_key: ticket_key,
        connection_id: bytes(cfg.connection_id, cfg.connection_id_len),
        pair_hint: bytes(cfg.pair_hint, cfg.pair_hint_len),
    })
}

macro_rules! handle {
    ($h:expr) => {
        match unsafe { ($h as *mut GrpcdcDtls).as_mut() } {
            Some(w) => w,
            None => return ERR_NULL,
        }
    };
}

fn make(
    cfg: *const GrpcdcDtlsConfig,
    resume: *const GrpcdcDtlsSession,
    now_ms: u64,
    server: bool,
) -> *mut GrpcdcDtls {
    let Some(cfg) = (if cfg.is_null() {
        None
    } else {
        build_config(unsafe { &*cfg })
    }) else {
        return std::ptr::null_mut();
    };
    let result = if server {
        Ok((
            DtlsHandshake::new_server(&cfg, now_ms),
            Vec::new(),
        ))
    } else {
        let session = if resume.is_null() {
            None
        } else {
            Some(unsafe { &(*resume).0 })
        };
        DtlsHandshake::new_client(&cfg, session, now_ms)
            .map(|(m, flight)| (m, flight))
    };
    match result {
        Ok((machine, initial)) => Box::into_raw(Box::new(GrpcdcDtls {
            machine,
            initial,
            last_out: Vec::new(),
        })),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_new_client(
    cfg: *const GrpcdcDtlsConfig,
    resume: *const GrpcdcDtlsSession,
    now_ms: u64,
) -> *mut GrpcdcDtls {
    catch_unwind(AssertUnwindSafe(|| make(cfg, resume, now_ms, false)))
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_new_server(
    cfg: *const GrpcdcDtlsConfig,
    now_ms: u64,
) -> *mut GrpcdcDtls {
    catch_unwind(AssertUnwindSafe(|| {
        make(cfg, std::ptr::null(), now_ms, true)
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_free(h: *mut GrpcdcDtls) {
    if !h.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(h));
        }));
    }
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_start(h: *mut GrpcdcDtls, out: *mut u8, cap: usize) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        w.last_out = frame_packets(&w.initial);
        copy_framed(&w.last_out.clone(), out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_handle_datagram(
    h: *mut GrpcdcDtls,
    packet: *const u8,
    len: usize,
    now_ms: u64,
    out: *mut u8,
    cap: usize,
) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        if packet.is_null() {
            return ERR_NULL;
        }
        let bytes = unsafe { std::slice::from_raw_parts(packet, len) };
        let packets = w.machine.handle_datagram(bytes, now_ms);
        w.last_out = frame_packets(&packets);
        let framed = w.last_out.clone();
        copy_framed(&framed, out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_tick(
    h: *mut GrpcdcDtls,
    now_ms: u64,
    out: *mut u8,
    cap: usize,
) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        let packets = w.machine.tick(now_ms);
        w.last_out = frame_packets(&packets);
        let framed = w.last_out.clone();
        copy_framed(&framed, out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_drain(h: *mut GrpcdcDtls, out: *mut u8, cap: usize) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        let framed = w.last_out.clone();
        copy_framed(&framed, out, cap)
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_next_timeout(h: *const GrpcdcDtls, now_ms: u64) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcDtls).as_ref() } {
            Some(w) => w.machine.next_timeout(now_ms).map(|v| v as i64).unwrap_or(-1),
            None => -1,
        }
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_is_established(h: *const GrpcdcDtls) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcDtls).as_ref() } {
            Some(w) => w.machine.established() as i32,
            None => 0,
        }
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_was_resumed(h: *const GrpcdcDtls) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        match unsafe { (h as *const GrpcdcDtls).as_ref() } {
            Some(w) => w.machine.was_resumed() as i32,
            None => 0,
        }
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_failure(h: *const GrpcdcDtls, buf: *mut c_char, cap: usize) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        let w = match unsafe { (h as *const GrpcdcDtls).as_ref() } {
            Some(w) => w,
            None => return ERR_NULL,
        };
        let Some(failure) = w.machine.failure() else {
            return 0;
        };
        if buf.is_null() || cap == 0 {
            return failure.len() as i64;
        }
        let n = failure.len().min(cap - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(failure.as_ptr(), buf as *mut u8, n);
            *buf.add(n) = 0;
        }
        failure.len() as i64
    }))
    .unwrap_or(ERR_PANIC)
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_encrypt_app(
    h: *mut GrpcdcDtls,
    data: *const u8,
    len: usize,
    out: *mut u8,
    cap: usize,
) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        if data.is_null() && len > 0 {
            return ERR_NULL;
        }
        let bytes: &[u8] = if len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(data, len) }
        };
        match w.machine.encrypt_app(bytes) {
            Some(record) => {
                if record.len() > cap {
                    return ERR_SMALL;
                }
                if out.is_null() {
                    return ERR_NULL;
                }
                let buf = unsafe { std::slice::from_raw_parts_mut(out, cap) };
                buf[..record.len()].copy_from_slice(&record);
                record.len() as i64
            }
            None => ERR_NULL,
        }
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_handle_app(
    h: *mut GrpcdcDtls,
    packet: *const u8,
    len: usize,
    out: *mut u8,
    cap: usize,
) -> i64 {
    guard_i64(|| {
        let w = handle!(h);
        if packet.is_null() {
            return ERR_NULL;
        }
        let bytes = unsafe { std::slice::from_raw_parts(packet, len) };
        match w.machine.handle_app_datagram(bytes) {
            Some(Ok(Some(payload))) => {
                if payload.len() > cap {
                    return ERR_SMALL;
                }
                if out.is_null() {
                    return ERR_NULL;
                }
                let buf = unsafe { std::slice::from_raw_parts_mut(out, cap) };
                buf[..payload.len()].copy_from_slice(&payload);
                payload.len() as i64
            }
            Some(Ok(None)) => ERR_NO_DATA,
            Some(Err(_)) => ERR_CRYPTO,
            None => ERR_NULL,
        }
    })
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_peer_fingerprint(
    h: *const GrpcdcDtls,
    buf: *mut c_char,
    cap: usize,
) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        let w = match unsafe { (h as *const GrpcdcDtls).as_ref() } {
            Some(w) => w,
            None => return ERR_NULL,
        };
        let Some(fp) = w.machine.peer_fingerprint() else {
            return 0;
        };
        if buf.is_null() || cap == 0 {
            return fp.len() as i64;
        }
        let n = fp.len().min(cap - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(fp.as_ptr(), buf as *mut u8, n);
            *buf.add(n) = 0;
        }
        fp.len() as i64
    }))
    .unwrap_or(ERR_PANIC)
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_take_session(
    h: *mut GrpcdcDtls,
) -> *mut GrpcdcDtlsSession {
    catch_unwind(AssertUnwindSafe(|| {
        let w = match unsafe { (h as *mut GrpcdcDtls).as_mut() } {
            Some(w) => w,
            None => return std::ptr::null_mut(),
        };
        match w.machine.take_session() {
            Some(session) => Box::into_raw(Box::new(GrpcdcDtlsSession(session))),
            None => std::ptr::null_mut(),
        }
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn grpcdc_dtls_session_free(s: *mut GrpcdcDtlsSession) {
    if !s.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(s));
        }));
    }
}
