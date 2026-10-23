//! Minimal TLS 1.2 client for TURN over TLS (RFC 5766 turns:).
//!
//! One cipher suite (TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256),
//! P-256 ECDHE, no client authentication, no session
//! resumption, no Extended Master Secret (never offered).
//! Built on the same hand-rolled crypto as dtls.rs.
//!
//! Certificate policy: unless insecure_skip_verify is set,
//! the presented chain must build to a trusted root (system
//! store by default: `$SSL_CERT_FILE` or the usual PEM bundle
//! paths; or an explicit RootStore), every link's signature
//! must verify (ECDSA-with-SHA-256/384/512 over P-256/P-384
//! keys and sha{256,384,512}WithRSAEncryption are supported;
//! anything else fails closed), issuers must be CAs in window,
//! the leaf must be inside its validity window and name the
//! expected server (SAN dNSName / iPAddress, else CN), and
//! the ServerKeyExchange signature must verify.

use alloc::string::{String, ToString};
use alloc::vec::Vec;
use crate::crypto::{aes128_gcm_decrypt, aes128_gcm_encrypt, sha256, sha384, sha512};
#[cfg(feature = "std")]
use crate::crypto::{prf, random_bytes};
use crate::io;
#[cfg(feature = "std")]
use crate::io::{Read, Write};
use crate::p256::PublicKey;
#[cfg(feature = "std")]
use crate::p256::PrivateKey;
use core::net::IpAddr;
#[cfg(feature = "std")]
use std::net::TcpStream;

const SUITE_ECDHE_ECDSA_AES128_GCM_SHA256: u16 = 0xC02B;
const SUITE_ECDHE_RSA_AES128_GCM_SHA256: u16 = 0xC02F;
const VERSION: [u8; 2] = [3, 3];

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}

#[derive(Clone)]
struct Cipher {
    key: [u8; 16],
    salt: [u8; 4],
    seq: u64,
}

impl Cipher {
    fn encrypt(&mut self, content_type: u8, plaintext: &[u8]) -> Vec<u8> {
        let explicit = self.seq.to_be_bytes();
        let mut nonce = [0u8; 12];
        nonce[..4].copy_from_slice(&self.salt);
        nonce[4..].copy_from_slice(&explicit);
        let mut aad = Vec::with_capacity(13);
        aad.extend_from_slice(&explicit); // AAD sequence number == explicit nonce
        aad.push(content_type);
        aad.extend_from_slice(&VERSION);
        aad.extend_from_slice(&(plaintext.len() as u16).to_be_bytes());
        let (ciphertext, tag) = aes128_gcm_encrypt(&self.key, &nonce, plaintext, &aad);
        self.seq += 1;
        let mut out = Vec::with_capacity(8 + ciphertext.len() + 16);
        out.extend_from_slice(&explicit);
        out.extend_from_slice(&ciphertext);
        out.extend_from_slice(&tag);
        out
    }

    fn decrypt(&mut self, content_type: u8, record: &[u8]) -> io::Result<Vec<u8>> {
        if record.len() < 8 + 16 {
            return Err(bad("tls: record too short"));
        }
        // Nonce = salt || explicit nonce carried in the record;
        // the AAD sequence number is the implicit record counter
        // (RFC 5288: the two need not be equal).
        let explicit: [u8; 8] = record[..8].try_into().unwrap();
        let mut nonce = [0u8; 12];
        nonce[..4].copy_from_slice(&self.salt);
        nonce[4..].copy_from_slice(&explicit);
        let plain_len = record.len() - 8 - 16;
        let mut aad = Vec::with_capacity(13);
        aad.extend_from_slice(&self.seq.to_be_bytes());
        aad.push(content_type);
        aad.extend_from_slice(&VERSION);
        aad.extend_from_slice(&(plain_len as u16).to_be_bytes());
        let (ciphertext, tag) = record[8..].split_at(record.len() - 8 - 16);
        let tag: [u8; 16] = tag.try_into().unwrap();
        let plaintext = aes128_gcm_decrypt(&self.key, &nonce, ciphertext, &aad, &tag)
            .ok_or_else(|| bad("tls: record decryption failed"))?;
        self.seq += 1;
        Ok(plaintext)
    }
}

/// Record layer during the handshake (both directions on one
/// stream); split into halves once application data flows.
/// (TCP client halves are std-only; the DTLS engine in dtls.rs
/// has its own record layer over `DtlsIo`.)
#[cfg(feature = "std")]
struct RecordConn {
    stream: TcpStream,
    read_cipher: Option<Cipher>,
    write_cipher: Option<Cipher>,
}

#[cfg(feature = "std")]
impl RecordConn {
    fn write_record(&mut self, content_type: u8, payload: &[u8]) -> io::Result<()> {
        let body = match &mut self.write_cipher {
            Some(cipher) => cipher.encrypt(content_type, payload),
            None => payload.to_vec(),
        };
        let mut header = [content_type, VERSION[0], VERSION[1], 0, 0];
        header[3..5].copy_from_slice(&(body.len() as u16).to_be_bytes());
        self.stream.write_all(&header)?;
        self.stream.write_all(&body)
    }

    fn read_record(&mut self) -> io::Result<(u8, Vec<u8>)> {
        let mut header = [0u8; 5];
        self.stream.read_exact(&mut header)?;
        let length = u16::from_be_bytes(header[3..5].try_into().unwrap()) as usize;
        if length > 18_432 {
            return Err(bad("tls: record too large"));
        }
        let mut body = vec![0u8; length];
        self.stream.read_exact(&mut body)?;
        let content_type = header[0];
        match &mut self.read_cipher {
            Some(cipher) => Ok((content_type, cipher.decrypt(content_type, &body)?)),
            None => Ok((content_type, body)),
        }
    }
}

/// Handshake-message view over decrypted record payloads.
#[cfg(feature = "std")]
struct HandshakeReader {
    conn: RecordConn,
    buf: Vec<u8>,
    transcript: Vec<u8>,
}

#[cfg(feature = "std")]
impl HandshakeReader {
    /// Next handshake message as (type, body, transcript hash
    /// BEFORE this message — what Finished verify_data covers).
    /// ChangeCipherSpec records are reported as type 254 so
    /// the caller can switch ciphers and continue.
    fn next(&mut self) -> io::Result<(u8, Vec<u8>, [u8; 32])> {
        loop {
            if self.buf.len() >= 4 {
                let length =
                    ((self.buf[1] as usize) << 16) | ((self.buf[2] as usize) << 8) | self.buf[3] as usize;
                if self.buf.len() >= 4 + length {
                    let hash_before = self.transcript_hash();
                    let msg: Vec<u8> = self.buf.drain(..4 + length).collect();
                    self.transcript.extend_from_slice(&msg);
                    return Ok((msg[0], msg[4..].to_vec(), hash_before));
                }
            }
            let (content_type, payload) = self.conn.read_record()?;
            match content_type {
                22 => self.buf.extend_from_slice(&payload),
                20 => return Ok((254, payload, self.transcript_hash())),
                21 => return Err(bad("tls: alert during handshake")),
                _ => return Err(bad("tls: unexpected record during handshake")),
            }
        }
    }

