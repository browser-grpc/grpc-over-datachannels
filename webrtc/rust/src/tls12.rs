//! Minimal TLS 1.2 client for TURN over TLS (RFC 5766 turns:).
//!
//! One cipher suite (TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256),
//! P-256 ECDHE, no client authentication, no session
//! resumption, no Extended Master Secret (never offered).
//! Built on the same hand-rolled crypto as dtls.rs.
//!
//! Certificate policy is deliberately narrow (a std-only stack
//! ships no WebPKI root store): unless insecure_skip_verify is
//! set, the presented chain must be signature-valid up to a
//! self-signed top, the leaf must be inside its validity
//! window and name the expected server (SAN dNSName /
//! iPAddress, else CN), and the ServerKeyExchange signature
//! must verify. That is chain hygiene, not root trust —
//! deployments that need WebPKI should terminate TLS
//! elsewhere.

use crate::crypto::{aes128_gcm_decrypt, aes128_gcm_encrypt, prf, random_bytes, sha256};
use crate::p256::{PrivateKey, PublicKey};
use std::io::{self, Read, Write};
use std::net::{IpAddr, TcpStream};

const SUITE_ECDHE_ECDSA_AES128_GCM_SHA256: u16 = 0xC02B;
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
struct RecordConn {
    stream: TcpStream,
    read_cipher: Option<Cipher>,
    write_cipher: Option<Cipher>,
}

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
struct HandshakeReader {
    conn: RecordConn,
    buf: Vec<u8>,
    transcript: Vec<u8>,
}

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
    body.extend_from_slice(&2u16.to_be_bytes());
    body.extend_from_slice(&SUITE_ECDHE_ECDSA_AES128_GCM_SHA256.to_be_bytes());
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
    extensions.extend_from_slice(&ext(10, &[0, 2, 0, 23])); // supported_groups: secp256r1
    extensions.extend_from_slice(&ext(11, &[1, 0])); // ec_point_formats: uncompressed
    extensions.extend_from_slice(&ext(13, &[0, 2, 4, 3])); // signature_algorithms: ecdsa/sha256
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
    fn skip_len16(&mut self) -> io::Result<()> {
        let n = self.u16()? as usize;
        self.take(n).map(|_| ())
    }
}

// ---------------------------------------------------------------------------
// Certificate parsing/verification (ECDSA P-256 chains only)
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

struct ParsedCert {
    tbs: Vec<u8>,
    public_key: PublicKey,
    signature: (Vec<u8>, Vec<u8>), // (r, s), big-endian
    self_signed_name: bool,       // issuer == subject (raw bytes)
    not_before: i64,
    not_after: i64,
    sans_dns: Vec<String>,
    sans_ip: Vec<IpAddr>,
    cn: Option<String>,
}

fn parse_time(tag: u8, text: &[u8]) -> io::Result<i64> {
    let text = std::str::from_utf8(text).map_err(|_| bad("tls: bad validity time"))?;
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
    let mut int = |reader: &mut Der<'_>| -> io::Result<Vec<u8>> {
        let (tag, content, _) = reader.read()?;
        if tag != 0x02 {
            return Err(bad("tls: bad ECDSA signature"));
        }
        let bytes = content.strip_prefix(&[0]).unwrap_or(content);
        let mut out = vec![0u8; 32];
        if bytes.len() > 32 {
            return Err(bad("tls: bad ECDSA signature"));
        }
        out[32 - bytes.len()..].copy_from_slice(bytes);
        Ok(out)
    };
    Ok((int(&mut reader)?, int(&mut reader)?))
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
    let _alg = cert.read()?;
    let (tag, sig_bits, _) = cert.read()?;
    if tag != 0x03 || sig_bits.is_empty() || sig_bits[0] != 0 {
        return Err(bad("tls: bad certificate signature"));
    }
    let signature = parse_ecdsa_signature(&sig_bits[1..])?;
    let public_key =
        crate::x509::parse_public_key(der_bytes).ok_or_else(|| bad("tls: no P-256 key in certificate"))?;

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
    let _spki = tbs.read()?;
    let mut sans_dns = Vec::new();
    let mut sans_ip = Vec::new();
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
            // subjectAltName OID 2.5.29.17 == 55 1d 11
            if oid != [0x55, 0x1d, 0x11] {
                continue;
            }
            // Optional critical BOOLEAN, then OCTET STRING value.
            let (vtag, value, _) = ext_reader.read()?;
            let value = if vtag == 0x01 {
                ext_reader.read()?.1
            } else {
                value
            };
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
        public_key,
        signature,
        self_signed_name: issuer_full == subject_full,
        not_before,
        not_after,
        sans_dns,
        sans_ip,
        cn,
    })
}

