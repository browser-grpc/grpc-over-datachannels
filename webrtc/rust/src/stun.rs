//! STUN (RFC 8489) Binding messages with short-term credentials:
//! MESSAGE-INTEGRITY (HMAC-SHA1) and FINGERPRINT (CRC-32), plus
//! XOR-MAPPED-ADDRESS — exactly what ICE connectivity checks need.

use alloc::string::String;
use alloc::vec::Vec;
use crate::crypto::{crc32, hmac_sha1, random_bytes};
use crate::proto_gen::{stun_attr, stun_msg};
use core::net::{IpAddr, Ipv4Addr, SocketAddr};

pub const MAGIC: u32 = 0x2112_A442;

#[derive(Clone, Debug)]
pub struct Message {
    pub msg_type: u16,
    pub transaction_id: [u8; 12],
    pub attrs: Vec<(u16, Vec<u8>)>,
}

impl Message {
    pub fn new(msg_type: u16) -> Self {
        Self {
            msg_type,
            transaction_id: random_bytes(12).try_into().unwrap(),
            attrs: Vec::new(),
        }
    }

    pub fn attr(&self, ty: u16) -> Option<&[u8]> {
        self.attrs.iter().find(|(t, _)| *t == ty).map(|(_, v)| v.as_slice())
    }

    /// Serialize. `integrity_key` (ICE password) adds MESSAGE-INTEGRITY
    /// then FINGERPRINT, in that order, per RFC 8489.
    pub fn encode(&self, integrity_key: Option<&[u8]>) -> Vec<u8> {
        let mut body = Vec::new();
        for (ty, value) in &self.attrs {
            if *ty == stun_attr::MESSAGE_INTEGRITY || *ty == stun_attr::FINGERPRINT {
                continue; // recomputed below, always last
            }
            body.extend_from_slice(&ty.to_be_bytes());
            body.extend_from_slice(&(value.len() as u16).to_be_bytes());
            body.extend_from_slice(value);
            while body.len() % 4 != 0 {
                body.push(0);
            }
        }
        let mut out = Vec::new();
        out.extend_from_slice(&self.msg_type.to_be_bytes());
        let total_len = body.len() + if integrity_key.is_some() { 24 + 8 } else { 0 };
        out.extend_from_slice(&(total_len as u16).to_be_bytes());
        out.extend_from_slice(&MAGIC.to_be_bytes());
        out.extend_from_slice(&self.transaction_id);
        out.extend_from_slice(&body);
        if let Some(key) = integrity_key {
            // MESSAGE-INTEGRITY (RFC 8489 §14.5): the header length is
            // first adjusted to count everything through the end of the
            // MI attribute (but not FINGERPRINT), then HMACed.
            let through_mi = (out.len() - 20 + 24) as u16;
            out[2..4].copy_from_slice(&through_mi.to_be_bytes());
            let mac = hmac_sha1(key, &[&out]);
            out.extend_from_slice(&stun_attr::MESSAGE_INTEGRITY.to_be_bytes());
            out.extend_from_slice(&20u16.to_be_bytes());
            out.extend_from_slice(&mac);
            // FINGERPRINT (§14.7): CRC over everything before it, with
            // the header length already set to the final value that
            // includes the FP attribute itself.
            let final_len = (out.len() - 20 + 8) as u16;
            out[2..4].copy_from_slice(&final_len.to_be_bytes());
            let crc = crc32(&out) ^ 0x5354_554E;
            out.extend_from_slice(&stun_attr::FINGERPRINT.to_be_bytes());
            out.extend_from_slice(&4u16.to_be_bytes());
            out.extend_from_slice(&crc.to_be_bytes());
        }
        out
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() < 20 {
            return None;
        }
        if u32::from_be_bytes(data[4..8].try_into().ok()?) != MAGIC {
            return None;
        }
        let msg_type = u16::from_be_bytes(data[0..2].try_into().ok()?);
        let len = u16::from_be_bytes(data[2..4].try_into().ok()?) as usize;
        if 20 + len > data.len() {
            return None;
        }
        let mut attrs = Vec::new();
        let mut pos = 20;
        let end = 20 + len;
        while pos + 4 <= end {
            let ty = u16::from_be_bytes(data[pos..pos + 2].try_into().ok()?);
            let alen = u16::from_be_bytes(data[pos + 2..pos + 4].try_into().ok()?) as usize;
            if pos + 4 + alen > end {
                break;
            }
            attrs.push((ty, data[pos + 4..pos + 4 + alen].to_vec()));
            pos += 4 + ((alen + 3) & !3);
        }
        Some(Self {
            msg_type,
            transaction_id: data[8..20].try_into().ok()?,
            attrs,
        })
    }