    fn transcript_hash(&self) -> [u8; 32] {
        sha256(&self.transcript)
    }

    fn send(&mut self, msg_type: u8, body: &[u8]) -> io::Result<()> {
        let mut msg = vec![msg_type, (body.len() >> 16) as u8, (body.len() >> 8) as u8, body.len() as u8];
        msg.extend_from_slice(body);
        self.transcript.extend_from_slice(&msg);
        self.conn.write_record(22, &msg)
    }
}

fn ext(ext_type: u16, body: &[u8]) -> Vec<u8> {
    let mut out = ext_type.to_be_bytes().to_vec();
    out.extend_from_slice(&(body.len() as u16).to_be_bytes());
    out.extend_from_slice(body);
    out
}

fn client_hello(server_name: Option<&str>, random: &[u8; 32]) -> Vec<u8> {
    let mut body = Vec::new();
    body.extend_from_slice(&VERSION);
    body.extend_from_slice(random);
    body.push(0); // session id
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&SUITE_ECDHE_ECDSA_AES128_GCM_SHA256.to_be_bytes());
    body.extend_from_slice(&SUITE_ECDHE_RSA_AES128_GCM_SHA256.to_be_bytes());
    body.extend_from_slice(&[1, 0]); // compression: null
    let mut extensions = Vec::new();
    if let Some(name) = server_name {
        if name.parse::<IpAddr>().is_err() {
            let mut sni = Vec::new();
            let name_bytes = name.as_bytes();
            sni.extend_from_slice(&((name_bytes.len() + 3) as u16).to_be_bytes());
            sni.push(0); // host_name
            sni.extend_from_slice(&(name_bytes.len() as u16).to_be_bytes());
            sni.extend_from_slice(name_bytes);
            extensions.extend_from_slice(&ext(0, &sni));
        }
    }
    extensions.extend_from_slice(&ext(10, &[0, 4, 0, 23, 0, 24])); // supported_groups: secp256r1, secp384r1
    extensions.extend_from_slice(&ext(11, &[1, 0])); // ec_point_formats: uncompressed
    // signature_algorithms: ecdsa/sha256, ecdsa/sha384,
    // rsa_pkcs1/sha256, rsa_pkcs1/sha384 (the RSA pair lets
    // servers with RSA certificates -- the common TURNS case --
    // sign their ServerKeyExchange for us).
    extensions.extend_from_slice(&ext(13, &[0, 8, 4, 3, 5, 3, 4, 1, 5, 1]));
    body.extend_from_slice(&(extensions.len() as u16).to_be_bytes());
    body.extend_from_slice(&extensions);
    body
}

struct Cursor<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }
    fn take(&mut self, n: usize) -> io::Result<&'a [u8]> {
        let out = self.data.get(self.pos..self.pos + n).ok_or_else(|| bad("tls: truncated"))?;
        self.pos += n;
        Ok(out)
    }
    fn u8(&mut self) -> io::Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> io::Result<u16> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn skip_len8(&mut self) -> io::Result<()> {
        let n = self.u8()? as usize;
        self.take(n).map(|_| ())
    }

}

// ---------------------------------------------------------------------------
// Certificate parsing/verification (ECDSA P-256 and RSA keys)
// ---------------------------------------------------------------------------

/// A tiny DER TLV reader (definite lengths only).
struct Der<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Der<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    /// One TLV: (tag, content, full encoding).
    fn read(&mut self) -> io::Result<(u8, &'a [u8], &'a [u8])> {
        let start = self.pos;
        let byte = |der: &mut Der<'a>| -> io::Result<u8> {
            let b = *der.data.get(der.pos).ok_or_else(|| bad("tls: truncated DER"))?;
            der.pos += 1;
            Ok(b)
        };
        let tag = byte(self)?;
        let first = byte(self)? as usize;
        let length = if first < 0x80 {
            first
        } else {
            let count = first & 0x7f;
            if count == 0 || count > 3 {
                return Err(bad("tls: unsupported DER length"));
            }
            let mut len = 0usize;
            for _ in 0..count {
                len = (len << 8) | byte(self)? as usize;
            }
            len
        };
        let content = self
            .data
            .get(self.pos..self.pos + length)
            .ok_or_else(|| bad("tls: truncated DER"))?;
        self.pos += length;
        Ok((tag, content, &self.data[start..self.pos]))
    }
}

enum CertKey {
    EcdsaP256(PublicKey),
    EcdsaP384(crate::p384::PublicKey),
    Rsa { modulus: Vec<u8>, exponent: u64 },
}

#[derive(Clone, Copy)]
enum HashAlg {
    Sha256,
    Sha384,
    Sha512,
}

fn digest_for(hash: HashAlg, data: &[u8]) -> Vec<u8> {
    match hash {
        HashAlg::Sha256 => sha256(data).to_vec(),
        HashAlg::Sha384 => sha384(data).to_vec(),
        HashAlg::Sha512 => sha512(data).to_vec(),
    }
}

enum CertSignature {
    Ecdsa(Vec<u8>, Vec<u8>), // (r, s), big-endian
    Rsa(Vec<u8>),
    Unsupported,
}

struct ParsedCert {
    tbs: Vec<u8>,
    key: CertKey,
    spki: Vec<u8>,
    signature: CertSignature,
    hash: HashAlg,
    issuer: Vec<u8>,  // DER Name
    subject: Vec<u8>, // DER Name
    not_before: i64,
    not_after: i64,
    is_ca: bool, // BasicConstraints cA (false when absent)
    sans_dns: Vec<String>,
    sans_ip: Vec<IpAddr>,
    cn: Option<String>,
}

fn parse_time(tag: u8, text: &[u8]) -> io::Result<i64> {
    let text = core::str::from_utf8(text).map_err(|_| bad("tls: bad validity time"))?;
    let digits = |s: &str| s.bytes().take_while(|b| b.is_ascii_digit()).count();
    let (year, rest) = if tag == 0x17 {
        // UTCTime YYMMDDHHMMSSZ
        let yy: i64 = text.get(..2).and_then(|v| v.parse().ok()).ok_or_else(|| bad("tls: bad UTCTime"))?;
        (if yy >= 50 { 1900 + yy } else { 2000 + yy }, &text[2..])
    } else {
        // GeneralizedTime YYYYMMDDHHMMSSZ
        let yyyy: i64 = text.get(..4).and_then(|v| v.parse().ok()).ok_or_else(|| bad("tls: bad GeneralizedTime"))?;
        (yyyy, &text[4..])
    };
    if digits(rest) < 10 {
        return Err(bad("tls: bad validity time"));
    }
    let field = |i: usize| -> io::Result<i64> {
        rest.get(i..i + 2).and_then(|v| v.parse().ok()).ok_or_else(|| bad("tls: bad validity time"))
    };
    let (month, day, hour, min, sec) = (field(0)?, field(2)?, field(4)?, field(6)?, field(8)?);
    // Howard Hinnant's days-from-civil algorithm.
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Ok(days * 86400 + hour * 3600 + min * 60 + sec)
}