fn ecdsa_verify(key: &PublicKey, digest: &[u8; 32], sig: &(Vec<u8>, Vec<u8>)) -> bool {
    let r: [u8; 32] = match sig.0.as_slice().try_into() {
        Ok(v) => v,
        Err(_) => return false,
    };
    let s: [u8; 32] = match sig.1.as_slice().try_into() {
        Ok(v) => v,
        Err(_) => return false,
    };
    key.verify(digest, &r, &s)
}

fn verify_presented_chain(certs: &[ParsedCert], server_name: &str) -> io::Result<()> {
    if certs.is_empty() {
        return Err(bad("tls: empty certificate chain"));
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let leaf = &certs[0];
    if now < leaf.not_before || now > leaf.not_after {
        return Err(bad("tls: certificate outside validity window"));
    }
    // Chain signatures up to a self-signed top.
    for pair in certs.windows(2) {
        let digest = sha256(&pair[0].tbs);
        if !ecdsa_verify(&pair[1].public_key, &digest, &pair[0].signature) {
            return Err(bad("tls: certificate chain signature invalid"));
        }
    }
    let top = &certs[certs.len() - 1];
    if !top.self_signed_name {
        return Err(bad("tls: certificate chain does not end at a self-signed cert"));
    }
    let digest = sha256(&top.tbs);
    if !ecdsa_verify(&top.public_key, &digest, &top.signature) {
        return Err(bad("tls: top certificate is not self-signed"));
    }
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
pub struct TlsReadHalf {
    stream: TcpStream,
    cipher: Cipher,
    plain: std::collections::VecDeque<u8>,
}

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
pub struct TlsWriteHalf {
    stream: TcpStream,
    cipher: Cipher,
}

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

/// Run the TLS 1.2 client handshake over an established TCP
/// connection and split it into read/write halves. Verifies
/// the presented chain unless insecure_skip_verify (the
/// ServerKeyExchange signature is always verified unless
/// skipping: without it the handshake proves nothing).
pub fn connect(
    stream: TcpStream,
    server_name: &str,
    insecure_skip_verify: bool,
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
    if cursor.u16()? != SUITE_ECDHE_ECDSA_AES128_GCM_SHA256 {
        return Err(bad("tls: server selected an unsupported cipher suite"));
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
        verify_presented_chain(&chain, server_name)?;
    }
    let leaf_key = chain[0].public_key;

    let (msg_type, body, _) = hs.next()?;
    if msg_type == 13 {
        return Err(bad("tls: client authentication not supported"));
    }
    if msg_type != 12 {
        return Err(bad("tls: expected ServerKeyExchange"));
    }
    // ECParameters: named_curve secp256r1 + point, then signature.
    if body.len() < 4 || body[0] != 3 || body[1..3] != [0, 23] {
        return Err(bad("tls: unsupported ServerKeyExchange parameters"));
    }
    let point_len = body[3] as usize;
    let params_end = 4 + point_len;
    let point_bytes = body.get(4..params_end).ok_or_else(|| bad("tls: truncated SKE point"))?;
    let server_public =
        PublicKey::decode(point_bytes).ok_or_else(|| bad("tls: bad SKE point"))?;
    let mut sig_cursor = Cursor::new(body.get(params_end..).ok_or_else(|| bad("tls: truncated SKE"))?);
    let hash_alg = sig_cursor.u8()?;
    let sig_alg = sig_cursor.u8()?;
    if hash_alg != 4 || sig_alg != 3 {
        return Err(bad("tls: unsupported SKE signature algorithm"));
    }
    let sig_len = sig_cursor.u16()? as usize;
    let sig_der = sig_cursor.take(sig_len)?;
    if !insecure_skip_verify {
        let mut signed = Vec::with_capacity(64 + params_end);
        signed.extend_from_slice(&client_random);
        signed.extend_from_slice(&server_random);
        signed.extend_from_slice(&body[..params_end]);
        let digest = sha256(&signed);
        let sig = parse_ecdsa_signature(sig_der)?;
        if !ecdsa_verify(&leaf_key, &digest, &sig) {
            return Err(bad("tls: ServerKeyExchange signature invalid"));
        }
    }

    let (msg_type, _, _) = hs.next()?;
    if msg_type != 14 {
        return Err(bad("tls: expected ServerHelloDone"));
    }

    // --- client flight ---
    let (secret, our_public) = PrivateKey::generate();
    let premaster = secret
        .ecdh(&server_public)
        .ok_or_else(|| bad("tls: ECDHE failed"))?;
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

    let mut cke = vec![65u8];
    cke.extend_from_slice(&our_public.encode_uncompressed());
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
