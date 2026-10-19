//! Minimal X.509 (RFC 5280) support: generate self-signed ECDSA P-256
//! certificates as DER, and parse a peer certificate far enough to
//! extract its EC public key. Certificate signatures are NOT verified:
//! WebRTC pins certificates by their SHA-256 fingerprint in SDP, which
//! is what `fingerprint` provides.

use alloc::string::String;
use alloc::vec::Vec;
use crate::crypto::sha256;
use crate::p256::{PrivateKey, PublicKey};

fn der_len(len: usize) -> Vec<u8> {
    if len < 128 {
        vec![len as u8]
    } else {
        let bytes = len.to_be_bytes();
        let first = bytes.iter().position(|&b| b != 0).unwrap_or(7);
        let mut out = vec![0x80 | (8 - first) as u8];
        out.extend_from_slice(&bytes[first..]);
        out
    }
}

fn tlv(tag: u8, content: &[u8]) -> Vec<u8> {
    let mut out = vec![tag];
    out.extend_from_slice(&der_len(content.len()));
    out.extend_from_slice(content);
    out
}

fn seq(parts: &[u8]) -> Vec<u8> {
    tlv(0x30, parts)
}

fn der_int(bytes_be: &[u8]) -> Vec<u8> {
    let mut v = bytes_be;
    while v.len() > 1 && v[0] == 0 {
        v = &v[1..];
    }
    let mut content = Vec::new();
    if v.first().map_or(false, |b| b & 0x80 != 0) {
        content.push(0);
    }
    content.extend_from_slice(v);
    tlv(0x02, &content)
}

fn der_oid(arcs: &[u32]) -> Vec<u8> {
    let mut content = vec![(arcs[0] * 40 + arcs[1]) as u8];
    for &arc in &arcs[2..] {
        let mut encoded = vec![(arc & 0x7f) as u8];
        let mut rest = arc >> 7;
        while rest > 0 {
            encoded.push(((rest & 0x7f) as u8) | 0x80);
            rest >>= 7;
        }
        encoded.reverse();
        // fix continuation bits: all but last get 0x80
        let n = encoded.len();
        for i in 0..n - 1 {
            encoded[i] |= 0x80;
        }
        if n > 1 {
            // The first byte produced above already carries the low bits;
            // recompute cleanly below instead.
        }
        let mut clean = Vec::new();
        let mut rest = arc;
        let mut groups = vec![(rest & 0x7f) as u8];
        rest >>= 7;
        while rest > 0 {
            groups.push(((rest & 0x7f) as u8) | 0x80);
            rest >>= 7;
        }
        groups.reverse();
        clean.extend_from_slice(&groups);
        content.extend_from_slice(&clean);
        let _ = encoded;
    }
    tlv(0x06, &content)
}

fn alg_ecdsa_sha256() -> Vec<u8> {
    seq(&der_oid(&[1, 2, 840, 10045, 4, 3, 2]))
}