fn parse_ecdsa_signature(der: &[u8]) -> io::Result<(Vec<u8>, Vec<u8>)> {
    let mut top = Der::new(der);
    let (tag, seq, _) = top.read()?;
    if tag != 0x30 {
        return Err(bad("tls: bad ECDSA signature"));
    }
    let mut reader = Der::new(seq);
    let int = |reader: &mut Der<'_>| -> io::Result<Vec<u8>> {
        let (tag, content, _) = reader.read()?;
        if tag != 0x02 {
            return Err(bad("tls: bad ECDSA signature"));
        }
        let bytes = content.strip_prefix(&[0]).unwrap_or(content);
        if bytes.len() > 72 {
            return Err(bad("tls: bad ECDSA signature"));
        }
        Ok(bytes.to_vec())
    };
    Ok((int(&mut reader)?, int(&mut reader)?))
}

/// Parse a SubjectPublicKeyInfo body into the key forms we can
/// verify with: EC P-256 / P-384 and RSA.
fn parse_spki_key(spki: &[u8]) -> io::Result<CertKey> {
    let mut reader = Der::new(spki);
    let (_, alg_content, _) = reader.read()?;
    let mut alg = Der::new(alg_content);
    let (_, oid, _) = alg.read()?;
    let (tag, bitstring, _) = reader.read()?;
    if tag != 0x03 || bitstring.is_empty() || bitstring[0] != 0 {
        return Err(bad("tls: bad subject public key"));
    }
    let key_bytes = &bitstring[1..];
    match oid {
        // id-ecPublicKey 1.2.840.10045.2.1 (+ curve OID parameter)
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01] => {
            let (_, curve_oid, _) = alg.read()?;
            match curve_oid {
                // prime256v1 1.2.840.10045.3.1.7
                [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07] => PublicKey::decode(key_bytes)
                    .map(CertKey::EcdsaP256)
                    .ok_or_else(|| bad("tls: bad P-256 key in certificate")),
                // secp384r1 1.3.132.0.34
                [0x2b, 0x81, 0x04, 0x00, 0x22] => crate::p384::PublicKey::decode(key_bytes)
                    .map(CertKey::EcdsaP384)
                    .ok_or_else(|| bad("tls: bad P-384 key in certificate")),
                _ => Err(bad("tls: unsupported EC curve in certificate")),
            }
        }
        // rsaEncryption 1.2.840.113549.1.1.1
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01] => {
            let mut top = Der::new(key_bytes);
            let (tag, seq, _) = top.read()?;
            if tag != 0x30 {
                return Err(bad("tls: bad RSA key in certificate"));
            }
            let mut ints = Der::new(seq);
            let (_, modulus, _) = ints.read()?;
            let (_, exponent_bytes, _) = ints.read()?;
            let modulus = modulus.strip_prefix(&[0]).unwrap_or(modulus);
            if modulus.len() < 128 || modulus.len() > 1024 {
                return Err(bad("tls: unsupported RSA modulus size"));
            }
            let exponent_bytes = exponent_bytes.strip_prefix(&[0]).unwrap_or(exponent_bytes);
            if exponent_bytes.is_empty() || exponent_bytes.len() > 8 {
                return Err(bad("tls: unsupported RSA exponent"));
            }
            let mut exponent: u64 = 0;
            for byte in exponent_bytes {
                exponent = (exponent << 8) | *byte as u64;
            }
            Ok(CertKey::Rsa { modulus: modulus.to_vec(), exponent })
        }
        _ => Err(bad("tls: unsupported public key algorithm in certificate")),
    }
}