    /// Verify MESSAGE-INTEGRITY against the raw packet and key.
    pub fn check_integrity(&self, raw: &[u8], key: &[u8]) -> bool {
        // Find the MI attribute offset in the raw packet.
        let Some(mi_value) = self.attr(stun_attr::MESSAGE_INTEGRITY) else {
            return false;
        };
        let mut pos = 20;
        let end = raw.len();
        while pos + 4 <= end {
            let ty = u16::from_be_bytes(raw[pos..pos + 2].try_into().unwrap());
            let alen = u16::from_be_bytes(raw[pos + 2..pos + 4].try_into().unwrap()) as usize;
            if ty == stun_attr::MESSAGE_INTEGRITY {
                let mut prefix = raw[..pos].to_vec();
                // Length field must count everything through the end of
                // the MI attribute (header-relative).
                let through_mi = (pos - 20) + 24;
                prefix[2..4].copy_from_slice(&(through_mi as u16).to_be_bytes());
                return hmac_sha1(key, &[&prefix])[..] == mi_value[..];
            }
            pos += 4 + ((alen + 3) & !3);
        }
        false
    }

    pub fn is_binding_request(&self) -> bool {
        self.msg_type == stun_msg::BINDING_REQUEST
    }
}

/// Normalize an IPv4-mapped IPv6 address to plain IPv4 (dual-
/// stack sockets report IPv4 senders in mapped form).
pub fn normalize_ip(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => ip,
        },
        IpAddr::V4(_) => ip,
    }
}

pub fn normalize_addr(addr: SocketAddr) -> SocketAddr {
    SocketAddr::new(normalize_ip(addr.ip()), addr.port())
}

fn xor_mask(transaction_id: &[u8; 12], length: usize) -> Vec<u8> {
    let mut mask = Vec::with_capacity(length);
    mask.extend_from_slice(&MAGIC.to_be_bytes());
    if length > 4 {
        mask.extend_from_slice(&transaction_id[..length - 4]);
    }
    mask
}

/// Encode an XOR-*ADDRESS value (RFC 5389 section 15.2): the
/// IPv6 mask is the magic cookie concatenated with the
/// transaction ID. IPv4-mapped addresses encode as IPv4.
pub fn xor_mapped_address(addr: &SocketAddr, transaction_id: &[u8; 12]) -> Vec<u8> {
    let ip = normalize_ip(addr.ip());
    let (family, bytes): (u8, Vec<u8>) = match ip {
        IpAddr::V4(v4) => (1, v4.octets().to_vec()),
        IpAddr::V6(v6) => (2, v6.octets().to_vec()),
    };
    let mut out = vec![0u8, family];
    let xport = addr.port() ^ (MAGIC >> 16) as u16;
    out.extend_from_slice(&xport.to_be_bytes());
    let mask = xor_mask(transaction_id, bytes.len());
    out.extend(bytes.iter().zip(&mask).map(|(b, m)| b ^ m));
    out
}