fn name(cn: &str) -> Vec<u8> {
    let rdn = seq(&{
        let mut v = der_oid(&[2, 5, 4, 3]);
        v.extend_from_slice(&tlv(0x0C, cn.as_bytes())); // UTF8String
        v
    });
    seq(&tlv(0x31, &rdn))
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    // Howard Hinnant's civil_from_days algorithm.
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn utc_time(epoch_secs: u64) -> Vec<u8> {
    let days = (epoch_secs / 86_400) as i64;
    let rem = epoch_secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    let text = format!(
        "{:02}{:02}{:02}{:02}{:02}{:02}Z",
        y % 100,
        m,
        d,
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    );
    tlv(0x17, text.as_bytes())
}

#[derive(Clone)]
pub struct Certificate {
    pub der: Vec<u8>,
    pub private: PrivateKey,
    pub public: PublicKey,
}

impl Certificate {
    pub fn generate_self_signed(cn: &str) -> Self {
        let (private, public) = PrivateKey::generate();
        let serial = crate::crypto::random_bytes(16);
        let now = crate::platform::wall_now_secs();
        let spki = {
            let alg = {
                let mut v = der_oid(&[1, 2, 840, 10045, 2, 1]);
                v.extend_from_slice(&der_oid(&[1, 2, 840, 10045, 3, 1, 7]));
                seq(&v)
            };
            let mut bitstring = vec![0u8];
            bitstring.extend_from_slice(&public.encode_uncompressed());
            let mut spki_body = alg;
            spki_body.extend_from_slice(&tlv(0x03, &bitstring));
            seq(&spki_body)
        };
        let tbs = {
            let mut body = Vec::new();
            body.extend_from_slice(&tlv(0xA0, &der_int(&[2]))); // version v3
            body.extend_from_slice(&der_int(&serial));
            body.extend_from_slice(&alg_ecdsa_sha256());
            body.extend_from_slice(&name(cn));
            let mut validity = utc_time(now.saturating_sub(86_400));
            validity.extend_from_slice(&utc_time(now + 30 * 86_400));
            body.extend_from_slice(&seq(&validity));
            body.extend_from_slice(&name(cn));
            body.extend_from_slice(&spki);
            seq(&body)
        };
        let digest = sha256(&tbs);
        let (r, s) = private.sign(&digest);
        let signature = {
            let mut sig_seq_body = der_int(&r);
            sig_seq_body.extend_from_slice(&der_int(&s));
            let sig_der = seq(&sig_seq_body);
            let mut bitstring = vec![0u8];
            bitstring.extend_from_slice(&sig_der);
            tlv(0x03, &bitstring)
        };
        let mut cert_body = tbs;
        cert_body.extend_from_slice(&alg_ecdsa_sha256());
        cert_body.extend_from_slice(&signature);
        let der = seq(&cert_body);
        Self { der, private, public }
    }

    /// SDP form: uppercase hex bytes separated by colons.
    pub fn fingerprint(&self) -> String {
        fingerprint_of_der(&self.der)
    }
}

pub fn fingerprint_of_der(der: &[u8]) -> String {
    sha256(der)
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(":")
}

// ---------------------------------------------------------------------------
// DER parsing (public key extraction only)
// ---------------------------------------------------------------------------

struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    /// Returns (tag, content) of the next TLV.
    fn read(&mut self) -> Option<(u8, &'a [u8])> {
        let tag = *self.data.get(self.pos)?;
        self.pos += 1;
        let first = *self.data.get(self.pos)?;
        self.pos += 1;
        let len = if first & 0x80 == 0 {
            first as usize
        } else {
            let n = (first & 0x7f) as usize;
            if n == 0 || n > 4 {
                return None;
            }
            let mut len = 0usize;
            for _ in 0..n {
                len = (len << 8) | *self.data.get(self.pos)? as usize;
                self.pos += 1;
            }
            len
        };
        let content = self.data.get(self.pos..self.pos + len)?;
        self.pos += len;
        Some((tag, content))
    }
}

/// Extract the EC P-256 public key from a DER certificate.
pub fn parse_public_key(der: &[u8]) -> Option<PublicKey> {
    let mut top = Reader { data: der, pos: 0 };
    let (tag, cert_body) = top.read()?;
    if tag != 0x30 {
        return None;
    }
    let mut cert_reader = Reader { data: cert_body, pos: 0 };
    let (tag, tbs) = cert_reader.read()?;
    if tag != 0x30 {
        return None;
    }
    let mut tbs_reader = Reader { data: tbs, pos: 0 };
    // [0] version, serial, alg, issuer, validity, subject, spki
    for _ in 0..6 {
        tbs_reader.read()?;
    }
    let (tag, spki) = tbs_reader.read()?;
    if tag != 0x30 {
        return None;
    }
    let mut spki_reader = Reader { data: spki, pos: 0 };
    spki_reader.read()?; // algorithm sequence
    let (tag, bitstring) = spki_reader.read()?;
    if tag != 0x03 || bitstring.is_empty() || bitstring[0] != 0 {
        return None;
    }
    PublicKey::decode(&bitstring[1..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_and_parse_roundtrip() {
        let cert = Certificate::generate_self_signed("dc-webrtc");
        let parsed = parse_public_key(&cert.der).expect("parse spki");
        assert_eq!(parsed, cert.public);
        assert_eq!(cert.fingerprint().len(), 95); // 32 bytes * 3 - 1
    }
}