fn parse_cert(der_bytes: &[u8]) -> io::Result<ParsedCert> {
    let mut top = Der::new(der_bytes);
    let (tag, cert_body, _) = top.read()?;
    if tag != 0x30 {
        return Err(bad("tls: bad certificate"));
    }
    let mut cert = Der::new(cert_body);
    let (tag, _tbs_content, tbs_full) = cert.read()?;
    if tag != 0x30 {
        return Err(bad("tls: bad certificate"));
    }
    let (_, alg_content, _) = cert.read()?;
    let mut alg_reader = Der::new(alg_content);
    let (_, sig_alg_oid, _) = alg_reader.read()?;
    let (tag, sig_bits, _) = cert.read()?;
    if tag != 0x03 || sig_bits.is_empty() || sig_bits[0] != 0 {
        return Err(bad("tls: bad certificate signature"));
    }
    // ecdsa-with-SHA{256,384,512} 1.2.840.10045.4.3.{2,3,4} and
    // sha{256,384,512}WithRSAEncryption 1.2.840.113549.1.1.{11,12,13};
    // anything else fails closed at verify.
    let (signature, hash) = match sig_alg_oid {
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02] => {
            let (r, s) = parse_ecdsa_signature(&sig_bits[1..])?;
            (CertSignature::Ecdsa(r, s), HashAlg::Sha256)
        }
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03] => {
            let (r, s) = parse_ecdsa_signature(&sig_bits[1..])?;
            (CertSignature::Ecdsa(r, s), HashAlg::Sha384)
        }
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x04] => {
            let (r, s) = parse_ecdsa_signature(&sig_bits[1..])?;
            (CertSignature::Ecdsa(r, s), HashAlg::Sha512)
        }
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b] => {
            (CertSignature::Rsa(sig_bits[1..].to_vec()), HashAlg::Sha256)
        }
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0c] => {
            (CertSignature::Rsa(sig_bits[1..].to_vec()), HashAlg::Sha384)
        }
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0d] => {
            (CertSignature::Rsa(sig_bits[1..].to_vec()), HashAlg::Sha512)
        }
        _ => (CertSignature::Unsupported, HashAlg::Sha256),
    };

    // Walk TBSCertificate: [0] version?, serial, alg, issuer,
    // validity, subject, spki, ..., [3] extensions?
    let mut tbs = Der::new({
        let mut probe = Der::new(tbs_full);
        let (_, content, _) = probe.read()?;
        content
    });
    let (first_tag, _, _) = tbs.read()?;
    if first_tag != 0xa0 {
        // No version field: that first element was the serial.
        tbs.pos = 0;
    }
    let _serial = tbs.read()?;
    let _alg2 = tbs.read()?;
    let (_, _issuer_content, issuer_full) = tbs.read()?;
    let (_, validity, _) = tbs.read()?;
    let (not_before, not_after) = {
        let mut v = Der::new(validity);
        let (t1, c1, _) = v.read()?;
        let (t2, c2, _) = v.read()?;
        (parse_time(t1, c1)?, parse_time(t2, c2)?)
    };
    let (_, subject_content, subject_full) = tbs.read()?;
    let (_, spki_content, spki_full) = tbs.read()?;
    let key = parse_spki_key(spki_content)?;
    let mut sans_dns = Vec::new();
    let mut sans_ip = Vec::new();
    let mut is_ca = false;
    // Remaining elements: optional [1]/[2] unique ids, [3] extensions.
    while tbs.pos < tbs.data.len() {
        let (etag, content, _) = tbs.read()?;
        if etag != 0xa3 {
            continue;
        }
        let mut ext_wrap = Der::new(content);
        let (_, seq, _) = ext_wrap.read()?;
        let mut exts = Der::new(seq);
        while exts.pos < exts.data.len() {
            let (_, ext_body, _) = exts.read()?;
            let mut ext_reader = Der::new(ext_body);
            let (_, oid, _) = ext_reader.read()?;
            // Optional critical BOOLEAN, then OCTET STRING value.
            let (vtag, value, _) = ext_reader.read()?;
            let value = if vtag == 0x01 {
                ext_reader.read()?.1
            } else {
                value
            };
            // basicConstraints OID 2.5.29.19 == 55 1d 13:
            // SEQUENCE { BOOLEAN cA DEFAULT FALSE, pathLen? }
            if oid == [0x55, 0x1d, 0x13] {
                let mut bc_wrap = Der::new(value);
                if let Ok((_, seq, _)) = bc_wrap.read() {
                    let mut bc = Der::new(seq);
                    if let Ok((btag, bval, _)) = bc.read() {
                        is_ca = btag == 0x01 && bval.first().map_or(false, |b| *b != 0);
                    }
                }
                continue;
            }
            // subjectAltName OID 2.5.29.17 == 55 1d 11
            if oid != [0x55, 0x1d, 0x11] {
                continue;
            }
            let mut names = Der::new(value);
            let (_, names_seq, _) = names.read()?;
            let mut name_reader = Der::new(names_seq);
            while name_reader.pos < name_reader.data.len() {
                let (ntag, ncontent, _) = name_reader.read()?;
                match ntag {
                    0x82 => sans_dns.push(String::from_utf8_lossy(ncontent).into_owned()),
                    0x87 if ncontent.len() == 4 => {
                        sans_ip.push(IpAddr::from(<[u8; 4]>::try_from(ncontent).unwrap()))
                    }
                    0x87 if ncontent.len() == 16 => {
                        sans_ip.push(IpAddr::from(<[u8; 16]>::try_from(ncontent).unwrap()))
                    }
                    _ => {}
                }
            }
        }
    }
    // CN from subject (OID 2.5.4.3 == 55 04 03), best-effort.
    let mut cn = None;
    let mut subject = Der::new(subject_content);
    while subject.pos < subject.data.len() {
        let (_, set_body, _) = subject.read()?;
        let mut set = Der::new(set_body);
        while set.pos < set.data.len() {
            let (_, atv, _) = set.read()?;
            let mut pair = Der::new(atv);
            let (_, oid, _) = pair.read()?;
            let (_, value, _) = pair.read()?;
            if oid == [0x55, 0x04, 0x03] {
                cn = Some(String::from_utf8_lossy(value).into_owned());
            }
        }
    }
    Ok(ParsedCert {
        tbs: tbs_full.to_vec(),
        key,
        spki: spki_full.to_vec(),
        signature,
        hash,
        issuer: issuer_full.to_vec(),
        subject: subject_full.to_vec(),
        not_before,
        not_after,
        is_ca,
        sans_dns,
        sans_ip,
        cn,
    })
}

fn pad<const N: usize>(bytes: &[u8]) -> Option<[u8; N]> {
    if bytes.len() > N {
        return None;
    }
    let mut out = [0u8; N];
    out[N - bytes.len()..].copy_from_slice(bytes);
    Some(out)
}

fn ecdsa_verify_p256(key: &PublicKey, digest: &[u8; 32], r_bytes: &[u8], s_bytes: &[u8]) -> bool {
    match (pad::<32>(r_bytes), pad::<32>(s_bytes)) {
        (Some(r), Some(s)) => key.verify(digest, &r, &s),
        _ => false,
    }
}

// --- RSA PKCS#1 v1.5 verify (public values only; no secret data,
// so straightforward bignum arithmetic is fine) ---

type BigUint = Vec<u32>; // little-endian limbs

fn big_from_be(bytes: &[u8]) -> BigUint {
    let mut limbs = vec![0u32; bytes.len().div_ceil(4)];
    for (i, byte) in bytes.iter().rev().enumerate() {
        limbs[i / 4] |= (*byte as u32) << ((i % 4) * 8);
    }
    while limbs.len() > 1 && *limbs.last().unwrap() == 0 {
        limbs.pop();
    }
    limbs
}

fn big_to_be(value: &BigUint, width: usize) -> Vec<u8> {
    let mut out = vec![0u8; width];
    for i in 0..width {
        let limb = value.get(i / 4).copied().unwrap_or(0);
        out[width - 1 - i] = (limb >> ((i % 4) * 8)) as u8;
    }
    out
}

fn big_cmp(a: &BigUint, b: &BigUint) -> core::cmp::Ordering {
    let top = |v: &BigUint| v.iter().rposition(|limb| *limb != 0).map_or(0, |i| i + 1);
    match top(a).cmp(&top(b)) {
        core::cmp::Ordering::Equal => {
            for i in (0..top(a)).rev() {
                match a[i].cmp(&b[i]) {
                    core::cmp::Ordering::Equal => continue,
                    other => return other,
                }
            }
            core::cmp::Ordering::Equal
        }
        other => other,
    }
}

// a -= b, requiring a >= b.
fn big_sub_assign(a: &mut BigUint, b: &BigUint) {
    let mut borrow = 0i64;
    for i in 0..a.len() {
        let sub = b.get(i).copied().unwrap_or(0) as i64 + borrow;
        let cur = a[i] as i64 - sub;
        if cur < 0 {
            a[i] = (cur + (1i64 << 32)) as u32;
            borrow = 1;
        } else {
            a[i] = cur as u32;
            borrow = 0;
        }
    }
}

fn big_addmod(a: &BigUint, b: &BigUint, modulus: &BigUint) -> BigUint {
    let len = modulus.len() + 1;
    let mut out = vec![0u32; len];
    let mut carry = 0u64;
    for i in 0..len {
        let sum = a.get(i).copied().unwrap_or(0) as u64
            + b.get(i).copied().unwrap_or(0) as u64
            + carry;
        out[i] = sum as u32;
        carry = sum >> 32;
    }
    if big_cmp(&out, modulus) != core::cmp::Ordering::Less {
        big_sub_assign(&mut out, modulus);
    }
    out.truncate(modulus.len());
    out
}