pub fn decode_xor_mapped(value: &[u8], transaction_id: &[u8; 12]) -> Option<SocketAddr> {
    if value.len() < 4 {
        return None;
    }
    let ip_len = match value[1] {
        1 => 4usize,
        2 => 16usize,
        _ => return None,
    };
    if value.len() < 4 + ip_len {
        return None;
    }
    let port = u16::from_be_bytes(value[2..4].try_into().ok()?) ^ (MAGIC >> 16) as u16;
    let mask = xor_mask(transaction_id, ip_len);
    let bytes: Vec<u8> = value[4..4 + ip_len]
        .iter()
        .zip(&mask)
        .map(|(b, m)| b ^ m)
        .collect();
    let ip: IpAddr = if ip_len == 4 {
        IpAddr::V4(Ipv4Addr::from(<[u8; 4]>::try_from(bytes.as_slice()).ok()?))
    } else {
        IpAddr::V6(core::net::Ipv6Addr::from(<[u8; 16]>::try_from(bytes.as_slice()).ok()?))
    };
    Some(SocketAddr::new(normalize_ip(ip), port))
}

/// Candidate priority per RFC 8445 §5.1.2:
/// (2^24)*typePreference + (2^8)*localPreference + (256-component).
/// Host uses type preference 126, srflx 100.
pub fn candidate_priority(type_preference: u32, component: u16) -> u32 {
    (type_preference << 24) + (65535u32 << 8) + (256 - component as u32)
}

pub fn host_priority(component: u16) -> u32 {
    candidate_priority(126, component)
}

/// Pair priority (RFC 8445 §6.1.2.3): G = controlling's priority.
pub fn pair_priority(controlling_prio: u32, controlled_prio: u32, we_control: bool) -> u64 {
    let (g, d) = if we_control {
        (controlling_prio, controlled_prio)
    } else {
        (controlled_prio, controlling_prio)
    };
    let (min, max) = (g.min(d) as u64, g.max(d) as u64);
    (1u64 << 32) * min + 2 * max + if g > d { 1 } else { 0 }
}

const ICE_ALPHABET: &[u8; 64] =
    b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/";

fn random_ice_string(n_bytes: usize) -> String {
    random_bytes(n_bytes)
        .iter()
        .map(|b| ICE_ALPHABET[(b % 64) as usize] as char)
        .collect()
}

pub fn random_ufrag() -> String {
    random_ice_string(6)
}

pub fn random_password() -> String {
    // RFC 8445: ice-pwd must be 22..=256 characters (browsers enforce).
    random_ice_string(24)
}

pub fn fingerprint_ok(raw: &[u8]) -> bool {
    // Last attribute should be FINGERPRINT; verify CRC over the rest.
    if raw.len() < 28 {
        return false;
    }
    let len = u16::from_be_bytes(raw[2..4].try_into().unwrap()) as usize;
    let end = 20 + len;
    if end > raw.len() {
        return false;
    }
    let fp_pos = end - 8;
    if u16::from_be_bytes(raw[fp_pos..fp_pos + 2].try_into().unwrap()) != stun_attr::FINGERPRINT {
        return false;
    }
    let expected = u32::from_be_bytes(raw[fp_pos + 4..fp_pos + 8].try_into().unwrap());
    // CRC input: everything before the FP attribute, with the header
    // length adjusted to exclude the FP attribute itself.
    let mut input = raw[..fp_pos].to_vec();
    input[2..4].copy_from_slice(&((fp_pos - 20) as u16).to_be_bytes());
    crc32(&input) ^ 0x5354_554E == expected
}

pub fn binding_success(request: &Message, peer_addr: &SocketAddr, key: &[u8]) -> Vec<u8> {
    let mut resp = Message {
        msg_type: stun_msg::BINDING_SUCCESS,
        transaction_id: request.transaction_id,
        attrs: vec![(stun_attr::XOR_MAPPED_ADDRESS, xor_mapped_address(peer_addr, &request.transaction_id))],
    };
    resp.attrs.push((stun_attr::SOFTWARE, b"dc-webrtc".to_vec()));
    resp.encode(Some(key))
}

pub fn binding_error(request: &Message, code: u16, reason: &str, key: Option<&[u8]>) -> Vec<u8> {
    let mut value = vec![0u8, 0, (code / 100) as u8, (code % 100) as u8];
    value.extend_from_slice(reason.as_bytes());
    let resp = Message {
        msg_type: stun_msg::BINDING_ERROR,
        transaction_id: request.transaction_id,
        attrs: vec![(stun_attr::ERROR_CODE, value)],
    };
    resp.encode(key)
}