fn big_mulmod(a: &BigUint, b: &BigUint, modulus: &BigUint) -> BigUint {
    // Double-and-add over the bits of b (MSB first).
    let mut acc = vec![0u32; modulus.len()];
    let bits = modulus.len() * 32;
    for i in (0..bits).rev() {
        acc = big_addmod(&acc, &acc, modulus);
        let bit = (b.get(i / 32).copied().unwrap_or(0) >> (i % 32)) & 1;
        if bit == 1 {
            acc = big_addmod(&acc, a, modulus);
        }
    }
    acc
}

fn rsa_pkcs1_verify(hash: HashAlg, digest: &[u8], sig: &[u8], modulus: &[u8], exponent: u64) -> bool {
    let n = big_from_be(modulus);
    let s = big_from_be(sig);
    if big_cmp(&s, &n) != core::cmp::Ordering::Less {
        return false;
    }
    // m = s^e mod n by square-and-multiply over the exponent bits.
    let mut result = big_from_be(&[1]);
    result.resize(n.len(), 0);
    let top_bit = 64 - exponent.leading_zeros();
    for i in (0..top_bit).rev() {
        result = big_mulmod(&result.clone(), &result.clone(), &n);
        if (exponent >> i) & 1 == 1 {
            result = big_mulmod(&result.clone(), &s, &n);
        }
    }
    let em = big_to_be(&result, modulus.len());
    // EMSA-PKCS1-v1_5: 00 01 FF..00 || DigestInfo(hash) || H
    const INFO_SHA256: [u8; 19] = [
        0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01,
        0x05, 0x00, 0x04, 0x20,
    ];
    const INFO_SHA384: [u8; 19] = [
        0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02,
        0x05, 0x00, 0x04, 0x30,
    ];
    const INFO_SHA512: [u8; 19] = [
        0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03,
        0x05, 0x00, 0x04, 0x40,
    ];
    let digest_info: &[u8] = match hash {
        HashAlg::Sha256 => &INFO_SHA256,
        HashAlg::Sha384 => &INFO_SHA384,
        HashAlg::Sha512 => &INFO_SHA512,
    };
    let tail_len = digest_info.len() + digest.len();
    if em.len() < tail_len + 11 || em[0] != 0 || em[1] != 1 {
        return false;
    }
    let sep = em.len() - tail_len;
    if em[sep - 1] != 0 || em[2..sep - 1].iter().any(|b| *b != 0xff) {
        return false;
    }
    em[sep..sep + digest_info.len()] == *digest_info && &em[sep + digest_info.len()..] == digest
}

fn verify_signature(issuer: &ParsedCert, child: &ParsedCert) -> bool {
    let digest = digest_for(child.hash, &child.tbs);
    match (&child.signature, &issuer.key) {
        (CertSignature::Ecdsa(r, s), CertKey::EcdsaP256(key)) => {
            let truncated: [u8; 32] = digest[..32].try_into().unwrap();
            ecdsa_verify_p256(key, &truncated, r, s)
        }
        (CertSignature::Ecdsa(r, s), CertKey::EcdsaP384(key)) => {
            match (pad::<48>(r), pad::<48>(s)) {
                (Some(r48), Some(s48)) => key.verify(&digest, &r48, &s48),
                _ => false,
            }
        }
        (CertSignature::Rsa(sig), CertKey::Rsa { modulus, exponent }) => {
            rsa_pkcs1_verify(child.hash, &digest, sig, modulus, *exponent)
        }
        _ => false,
    }
}

// --- Root store ---

fn base64_decode(text: &[u8]) -> Option<Vec<u8>> {
    let value = |b: u8| -> Option<u32> {
        match b {
            b'A'..=b'Z' => Some((b - b'A') as u32),
            b'a'..=b'z' => Some((b - b'a' + 26) as u32),
            b'0'..=b'9' => Some((b - b'0' + 52) as u32),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let mut out = Vec::new();
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    for byte in text {
        if byte.is_ascii_whitespace() {
            continue;
        }
        if *byte == b'=' {
            break;
        }
        acc = (acc << 6) | value(*byte)?;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// Trusted root certificates for TLS verification.
pub struct RootStore {
    roots: Vec<ParsedCert>,
}

impl RootStore {
    pub fn empty() -> Self {
        Self { roots: Vec::new() }
    }

    pub fn add_der(&mut self, der: &[u8]) -> io::Result<()> {
        self.roots.push(parse_cert(der)?);
        Ok(())
    }

    /// Add every CERTIFICATE block in a PEM bundle; unparsable
    /// blocks are skipped. Returns how many were added.
    pub fn add_pem(&mut self, pem: &[u8]) -> usize {
        let text = String::from_utf8_lossy(pem);
        let mut added = 0;
        for block in text.split("-----BEGIN CERTIFICATE-----").skip(1) {
            let Some((body, _)) = block.split_once("-----END CERTIFICATE-----") else {
                continue;
            };
            if let Some(der) = base64_decode(body.as_bytes()) {
                if let Ok(cert) = parse_cert(&der) {
                    self.roots.push(cert);
                    added += 1;
                }
            }
        }
        added
    }

    /// The platform root store: $SSL_CERT_FILE when set, else
    /// the first existing well-known bundle path.
    #[cfg(feature = "std")]
    pub fn system() -> io::Result<Self> {
        let mut store = Self::empty();
        let mut candidates: Vec<std::path::PathBuf> = Vec::new();
        if let Ok(path) = std::env::var("SSL_CERT_FILE") {
            candidates.push(path.into());
        } else {
            candidates = [
                "/etc/ssl/certs/ca-certificates.crt",
                "/etc/pki/tls/certs/ca-bundle.crt",
                "/etc/ssl/cert.pem",
                "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
            ]
            .iter()
            .map(Into::into)
            .collect();
        }
        for path in candidates {
            if let Ok(pem) = std::fs::read(&path) {
                if store.add_pem(&pem) > 0 {
                    return Ok(store);
                }
            }
        }
        Err(bad("tls: no system root certificates found"))
    }

    fn find_by_subject(&self, subject: &[u8]) -> Option<&ParsedCert> {
        self.roots.iter().find(|root| root.subject == subject)
    }
}

#[cfg(feature = "std")]
fn system_roots() -> io::Result<&'static RootStore> {
    static ROOTS: std::sync::OnceLock<io::Result<RootStore>> = std::sync::OnceLock::new();
    match ROOTS.get_or_init(RootStore::system) {
        Ok(store) => Ok(store),
        Err(err) => Err(bad(&format!("tls: system roots unavailable: {err}"))),
    }
}

fn verify_chain(certs: &[ParsedCert], roots: &RootStore, server_name: &str) -> io::Result<()> {
    if certs.is_empty() {
        return Err(bad("tls: empty certificate chain"));
    }
    let now = crate::platform::wall_now_secs() as i64;
    let in_window = |cert: &ParsedCert| now >= cert.not_before && now <= cert.not_after;
    let leaf = &certs[0];
    if !in_window(leaf) {
        return Err(bad("tls: certificate outside validity window"));
    }
    // Build leaf -> intermediates -> a trusted root.
    let mut current = leaf;
    for _ in 0..8 {
        if let Some(root) = roots.find_by_subject(&current.issuer) {
            // Anchored: the presented cert may be the root
            // itself (same name and key), or signed by it.
            let is_root_itself = current.subject == root.subject && current.spki == root.spki;
            if !is_root_itself && !verify_signature(root, current) {
                return Err(bad("tls: certificate signature invalid at the root"));
            }
            verify_server_name(leaf, server_name)?;
            return Ok(());
        }
        let Some(issuer) = certs.iter().find(|c| c.subject == current.issuer) else {
            return Err(bad("tls: certificate chain does not reach a trusted root"));
        };
        if !issuer.is_ca {
            return Err(bad("tls: issuer is not a CA"));
        }
        if !in_window(issuer) {
            return Err(bad("tls: issuer certificate outside validity window"));
        }
        if !verify_signature(issuer, current) {
            return Err(bad("tls: certificate chain signature invalid"));
        }
        // find() can return current itself for a self-signed
        // cert not in the root store.
        if core::ptr::eq(issuer, current) {
            return Err(bad("tls: self-signed certificate is not a trusted root"));
        }
        current = issuer;
    }
    Err(bad("tls: certificate chain too long"))
}

fn verify_server_name(leaf: &ParsedCert, server_name: &str) -> io::Result<()> {
    // Server identity: SANs when present, else CN.
    if let Ok(ip) = server_name.parse::<IpAddr>() {
        if leaf.sans_ip.contains(&ip) {
            return Ok(());
        }
        return Err(bad("tls: certificate does not name this IP"));
    }
    let name_matches = |pattern: &str| -> bool {
        let pattern = pattern.to_ascii_lowercase();
        let name = server_name.to_ascii_lowercase();
        if let Some(suffix) = pattern.strip_prefix("*.") {
            match name.split_once('.') {
                Some((_label, rest)) => rest == suffix,
                None => false,
            }
        } else {
            pattern == name
        }
    };
    if leaf.sans_dns.iter().any(|n| name_matches(n)) {
        return Ok(());
    }
    if leaf.sans_dns.is_empty() {
        if let Some(cn) = &leaf.cn {
            if name_matches(cn) {
                return Ok(());
            }
        }
    }
    Err(bad("tls: certificate does not name this server"))
}

// ---------------------------------------------------------------------------
// Client handshake + split halves
// ---------------------------------------------------------------------------

/// Decrypting read half: yields application-data plaintext via
/// Read (other record types are consumed and ignored).
#[cfg(feature = "std")]
pub struct TlsReadHalf {
    stream: TcpStream,
    cipher: Cipher,
    plain: std::collections::VecDeque<u8>,
}

#[cfg(feature = "std")]
impl Read for TlsReadHalf {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        while self.plain.is_empty() {
            let mut header = [0u8; 5];
            self.stream.read_exact(&mut header)?;
            let length = u16::from_be_bytes(header[3..5].try_into().unwrap()) as usize;
            if length > 18_432 {
                return Err(bad("tls: record too large"));
            }
            let mut body = vec![0u8; length];
            self.stream.read_exact(&mut body)?;
            let content_type = header[0];
            let plaintext = self.cipher.decrypt(content_type, &body)?;
            match content_type {
                23 => self.plain.extend(plaintext),
                21 => {
                    if plaintext.first() == Some(&2) {
                        return Err(bad("tls: fatal alert"));
                    }
                    if plaintext.get(1) == Some(&0) {
                        return Ok(0); // close_notify
                    }
                }
                20 | 22 => {} // stray CCS / handshake (e.g. late ticket): ignore
                _ => return Err(bad("tls: unexpected record type")),
            }
        }
        let n = out.len().min(self.plain.len());
        for slot in &mut out[..n] {
            *slot = self.plain.pop_front().unwrap();
        }
        Ok(n)
    }
}

/// Encrypting write half (one record per write_all chunk).
#[cfg(feature = "std")]
pub struct TlsWriteHalf {
    stream: TcpStream,
    cipher: Cipher,
}

#[cfg(feature = "std")]
impl TlsWriteHalf {
    pub fn write_all(&mut self, data: &[u8]) -> io::Result<()> {
        for chunk in data.chunks(16_384) {
            let body = self.cipher.encrypt(23, chunk);
            let mut header = [23u8, VERSION[0], VERSION[1], 0, 0];
            header[3..5].copy_from_slice(&(body.len() as u16).to_be_bytes());
            self.stream.write_all(&header)?;
            self.stream.write_all(&body)?;
        }
        Ok(())
    }
}

/// connect with the system root store (see RootStore::system).
#[cfg(feature = "std")]
pub fn connect(
    stream: TcpStream,
    server_name: &str,
    insecure_skip_verify: bool,
) -> io::Result<(TlsReadHalf, TlsWriteHalf)> {
    connect_with_roots(stream, server_name, insecure_skip_verify, None)
}

/// Run the TLS 1.2 client handshake over an established TCP
/// connection and split it into read/write halves. Verifies
/// the presented chain against `roots` (system store when
/// None) unless insecure_skip_verify (the ServerKeyExchange
/// signature is always verified unless skipping: without it
/// the handshake proves nothing).
#[cfg(feature = "std")]
pub fn connect_with_roots(
    stream: TcpStream,
    server_name: &str,
    insecure_skip_verify: bool,
    roots: Option<&RootStore>,
) -> io::Result<(TlsReadHalf, TlsWriteHalf)> {
    let mut hs = HandshakeReader {
        conn: RecordConn { stream, read_cipher: None, write_cipher: None },
        buf: Vec::new(),
        transcript: Vec::new(),
    };
    let client_random: [u8; 32] = random_bytes(32).try_into().unwrap();
    let sni = if server_name.is_empty() { None } else { Some(server_name) };
    hs.send(1, &client_hello(sni, &client_random))?;

    // --- server flight ---
    let (msg_type, body, _) = hs.next()?;
    if msg_type != 2 {
        return Err(bad("tls: expected ServerHello"));
    }
    let mut cursor = Cursor::new(&body);
    if cursor.take(2)? != VERSION {
        return Err(bad("tls: server did not select TLS 1.2"));
    }
    let server_random: [u8; 32] = cursor.take(32)?.try_into().unwrap();
    cursor.skip_len8()?; // session id
    match cursor.u16()? {
        SUITE_ECDHE_ECDSA_AES128_GCM_SHA256 | SUITE_ECDHE_RSA_AES128_GCM_SHA256 => {}
        _ => return Err(bad("tls: server selected an unsupported cipher suite")),
    }
    if cursor.u8()? != 0 {
        return Err(bad("tls: server selected compression"));
    }

    let (msg_type, body, _) = hs.next()?;
    if msg_type != 11 {
        return Err(bad("tls: expected Certificate"));
    }
    let mut cursor = Cursor::new(&body);
    let total = {
        let b = cursor.take(3)?;
        ((b[0] as usize) << 16) | ((b[1] as usize) << 8) | b[2] as usize
    };
    let cert_list = cursor.take(total)?;
    let mut chain: Vec<ParsedCert> = Vec::new();
    let mut list_cursor = Cursor::new(cert_list);
    while list_cursor.pos < cert_list.len() {
        let b = list_cursor.take(3)?;
        let len = ((b[0] as usize) << 16) | ((b[1] as usize) << 8) | b[2] as usize;
        chain.push(parse_cert(list_cursor.take(len)?)?);
    }
    if chain.is_empty() {
        return Err(bad("tls: empty certificate chain"));
    }
    if !insecure_skip_verify {
        let roots = match roots {
            Some(store) => store,
            None => system_roots()?,
        };
        verify_chain(&chain, roots, server_name)?;
    }
    enum LeafKey {
        P256(PublicKey),
        P384(crate::p384::PublicKey),
        Rsa { modulus: Vec<u8>, exponent: u64 },
    }
    let leaf_key = match &chain[0].key {
        CertKey::EcdsaP256(key) => LeafKey::P256(*key),
        CertKey::EcdsaP384(key) => LeafKey::P384(*key),
        CertKey::Rsa { modulus, exponent } => LeafKey::Rsa {
            modulus: modulus.clone(),
            exponent: *exponent,
        },
    };

    let (msg_type, body, _) = hs.next()?;
    if msg_type == 13 {
        return Err(bad("tls: client authentication not supported"));
    }
    if msg_type != 12 {
        return Err(bad("tls: expected ServerKeyExchange"));
    }
    // ECParameters: named_curve secp256r1/secp384r1 + point, then signature.
    if body.len() < 4 || body[0] != 3 {
        return Err(bad("tls: unsupported ServerKeyExchange parameters"));
    }
    enum ServerPublic {
        P256(PublicKey),
        P384(crate::p384::PublicKey),
    }
    let curve = u16::from_be_bytes([body[1], body[2]]);
    let point_len = body[3] as usize;
    let params_end = 4 + point_len;
    let point_bytes = body.get(4..params_end).ok_or_else(|| bad("tls: truncated SKE point"))?;
    let server_public = match curve {
        23 => ServerPublic::P256(
            PublicKey::decode(point_bytes).ok_or_else(|| bad("tls: bad SKE point"))?,
        ),
        24 => ServerPublic::P384(
            crate::p384::PublicKey::decode(point_bytes)
                .ok_or_else(|| bad("tls: bad SKE point"))?,
        ),
        _ => return Err(bad("tls: unsupported ServerKeyExchange parameters")),
    };
    let mut sig_cursor = Cursor::new(body.get(params_end..).ok_or_else(|| bad("tls: truncated SKE"))?);
    let hash_alg = sig_cursor.u8()?;
    let sig_alg = sig_cursor.u8()?;
    let ske_hash = match (hash_alg, sig_alg) {
        (4, 3) | (4, 1) => HashAlg::Sha256,
        (5, 3) | (5, 1) => HashAlg::Sha384,
        _ => return Err(bad("tls: unsupported SKE signature algorithm")),
    };
    let ske_is_rsa = sig_alg == 1;
    let sig_len = sig_cursor.u16()? as usize;
    let sig_der = sig_cursor.take(sig_len)?;
    if !insecure_skip_verify {
        let mut signed = Vec::with_capacity(64 + params_end);
        signed.extend_from_slice(&client_random);
        signed.extend_from_slice(&server_random);
        signed.extend_from_slice(&body[..params_end]);
        let digest = digest_for(ske_hash, &signed);
        let verified = if ske_is_rsa {
            match &leaf_key {
                LeafKey::Rsa { modulus, exponent } => {
                    rsa_pkcs1_verify(ske_hash, &digest, sig_der, modulus, *exponent)
                }
                _ => false,
            }
        } else {
            let sig = match parse_ecdsa_signature(sig_der) {
                Ok(sig) => sig,
                Err(_) => {
                    return Err(bad("tls: ServerKeyExchange signature invalid"));
                }
            };
            match &leaf_key {
                LeafKey::P256(key) => {
                    let truncated: [u8; 32] = digest[..32].try_into().unwrap();
                    ecdsa_verify_p256(key, &truncated, &sig.0, &sig.1)
                }
                LeafKey::P384(key) => match (pad::<48>(&sig.0), pad::<48>(&sig.1)) {
                    (Some(r), Some(s)) => key.verify(&digest, &r, &s),
                    _ => false,
                },
                LeafKey::Rsa { .. } => false,
            }
        };
        if !verified {
            return Err(bad("tls: ServerKeyExchange signature invalid"));
        }
    }

    let (msg_type, _, _) = hs.next()?;
    if msg_type != 14 {
        return Err(bad("tls: expected ServerHelloDone"));
    }

    // --- client flight ---
    let (premaster, client_point): (Vec<u8>, Vec<u8>) = match &server_public {
        ServerPublic::P256(server_key) => {
            let (secret, ours) = PrivateKey::generate();
            let shared = secret.ecdh(server_key).ok_or_else(|| bad("tls: ECDHE failed"))?;
            (shared.to_vec(), ours.encode_uncompressed().to_vec())
        }
        ServerPublic::P384(server_key) => {
            let (secret, ours) = crate::p384::PrivateKey::generate();
            let shared = secret.ecdh(server_key).ok_or_else(|| bad("tls: ECDHE failed"))?;
            (shared.to_vec(), ours.encode_uncompressed().to_vec())
        }
    };
    let mut seed = Vec::with_capacity(64);
    seed.extend_from_slice(&client_random);
    seed.extend_from_slice(&server_random);
    let master = prf(&premaster, "master secret", &seed, 48);
    let mut key_seed = Vec::with_capacity(64);
    key_seed.extend_from_slice(&server_random);
    key_seed.extend_from_slice(&client_random);
    let block = prf(&master, "key expansion", &key_seed, 40);
    let client_write = Cipher {
        key: block[0..16].try_into().unwrap(),
        salt: block[32..36].try_into().unwrap(),
        seq: 0,
    };
    let server_write = Cipher {
        key: block[16..32].try_into().unwrap(),
        salt: block[36..40].try_into().unwrap(),
        seq: 0,
    };

    let mut cke = vec![client_point.len() as u8];
    cke.extend_from_slice(&client_point);
    hs.send(16, &cke)?;
    hs.conn.write_record(20, &[1])?;
    hs.conn.write_cipher = Some(client_write.clone());
    let verify_data = prf(&master, "client finished", &hs.transcript_hash(), 12);
    hs.send(20, &verify_data)?;

    // --- server finish flight ---
    // Optional NewSessionTicket (plaintext), then CCS, then the
    // encrypted Finished.
    let mut saw_ccs = false;
    loop {
        let (msg_type, body, hash_before) = hs.next()?;
        match msg_type {
            254 => {
                // ChangeCipherSpec record.
                hs.conn.read_cipher = Some(server_write.clone());
                saw_ccs = true;
            }
            4 => {
                if saw_ccs {
                    return Err(bad("tls: ticket after CCS"));
                }
                // NewSessionTicket: ignored (no resumption).
            }
            20 => {
                if !saw_ccs {
                    return Err(bad("tls: Finished before ChangeCipherSpec"));
                }
                let expected = prf(&master, "server finished", &hash_before, 12);
                let got = body.get(..12).ok_or_else(|| bad("tls: short Finished"))?;
                if got != expected.as_slice() {
                    return Err(bad("tls: server Finished verification failed"));
                }
                break;
            }
            _ => return Err(bad("tls: unexpected handshake message")),
        }
    }

    let read_stream = hs.conn.stream.try_clone()?;
    let read_half = TlsReadHalf {
        stream: read_stream,
        cipher: hs.conn.read_cipher.take().unwrap(),
        plain: std::collections::VecDeque::new(),
    };
    let write_half = TlsWriteHalf {
        stream: hs.conn.stream,
        cipher: hs.conn.write_cipher.take().unwrap(),
    };
    Ok((read_half, write_half))
}

#[cfg(test)]
mod tests {
    use super::*;

    // OpenSSL-generated fixtures (public certs only): an RSA CA
    // and an ECDSA CA, each with a P-256 leaf for CN/SAN
    // localhost, plus a self-signed localhost leaf.
    const RSA_CA: &str = include_str!("../tests/fixtures/rsa_ca.pem");
    const LEAF_RSA: &str = include_str!("../tests/fixtures/leaf1.pem");
    const EC_CA: &str = include_str!("../tests/fixtures/ec_ca.pem");
    const LEAF_EC: &str = include_str!("../tests/fixtures/leaf2.pem");
    const SELF_SIGNED: &str = include_str!("../tests/fixtures/ss.pem");
    const P384_CA: &str = include_str!("../tests/fixtures/p384_ca.pem");
    const LEAF_P384: &str = include_str!("../tests/fixtures/leaf3.pem");
    const LEAF_P256_BY_P384: &str = include_str!("../tests/fixtures/leaf4.pem");
    const LEAF_RSA384: &str = include_str!("../tests/fixtures/leaf5.pem");
    const LEAF_RSA512: &str = include_str!("../tests/fixtures/leaf6.pem");

    fn cert(pem: &str) -> ParsedCert {
        let body = pem
            .split("-----BEGIN CERTIFICATE-----")
            .nth(1)
            .unwrap()
            .split("-----END")
            .next()
            .unwrap();
        parse_cert(&base64_decode(body.as_bytes()).unwrap()).unwrap()
    }

    fn store_with(pems: &[&str]) -> RootStore {
        let mut store = RootStore::empty();
        for pem in pems {
            assert_eq!(store.add_pem(pem.as_bytes()), 1);
        }
        store
    }

    #[test]
    fn rsa_signed_leaf_verifies_against_rsa_root() {
        verify_chain(&[cert(LEAF_RSA)], &store_with(&[RSA_CA]), "localhost").unwrap();
    }

    #[test]
    fn ecdsa_signed_leaf_verifies_against_ec_root() {
        verify_chain(&[cert(LEAF_EC)], &store_with(&[EC_CA]), "localhost").unwrap();
    }

    #[test]
    fn presented_root_in_chain_is_accepted() {
        verify_chain(
            &[cert(LEAF_RSA), cert(RSA_CA)],
            &store_with(&[RSA_CA]),
            "localhost",
        )
        .unwrap();
    }

    #[test]
    fn missing_root_is_rejected() {
        assert!(verify_chain(&[cert(LEAF_RSA)], &RootStore::empty(), "localhost").is_err());
        assert!(verify_chain(&[cert(LEAF_EC)], &store_with(&[RSA_CA]), "localhost").is_err());
    }

    #[test]
    fn self_signed_leaf_needs_explicit_trust() {
        assert!(verify_chain(&[cert(SELF_SIGNED)], &RootStore::empty(), "localhost").is_err());
        verify_chain(&[cert(SELF_SIGNED)], &store_with(&[SELF_SIGNED]), "localhost").unwrap();
    }

    #[test]
    #[test]
    fn client_hello_offers_rsa_suite_and_signature_algorithms() {
        let hello = client_hello(Some("example.com"), &[7u8; 32]);
        let has_suite = hello
            .windows(2)
            .any(|w| w == SUITE_ECDHE_RSA_AES128_GCM_SHA256.to_be_bytes());
        assert!(has_suite, "ECDHE-RSA suite not offered");
        let has_rsa_sigalg = hello.windows(2).any(|w| w == [0x04, 0x01])
            && hello.windows(2).any(|w| w == [0x05, 0x01]);
        assert!(has_rsa_sigalg, "rsa_pkcs1 signature algorithms not offered");
    }

    #[test]
    fn p384_chain_with_sha384_signature_verifies() {
        // P-384 CA (ecdsa-with-SHA384) issuing a P-384 leaf.
        verify_chain(&[cert(LEAF_P384)], &store_with(&[P384_CA]), "localhost").unwrap();
    }

    #[test]
    fn p384_issuer_over_p256_leaf_verifies() {
        verify_chain(&[cert(LEAF_P256_BY_P384)], &store_with(&[P384_CA]), "localhost").unwrap();
    }

    #[test]
    fn rsa_sha384_and_sha512_signatures_verify() {
        verify_chain(&[cert(LEAF_RSA384)], &store_with(&[RSA_CA]), "localhost").unwrap();
        verify_chain(&[cert(LEAF_RSA512)], &store_with(&[RSA_CA]), "localhost").unwrap();
    }

    #[test]
    fn wrong_server_name_is_rejected() {
        assert!(
            verify_chain(&[cert(LEAF_EC)], &store_with(&[EC_CA]), "wrong.example").is_err()
        );
    }

    #[test]
    fn tampered_signature_is_rejected() {
        let mut leaf = cert(LEAF_EC);
        if let CertSignature::Ecdsa(_, s) = &mut leaf.signature {
            s[0] ^= 1;
        } else {
            panic!("fixture leaf must carry an ECDSA signature");
        }
        assert!(verify_chain(&[leaf], &store_with(&[EC_CA]), "localhost").is_err());

        let mut leaf = cert(LEAF_RSA);
        if let CertSignature::Rsa(sig) = &mut leaf.signature {
            let last = sig.len() - 1;
            sig[last] ^= 1;
        } else {
            panic!("fixture leaf must carry an RSA signature");
        }
        assert!(verify_chain(&[leaf], &store_with(&[RSA_CA]), "localhost").is_err());
    }
}
