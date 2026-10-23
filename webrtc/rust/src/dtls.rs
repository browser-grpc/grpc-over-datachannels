//! DTLS 1.2 (RFC 6347) client and server, ECDHE-ECDSA with
//! AES-128-GCM-SHA256 only, extended master secret, `use_srtp`
//! negotiation (RFC 5764), and certificates pinned by SDP fingerprint.
//!
//! The handshake is a blocking flight machine over a packet IO: retransmit
//! on a 1s→2s backoff timer, reassemble fragmented handshake messages,
//! and protect epoch-1 records with AES-GCM (explicit nonce = epoch‖seq).
//! Verified against OpenSSL `s_server`/`s_client -dtls1_2`.

use alloc::string::{String, ToString};
use alloc::vec::Vec;
use crate::crypto::{aes128_gcm_decrypt, aes128_gcm_encrypt, prf, random_bytes, sha256};
use crate::p256::{PrivateKey, PublicKey};
use crate::proto_gen::{dtls_content, dtls_handshake};
use crate::x509::{fingerprint_of_der, Certificate};
#[cfg(feature = "std")]
use std::collections::HashMap;
#[cfg(not(feature = "std"))]
use alloc::collections::BTreeMap as HashMap;
use crate::io;
use core::time::Duration;
#[cfg(feature = "std")]
use std::net::UdpSocket;

pub trait DtlsIo {
    fn send_packet(&mut self, packet: &[u8]) -> io::Result<()>;
    /// Ok(None) on timeout.
    fn recv_packet(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>>;
}

#[cfg(feature = "std")]
pub struct UdpDtlsIo {
    pub socket: UdpSocket,
    pub peer: std::net::SocketAddr,
}

#[cfg(feature = "std")]
impl DtlsIo for UdpDtlsIo {
    fn send_packet(&mut self, packet: &[u8]) -> io::Result<()> {
        self.socket.send_to(packet, self.peer)?;
        Ok(())
    }
    fn recv_packet(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        self.socket.set_read_timeout(Some(timeout))?;
        let mut buf = vec![0u8; 65536];
        match self.socket.recv_from(&mut buf) {
            Ok((n, _)) => {
                buf.truncate(n);
                Ok(Some(buf))
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
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    Client,
    Server,
}

pub struct DtlsConfig {
    pub certificate: Certificate,
    /// Expected SHA-256 fingerprint of the peer certificate (SDP form,
    /// colon-separated). When set, a mismatch aborts the handshake.
    pub expected_peer_fingerprint: Option<String>,
    /// WebRTC peers always present certificates; OpenSSL test clients
    /// may not, so this is configurable.
    pub require_peer_certificate: bool,
    /// Offer/accept RFC 5077 session tickets (resumption). The
    /// wire behavior is unchanged unless this is set.
    pub session_resumption: bool,
    /// Server-side ticket sealing key (32 bytes). Required on a
    /// server for tickets to be issued or honored; clients ignore
    /// it. Sealing goes through the installed crypto backend.
    pub session_ticket_key: Option<[u8; 32]>,
    /// RFC 9146 connection id we ask the peer to send us
    /// (muxed peers set this so a shared socket can route
    /// epoch-1 records without a source address). None never
    /// offers the extension.
    pub connection_id: Option<Vec<u8>>,
    /// Private DcPairHint extension value (the remote peer's
    /// ICE ufrag) so a mux can route the first ClientHello
    /// flight deterministically; set only on muxed clients.
    pub pair_hint: Option<Vec<u8>>,
}

/// Resumption state from a server-issued session ticket
/// (RFC 5077 shape). The ticket is opaque and server-sealed;
/// the rest is the client-side session cache. Identity is not
/// weakened by resumption: the peer certificate travels inside
/// the sealed ticket, and `check_peer_fingerprint` runs against
/// it exactly as in a full handshake.
#[derive(Clone, Debug)]
pub struct DtlsSession {
    pub ticket: Vec<u8>,
    pub master_secret: Vec<u8>,
    pub peer_certificate: Vec<u8>,
    pub srtp_profile: Option<u16>,
}

const TICKET_LIFETIME_SECS: u64 = 3600;
const TICKET_AAD: &[u8] = b"grpcdc-dtls-ticket-v1";

/// Seal session state into a ticket (AES-128-GCM via the
/// installed crypto backend; the AES key is the first half of
/// the 32-byte ticket key).
fn seal_ticket(
    key: &[u8; 32],
    master_secret: &[u8],
    srtp_profile: Option<u16>,
    peer_certificate: &[u8],
) -> Vec<u8> {
    let mut plain = Vec::new();
    plain.extend_from_slice(master_secret);
    plain.extend_from_slice(&srtp_profile.unwrap_or(0xffff).to_be_bytes());
    plain.extend_from_slice(&crate::platform::wall_now_secs().to_be_bytes());
    plain.extend_from_slice(&(peer_certificate.len() as u32).to_be_bytes()[1..]);
    plain.extend_from_slice(peer_certificate);
    let aes_key: &[u8; 16] = key[..16].try_into().unwrap();
    let nonce_bytes = crate::crypto::random_bytes(12);
    let nonce: &[u8; 12] = nonce_bytes.as_slice().try_into().unwrap();
    let (ct, tag) = crate::crypto::aes128_gcm_encrypt(aes_key, nonce, &plain, TICKET_AAD);
    let mut ticket = nonce_bytes;
    ticket.extend_from_slice(&ct);
    ticket.extend_from_slice(&tag);
    ticket
}

/// Open a ticket; None when malformed, tampered, or expired.
fn open_ticket(key: &[u8; 32], ticket: &[u8]) -> Option<DtlsSession> {
    if ticket.len() < 12 + 16 {
        return None;
    }
    let (nonce, rest) = ticket.split_at(12);
    let (ct, tag) = rest.split_at(rest.len() - 16);
    let aes_key: &[u8; 16] = key[..16].try_into().unwrap();
    let plain = crate::crypto::aes128_gcm_decrypt(
        aes_key,
        nonce.try_into().unwrap(),
        ct,
        TICKET_AAD,
        tag.try_into().unwrap(),
    )?;
    if plain.len() < 48 + 2 + 8 + 3 {
        return None;
    }
    let master_secret = plain[..48].to_vec();
    let profile_raw = u16::from_be_bytes([plain[48], plain[49]]);
    let issued = u64::from_be_bytes(plain[50..58].try_into().unwrap());
    let now = crate::platform::wall_now_secs();
    if now > 0 && issued > 0 && now.saturating_sub(issued) > TICKET_LIFETIME_SECS {
        return None;
    }
    let cert_len =
        ((plain[58] as usize) << 16) | ((plain[59] as usize) << 8) | plain[60] as usize;
    if plain.len() < 61 + cert_len {
        return None;
    }
    Some(DtlsSession {
        ticket: ticket.to_vec(),
        master_secret,
        peer_certificate: plain[61..61 + cert_len].to_vec(),
        srtp_profile: if profile_raw == 0xffff { None } else { Some(profile_raw) },
    })
}

const DTLS_1_2: [u8; 2] = [0xFE, 0xFD];
const SUITE: u16 = 0xC02B;
const GROUP_SECP256R1: u16 = 23;

struct Record {
    content_type: u8,
    body: Vec<u8>, // plaintext (already decrypted for epoch 1)
}

struct EpochKeys {
    key: [u8; 16],
    salt: [u8; 4],
}

pub struct Dtls<I: DtlsIo> {
    io: I,
    role: Role,
    write_keys: Option<EpochKeys>,
    read_keys: Option<EpochKeys>,
    write_seq: u64, // epoch-1 sequence
    epoch0_seq: u64,
    master_secret: Vec<u8>,
    client_random: [u8; 32],
    server_random: [u8; 32],
    peer_certificate: Option<Vec<u8>>,
    negotiated_srtp_profile: Option<u16>,
    read_highest_seq: Option<u64>,
    read_replay_window: u64,
    /// Resumption state captured from a server NewSessionTicket
    /// (client) — take it with `take_session`.
    session: Option<DtlsSession>,
    /// This connection was established by an abbreviated
    /// (ticket-resumed) handshake.
    resumed: bool,
    /// Peer's announced connection id (records we send carry
    /// it, epoch 1 only); None when not negotiated.
    send_cid: Option<Vec<u8>>,
    /// Our announced connection id (records we receive carry
    /// it once the peer honors the extension; the parser
    /// falls back to the plain layout for peers that don't).
    recv_cid: Option<Vec<u8>>,
}

fn err(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}

// ---------------------------------------------------------------------------
// byte readers/writers
// ---------------------------------------------------------------------------

struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }
    fn u8(&mut self) -> io::Result<u8> {
        let v = self.data.get(self.pos).copied().ok_or_else(|| err("short read u8"))?;
        self.pos += 1;
        Ok(v)
    }
    fn u16(&mut self) -> io::Result<u16> {
        Ok(u16::from_be_bytes([self.u8()?, self.u8()?]))
    }
    fn u24(&mut self) -> io::Result<u32> {
        Ok(((self.u8()? as u32) << 16) | ((self.u8()? as u32) << 8) | self.u8()? as u32)
    }
    fn take(&mut self, n: usize) -> io::Result<&'a [u8]> {
        let out = self.data.get(self.pos..self.pos + n).ok_or_else(|| err("short read"))?;
        self.pos += n;
        Ok(out)
    }
    fn vec8(&mut self) -> io::Result<&'a [u8]> {
        let n = self.u8()? as usize;
        self.take(n)
    }
    fn vec16(&mut self) -> io::Result<&'a [u8]> {
        let n = self.u16()? as usize;
        self.take(n)
    }
    fn vec24(&mut self) -> io::Result<&'a [u8]> {
        let n = self.u24()? as usize;
        self.take(n)
    }
    fn done(&self) -> bool {
        self.pos >= self.data.len()
    }
}

fn put_u24(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&(v as u32).to_be_bytes()[1..]);
}

fn handshake_message(msg_type: u8, msg_seq: u16, body: &[u8]) -> Vec<u8> {
    let mut out = vec![msg_type];
    put_u24(&mut out, body.len() as u32);
    out.extend_from_slice(&msg_seq.to_be_bytes());
    put_u24(&mut out, 0);
    put_u24(&mut out, body.len() as u32);
    out.extend_from_slice(body);
    out
}

// ---------------------------------------------------------------------------
// connection
// ---------------------------------------------------------------------------

impl<I: DtlsIo> Dtls<I> {
    pub fn peer_fingerprint(&self) -> Option<String> {
        self.peer_certificate.as_deref().map(fingerprint_of_der)
    }

    pub fn srtp_profile(&self) -> Option<u16> {
        self.negotiated_srtp_profile
    }

    /// RFC 5705 exporter (used for DTLS-SRTP keying material).
    pub fn export_keying_material(&self, label: &str, context: &[u8], len: usize) -> Vec<u8> {
        let mut seed = self.client_random.to_vec();
        seed.extend_from_slice(&self.server_random);
        seed.extend_from_slice(context);
        prf(&self.master_secret, label, &seed, len)
    }

    fn send_record(&mut self, content_type: u8, epoch: u16, body: &[u8]) -> io::Result<Vec<u8>> {
        let packet = if epoch == 0 {
            let mut out = vec![content_type];
            out.extend_from_slice(&DTLS_1_2);
            out.extend_from_slice(&0u16.to_be_bytes());
            out.extend_from_slice(&self.epoch0_seq_next().to_be_bytes()[2..]);
            // RFC 9146: once the peer's connection id is known
            // it rides every record (the first ClientHello is
            // the only exception — send_cid is unset then).
            out.extend_from_slice(self.send_cid.as_deref().unwrap_or(&[]));
            out.extend_from_slice(&(body.len() as u16).to_be_bytes());
            out.extend_from_slice(body);
            out
        } else {
            let keys = self.write_keys.as_ref().ok_or_else(|| err("no write keys"))?;
            let seq = self.write_seq;
            self.write_seq += 1;
            let mut explicit = Vec::with_capacity(8);
            explicit.extend_from_slice(&1u16.to_be_bytes());
            explicit.extend_from_slice(&seq.to_be_bytes()[2..]);
            let mut nonce = [0u8; 12];
            nonce[..4].copy_from_slice(&keys.salt);
            nonce[4..].copy_from_slice(&explicit);
            // RFC 9146: once the peer's connection id is
            // known, every record carries it between the
            // sequence and the length (the first ClientHello
            // predates the knowledge, so it is the only
            // exception); the AAD covers it in our profile.
            let cid: &[u8] = self.send_cid.as_deref().unwrap_or(&[]);
            let mut aad = Vec::with_capacity(13 + cid.len());
            aad.extend_from_slice(&explicit);
            aad.extend_from_slice(cid);
            aad.push(content_type);
            aad.extend_from_slice(&DTLS_1_2);
            aad.extend_from_slice(&(body.len() as u16).to_be_bytes());
            let (ciphertext, tag) = aes128_gcm_encrypt(&keys.key, &nonce, body, &aad);
            let mut out = vec![content_type];
            out.extend_from_slice(&DTLS_1_2);
            out.extend_from_slice(&1u16.to_be_bytes());
            out.extend_from_slice(&seq.to_be_bytes()[2..]);
            out.extend_from_slice(cid);
            out.extend_from_slice(&((8 + ciphertext.len() + 16) as u16).to_be_bytes());
            out.extend_from_slice(&explicit);
            out.extend_from_slice(&ciphertext);
            out.extend_from_slice(&tag);
            out
        };
        self.io.send_packet(&packet)?;
        Ok(packet)
    }

    fn epoch0_seq_next(&mut self) -> u64 {
        let v = self.epoch0_seq;
        self.epoch0_seq += 1;
        v
    }

    /// Parse every record in one datagram (peers may coalesce records,
    /// e.g. OpenSSL sends CCS+Finished in a single packet).
    fn parse_records(&mut self, packet: &[u8]) -> io::Result<Vec<Record>> {
        let mut out = Vec::new();
        let mut offset = 0;
        while offset < packet.len() {
            let (record, next) = self.parse_record_at(&packet[offset..])?;
            out.push(record);
            offset += next;
        }
        Ok(out)
    }

    /// Parses records until the first failure, returning what
    /// parsed. A coalesced flight may place an epoch-1 record (the
    /// Finished) in the same datagram as the epoch-0 records that
    /// establish the keys; the handshake pump feeds the prefix and
    /// defers the datagram instead of discarding the whole packet.
    fn parse_records_partial(&mut self, packet: &[u8]) -> (Vec<Record>, Option<io::Error>) {
        let mut out = Vec::new();
        let mut offset = 0;
        while offset < packet.len() {
            match self.parse_record_at(&packet[offset..]) {
                Ok((record, next)) => {
                    out.push(record);
                    offset += next;
                }
                Err(e) => return (out, Some(e)),
            }
        }
        (out, None)
    }

    fn parse_record_at(&mut self, packet: &[u8]) -> io::Result<(Record, usize)> {
        let mut r = Reader::new(packet);
        let content_type = r.u8()?;
        let _version = [r.u8()?, r.u8()?];
        let epoch = r.u16()?;
        let mut seq_bytes = [0u8; 8];
        seq_bytes[2..].copy_from_slice(r.take(6)?);
        let sequence = u64::from_be_bytes(seq_bytes);
        // RFC 9146: when we announced a connection id, epoch-1
        // records from honoring peers carry it between the
        // sequence and the length (and inside the AAD). Peers
        // that ignore the extension (browsers) keep the plain
        // layout; accept both.
        let mut cid: &[u8] = &[];
        {
            if let Some(ours) = &self.recv_cid {
                let at = r.pos;
                if packet.len() >= at + ours.len()
                    && &packet[at..at + ours.len()] == ours.as_slice()
                {
                    cid = ours;
                    r.pos += ours.len();
                }
            }
        }
        let len = r.u16()? as usize;
        let body = r.take(len)?.to_vec();
        let consumed = r.pos;
        if epoch == 0 {
            return Ok((Record { content_type, body }, consumed));
        }
        // epoch 1: explicit nonce(8) || ciphertext || tag(16)
        if body.len() < 8 + 16 {
            return Err(err("short epoch-1 record"));
        }
        let keys = self.read_keys.as_ref().ok_or_else(|| err("no read keys"))?;
        let explicit = &body[..8];
        let ciphertext = &body[8..body.len() - 16];
        let tag: [u8; 16] = body[body.len() - 16..].try_into().unwrap();
        let mut nonce = [0u8; 12];
        nonce[..4].copy_from_slice(&keys.salt);
        nonce[4..].copy_from_slice(explicit);
        let plaintext_len = ciphertext.len();
        // AAD uses the record header's epoch||sequence (RFC 5246), which
        // is independent of the sender-chosen explicit nonce.
        let mut aad = Vec::with_capacity(13 + cid.len());
        aad.extend_from_slice(&epoch.to_be_bytes());
        aad.extend_from_slice(&sequence.to_be_bytes()[2..]);
        aad.extend_from_slice(cid);
        aad.push(content_type);
        aad.extend_from_slice(&DTLS_1_2);
        aad.extend_from_slice(&(plaintext_len as u16).to_be_bytes());
        let plaintext = aes128_gcm_decrypt(&keys.key, &nonce, ciphertext, &aad, &tag)
            .ok_or_else(|| err("record authentication failed"))?;
        // replay window (64 records)
        match self.read_highest_seq {
            None => {
                self.read_highest_seq = Some(sequence);
                self.read_replay_window = 1;
            }
            Some(highest) => {
                if sequence > highest {
                    let shift = (sequence - highest).min(64);
                    self.read_replay_window = if shift >= 64 {
                        1
                    } else {
                        (self.read_replay_window << shift) | 1
                    };
                    self.read_highest_seq = Some(sequence);
                } else {
                    let diff = highest - sequence;
                    if diff >= 64 || (self.read_replay_window >> diff) & 1 == 1 {
                        return Err(err("replayed record"));
                    }
                    self.read_replay_window |= 1 << diff;
                }
            }
        }
        Ok((Record { content_type, body: plaintext }, consumed))
    }
}

// ---------------------------------------------------------------------------
// handshake machinery
// ---------------------------------------------------------------------------

struct Frag {
    total: usize,
    buf: Vec<u8>,
    have: Vec<bool>,
}

impl Frag {
    fn add(&mut self, offset: usize, data: &[u8]) {
        for (i, &b) in data.iter().enumerate() {
            if offset + i < self.total {
                self.buf[offset + i] = b;
                self.have[offset + i] = true;
            }
        }
    }
    fn complete(&self) -> bool {
        self.have.iter().all(|&h| h)
    }
}

#[derive(Default)]
struct Hs {
    send_seq: u16,
    expect_seq: u16,
    fragments: HashMap<(u8, u16), Frag>,
    ready: HashMap<u16, (u8, Vec<u8>, Vec<u8>)>, // seq -> (type, raw, body)
    byte_buf: Vec<u8>,
    transcript: Vec<u8>,
    ccs_received: bool,
    /// Packets that arrived before their epoch keys existed (a peer may
    /// coalesce ClientKeyExchange + Finished into one datagram).
    pending: Vec<Vec<u8>>,
}

impl Hs {
    fn feed_handshake_bytes(&mut self, bytes: &[u8]) {
        self.byte_buf.extend_from_slice(bytes);
        loop {
            if self.byte_buf.len() < 12 {
                return;
            }
            let msg_type = self.byte_buf[0];
            let total = ((self.byte_buf[1] as usize) << 16)
                | ((self.byte_buf[2] as usize) << 8)
                | self.byte_buf[3] as usize;
            let seq = u16::from_be_bytes([self.byte_buf[4], self.byte_buf[5]]);
            let offset = ((self.byte_buf[6] as usize) << 16)
                | ((self.byte_buf[7] as usize) << 8)
                | self.byte_buf[8] as usize;
            let frag_len = ((self.byte_buf[9] as usize) << 16)
                | ((self.byte_buf[10] as usize) << 8)
                | self.byte_buf[11] as usize;
            if self.byte_buf.len() < 12 + frag_len {
                return;
            }
            let frag: Vec<u8> = self.byte_buf.drain(..12 + frag_len).collect();
            let entry = self
                .fragments
                .entry((msg_type, seq))
                .or_insert_with(|| Frag {
                    total,
                    buf: vec![0u8; total],
                    have: vec![false; total],
                });
            entry.add(offset, &frag[12..]);
            if entry.complete() {
                let done = self.fragments.remove(&(msg_type, seq)).unwrap();
                let mut raw = vec![msg_type];
                put_u24(&mut raw, done.total as u32);
                raw.extend_from_slice(&seq.to_be_bytes());
                put_u24(&mut raw, 0);
                put_u24(&mut raw, done.total as u32);
                raw.extend_from_slice(&done.buf);
                self.ready.insert(seq, (msg_type, raw, done.buf));
            }
        }
    }

    fn next(&mut self) -> Option<(u8, Vec<u8>, Vec<u8>)> {
        let msg = self.ready.remove(&self.expect_seq)?;
        self.expect_seq += 1;
        Some(msg)
    }

    fn hash(&self) -> [u8; 32] {
        sha256(&self.transcript)
    }
}

fn der_int_bytes(bytes: &[u8]) -> Vec<u8> {
    let mut v = bytes;
    while v.len() > 1 && v[0] == 0 {
        v = &v[1..];
    }
    let mut content = Vec::new();
    if v.first().map_or(false, |b| b & 0x80 != 0) {
        content.push(0);
    }
    content.extend_from_slice(v);
    let mut out = vec![0x02];
    out.push(content.len() as u8);
    out.extend_from_slice(&content);
    out
}

fn ecdsa_sig_der(r: &[u8; 32], s: &[u8; 32]) -> Vec<u8> {
    let mut body = der_int_bytes(r);
    body.extend_from_slice(&der_int_bytes(s));
    let mut out = vec![0x30, body.len() as u8];
    out.extend_from_slice(&body);
    out
}

fn parse_ecdsa_sig_der(der: &[u8]) -> io::Result<([u8; 32], [u8; 32])> {
    let mut rd = Reader::new(der);
    if rd.u8()? != 0x30 {
        return Err(err("bad signature SEQUENCE"));
    }
    let _ = rd.u8()?;
    let read_int = |rd: &mut Reader| -> io::Result<[u8; 32]> {
        if rd.u8()? != 0x02 {
            return Err(err("bad signature INTEGER"));
        }
        let bytes = rd.vec8()?;
        let mut out = [0u8; 32];
        let trimmed = if bytes.first() == Some(&0) && bytes.len() > 1 {
            &bytes[1..]
        } else {
            bytes
        };
        if trimmed.len() > 32 {
            return Err(err("signature integer too long"));
        }
        out[32 - trimmed.len()..].copy_from_slice(trimmed);
        Ok(out)
    };
    let r = read_int(&mut rd)?;
    let s = read_int(&mut rd)?;
    Ok((r, s))
}

fn cert_list_body(cert_der: &[u8]) -> Vec<u8> {
    let mut entry = Vec::new();
    put_u24(&mut entry, cert_der.len() as u32);
    entry.extend_from_slice(cert_der);
    let mut out = Vec::new();
    put_u24(&mut out, entry.len() as u32);
    out.extend_from_slice(&entry);
    out
}

fn parse_first_cert(body: &[u8]) -> io::Result<Vec<u8>> {
    let mut r = Reader::new(body);
    let list = r.vec24()?;
    let mut lr = Reader::new(list);
    Ok(lr.vec24()?.to_vec())
}

macro_rules! dtls_new {
    ($io:expr, $role:expr) => {
        Dtls {
            io: $io,
            role: $role,
            write_keys: None,
            read_keys: None,
            write_seq: 0,
            epoch0_seq: 0,
            master_secret: Vec::new(),
            client_random: [0u8; 32],
            server_random: [0u8; 32],
            peer_certificate: None,
            negotiated_srtp_profile: None,
            read_highest_seq: None,
            read_replay_window: 0,
            session: None,
            resumed: false,
            send_cid: None,
            recv_cid: None,
        }
    };
}

impl<I: DtlsIo> Dtls<I> {
    fn send_hs(&mut self, hs: &mut Hs, msg_type: u8, body: &[u8], epoch: u16) -> io::Result<Vec<u8>> {
        let raw = handshake_message(msg_type, hs.send_seq, body);
        hs.send_seq += 1;
        let packet = self.send_record(dtls_content::HANDSHAKE, epoch, &raw)?;
        hs.transcript.extend_from_slice(&raw);
        Ok(packet)
    }

    /// Receive records until `ready` yields the next handshake message or
    /// the overall deadline/retry budget is exhausted. Retransmits
    /// `flight` on each 1s timeout (DTLS flight retransmission).
    fn pump_until_message(
        &mut self,
        hs: &mut Hs,
        flight: &[Vec<u8>],
    ) -> io::Result<(u8, Vec<u8>, Vec<u8>)> {
        let mut retries = 0;
        loop {
            if let Some(msg) = hs.next() {
                return Ok(msg);
            }
            // Retry packets deferred until epoch keys were installed.
            let mut i = 0;
            let mut progressed = false;
            while i < hs.pending.len() {
                let (records, parse_err) = self.parse_records_partial(&hs.pending[i].clone());
                if parse_err.is_none() {
                    hs.pending.remove(i);
                    progressed = true;
                } else {
                    // Deferred (or undecodable): keep the datagram
                    // for a later pass; the reassembly layer dedupes
                    // records that get fed twice.
                    i += 1;
                }
                for record in records {
                    match record.content_type {
                        t if t == dtls_content::HANDSHAKE => {
                            hs.feed_handshake_bytes(&record.body)
                        }
                        t if t == dtls_content::CHANGE_CIPHER_SPEC => {
                            hs.ccs_received = true
                        }
                        _ => {}
                    }
                }
            }
            if progressed {
                continue;
            }
            match self.io.recv_packet(Duration::from_millis(1000))? {
                Some(packet) => {
                    let (records, parse_err) = self.parse_records_partial(&packet);
                    for record in records {
                        match record.content_type {
                            t if t == dtls_content::HANDSHAKE => {
                                hs.feed_handshake_bytes(&record.body)
                            }
                            t if t == dtls_content::CHANGE_CIPHER_SPEC => {
                                hs.ccs_received = true
                            }
                            t if t == dtls_content::ALERT => {
                                return Err(err("fatal alert from peer during handshake"))
                            }
                            _ => {}
                        }
                    }
                    match parse_err {
                        None => {}
                        Some(_) if self.read_keys.is_none() => hs.pending.push(packet),
                        Some(e) => return Err(e),
                    }
                }
                None => {
                    retries += 1;
                    if retries > 6 {
                        return Err(err("handshake timed out"));
                    }
                    for packet in flight {
                        self.io.send_packet(packet)?;
                    }
                }
            }
        }
    }

    fn derive_keys(&mut self, master: &[u8]) {
        let mut seed = self.server_random.to_vec();
        seed.extend_from_slice(&self.client_random);
        let block = prf(master, "key expansion", &seed, 40);
        let (ck, rest) = block.split_at(16);
        let (sk, rest) = rest.split_at(16);
        let (civ, siv) = rest.split_at(4);
        let client_keys = EpochKeys {
            key: ck.try_into().unwrap(),
            salt: civ[..4].try_into().unwrap(),
        };
        let server_keys = EpochKeys {
            key: sk.try_into().unwrap(),
            salt: siv[..4].try_into().unwrap(),
        };
        match self.role {
            Role::Client => {
                self.write_keys = Some(client_keys);
                self.read_keys = Some(server_keys);
            }
            Role::Server => {
                self.write_keys = Some(server_keys);
                self.read_keys = Some(client_keys);
            }
        }
    }

    fn check_peer_fingerprint(&self, config: &DtlsConfig) -> io::Result<()> {
        if let Some(expected) = &config.expected_peer_fingerprint {
            let actual = self
                .peer_certificate
                .as_deref()
                .map(fingerprint_of_der)
                .ok_or_else(|| err("peer presented no certificate"))?;
            if !actual.eq_ignore_ascii_case(expected) {
                return Err(err("peer certificate fingerprint mismatch"));
            }
        }
        Ok(())
    }

    // -- application data -----------------------------------------------------

    pub fn send_app(&mut self, data: &[u8]) -> io::Result<()> {
        self.send_record(dtls_content::APPLICATION_DATA, 1, data)?;
        Ok(())
    }

    /// Whether this connection came from an abbreviated
    /// (ticket-resumed) handshake rather than a full one.
    pub fn was_resumed(&self) -> bool {
        self.resumed
    }

    /// Send a close_notify alert (best effort). Lets the peer
    /// release the session — e.g. a `s_server -naccept 2` moves
    /// on to the next connection only once this one closes.
    pub fn close(&mut self) {
        let _ = self.send_record(dtls_content::ALERT, 1, &[1, 0]);
    }

    pub fn recv_app(&mut self) -> io::Result<Vec<u8>> {
        loop {
            match self.io.recv_packet(Duration::from_secs(60))? {
                Some(packet) => {
                    for record in self.parse_records(&packet)? {
                        match record.content_type {
                            t if t == dtls_content::APPLICATION_DATA => return Ok(record.body),
                            t if t == dtls_content::ALERT => {
                                return Err(err("alert from peer"))
                            }
                            _ => continue, // e.g. post-handshake tickets: ignore
                        }
                    }
                }
                None => return Err(err("timed out waiting for application data")),
            }
        }
    }

    pub fn recv_app_timeout(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        let clock = crate::platform::clock();
        let deadline_ms = clock.now_ms() + timeout.as_millis() as u64;
        loop {
            let remaining = Duration::from_millis(
                deadline_ms.saturating_sub(clock.now_ms()),
            );
            if remaining.is_zero() {
                return Ok(None);
            }
            match self.io.recv_packet(remaining)? {
                Some(packet) => {
                    for record in self.parse_records(&packet)? {
                        match record.content_type {
                            t if t == dtls_content::APPLICATION_DATA => {
                                return Ok(Some(record.body))
                            }
                            t if t == dtls_content::ALERT => {
                                return Err(err("alert from peer"))
                            }
                            _ => continue,
                        }
                    }
                }
                None => return Ok(None),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// ClientHello / ServerHello bodies
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
fn client_hello_body(
    random: &[u8; 32],
    cookie: &[u8],
    ems: bool,
    session_ticket: Option<&[u8]>,
    session_id: &[u8],
    connection_id: Option<&[u8]>,
    pair_hint: Option<&[u8]>,
) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&DTLS_1_2);
    out.extend_from_slice(random);
    // Session id: empty normally; a random id when attempting
    // ticket resumption — the server echoes it to signal the
    // ticket was honored (the OpenSSL convention).
    out.push(session_id.len() as u8);
    out.extend_from_slice(session_id);
    out.push(cookie.len() as u8);
    out.extend_from_slice(cookie);
    out.extend_from_slice(&[0, 2, 0xC0, 0x2B]); // cipher suites: len + C02B
    out.extend_from_slice(&[1, 0]); // compression: null only
    let mut exts = Vec::new();
    // supported_groups: secp256r1 only
    exts.extend_from_slice(&10u16.to_be_bytes());
    exts.extend_from_slice(&[0, 4, 0, 2, 0, GROUP_SECP256R1 as u8]);
    // ec_point_formats: uncompressed
    exts.extend_from_slice(&11u16.to_be_bytes());
    exts.extend_from_slice(&[0, 2, 1, 0]);
    // signature_algorithms: vec16 length, then ecdsa_sha256, ecdsa_sha384,
    // rsa_pkcs1_sha256, rsa_pss_rsae_sha256
    exts.extend_from_slice(&13u16.to_be_bytes());
    exts.extend_from_slice(&[0, 10, 0, 8, 0x04, 0x03, 0x05, 0x03, 0x04, 0x01, 0x08, 0x04]);
    // use_srtp: AEAD_AES_128_GCM, AES128_CM_HMAC_SHA1_80, _32; MKI empty
    exts.extend_from_slice(&14u16.to_be_bytes());
    let srtp = [0u8, 6, 0, 7, 0, 1, 0, 2, 0];
    exts.extend_from_slice(&(srtp.len() as u16).to_be_bytes());
    exts.extend_from_slice(&srtp);
    if ems {
        exts.extend_from_slice(&23u16.to_be_bytes());
        exts.extend_from_slice(&[0, 0]);
    }
    // session_ticket (35): empty offers support (server may send
    // a NewSessionTicket); non-empty attempts resumption.
    if let Some(ticket) = session_ticket {
        exts.extend_from_slice(&35u16.to_be_bytes());
        exts.extend_from_slice(&(ticket.len() as u16).to_be_bytes());
        exts.extend_from_slice(ticket);
    }
    // connection_id (54, RFC 9146): the cid we ask the server
    // to put on records it sends us (length-prefixed).
    if let Some(cid) = connection_id {
        exts.extend_from_slice(&crate::proto_gen::dtls_ext::CONNECTION_ID.to_be_bytes());
        exts.extend_from_slice(&((cid.len() + 1) as u16).to_be_bytes());
        exts.push(cid.len() as u8);
        exts.extend_from_slice(cid);
    }
    // DcPairHint (private): the remote peer's ICE ufrag, so a
    // shared-socket mux can route this first flight.
    if let Some(hint) = pair_hint {
        exts.extend_from_slice(&crate::proto_gen::dtls_ext::DC_PAIR_HINT.to_be_bytes());
        exts.extend_from_slice(&(hint.len() as u16).to_be_bytes());
        exts.extend_from_slice(hint);
    }
    out.extend_from_slice(&(exts.len() as u16).to_be_bytes());
    out.extend_from_slice(&exts);
    out
}

struct ServerHelloInfo {
    session_id: Vec<u8>,
    server_random: [u8; 32],
    ems: bool,
    srtp_profile: Option<u16>,
    /// Server accepted our session ticket (abbreviated handshake).
    resumed: bool,
    /// Server's announced connection id (RFC 9146).
    peer_cid: Option<Vec<u8>>,
}

fn parse_server_hello(body: &[u8]) -> io::Result<ServerHelloInfo> {
    let mut r = Reader::new(body);
    let _version = [r.u8()?, r.u8()?];
    let server_random: [u8; 32] = r.take(32)?.try_into().unwrap();
    let session_id = r.vec8()?.to_vec();
    let suite = r.u16()?;
    if suite != SUITE {
        return Err(err("server picked an unsupported cipher suite"));
    }
    let _compression = r.u8()?;
    let mut info = ServerHelloInfo {
        session_id,
        server_random,
        ems: false,
        srtp_profile: None,
        resumed: false,
        peer_cid: None,
    };
    if !r.done() {
        let exts = r.vec16()?;
        let mut er = Reader::new(exts);
        while !er.done() {
            let ty = er.u16()?;
            let data = er.vec16()?;
            match ty {
                23 => info.ems = true,
                crate::proto_gen::dtls_ext::CONNECTION_ID => {
                    let mut cr = Reader::new(data);
                    info.peer_cid = Some(cr.vec8()?.to_vec());
                }
                14 => {
                    let mut sr = Reader::new(data);
                    let profiles = sr.vec16()?;
                    if profiles.len() >= 2 {
                        info.srtp_profile =
                            Some(u16::from_be_bytes([profiles[0], profiles[1]]));
                    }
                }
                _ => {}
            }
        }
    }
    Ok(info)
}

impl<I: DtlsIo> Dtls<I> {
    /// DTLS client handshake (full). `config.certificate` is
    /// presented if the server requests one (WebRTC servers do).
    pub fn connect(io: I, config: &DtlsConfig) -> io::Result<Self> {
        Self::handshake(io, config, None)
    }

    /// DTLS client handshake attempting session resumption with
    /// state captured from an earlier connection (`take_session`).
    /// Falls back to a full handshake transparently when the
    /// server does not honor the ticket; the peer fingerprint
    /// check is enforced identically on both paths.
    pub fn connect_resumed(
        io: I,
        config: &DtlsConfig,
        session: &DtlsSession,
    ) -> io::Result<Self> {
        Self::handshake(io, config, Some(session))
    }

    /// Take resumption state captured from a NewSessionTicket,
    /// if the server sent one (requires `session_resumption`).
    pub fn take_session(&mut self) -> Option<DtlsSession> {
        self.session.take()
    }

    fn handshake(
        io: I,
        config: &DtlsConfig,
        resume: Option<&DtlsSession>,
    ) -> io::Result<Self> {
        let mut conn = dtls_new!(io, Role::Client);
        // Arm the receive cid before the first pump: a server
        // honoring our announced cid stamps it from its first
        // flight onward, so the record parser must recognize it
        // before ServerHello (mirrors accept()).
        conn.recv_cid = config.connection_id.clone();
        let mut hs = Hs::default();
        conn.client_random = random_bytes(32).try_into().unwrap();

        // First flight: ClientHello (re-sent with cookie on HelloVerify).
        // When resuming, offer a random session id; its echo in
        // ServerHello is the resumption signal.
        let offered_session_id: Vec<u8> = match resume {
            Some(_) => random_bytes(32),
            None => Vec::new(),
        };
        let mut cookie: Vec<u8> = Vec::new();
        let mut flight;
        let server_hello;
        'cookie_loop: loop {
            hs.transcript.clear();
            hs.send_seq = 0;
            hs.expect_seq = 0;
            let ticket_offer: Option<&[u8]> = match resume {
                Some(session) => Some(&session.ticket),
                None if config.session_resumption => Some(&[]),
                None => None,
            };
            let body = client_hello_body(
                &conn.client_random,
                &cookie,
                true,
                ticket_offer,
                &offered_session_id,
                config.connection_id.as_deref(),
                config.pair_hint.as_deref(),
            );
            let packet = conn.send_hs(&mut hs, dtls_handshake::CLIENT_HELLO, &body, 0)?;
            flight = vec![packet];
            loop {
                let (msg_type, raw, body) = conn.pump_until_message(&mut hs, &flight)?;
                match msg_type {
                    t if t == dtls_handshake::HELLO_VERIFY_REQUEST => {
                        let mut r = Reader::new(&body);
                        let _v = [r.u8()?, r.u8()?];
                        cookie = r.vec8()?.to_vec();
                        continue 'cookie_loop;
                    }
                    t if t == dtls_handshake::SERVER_HELLO => {
                        let mut hello = parse_server_hello(&body)?;
                        hello.resumed = resume.is_some()
                            && !offered_session_id.is_empty()
                            && hello.session_id == offered_session_id;
                        server_hello = hello;
                        hs.transcript.extend_from_slice(&raw);
                        break 'cookie_loop;
                    }
                    _ => return Err(err("unexpected message before ServerHello")),
                }
            }
        }
        conn.server_random = server_hello.server_random;
        conn.negotiated_srtp_profile = server_hello.srtp_profile;
        conn.send_cid = server_hello.peer_cid.clone();

        // Resumption is signalled by the echoed session id; when
        // that classification is unavailable, an abbreviated
        // flight straight to Finished also proves it (OpenSSL
        // omits the extension on resume). The encrypted Finished cannot
        // be ordered-pumped before keys exist, so classify at the
        // record layer: an epoch-1 handshake record already
        // deferred (or arriving next) with no plaintext flight in
        // hand means the server abbreviated.
        let mut peeked: Option<(u8, Vec<u8>, Vec<u8>)> = None;
        let resumed = match (resume, server_hello.resumed) {
            (Some(_), true) => true,
            (Some(_), false) => {
                fn epoch1_handshake(packet: &[u8]) -> bool {
                    let mut off = 0;
                    while off + 13 <= packet.len() {
                        let len =
                            u16::from_be_bytes([packet[off + 11], packet[off + 12]]) as usize;
                        if packet[off] == dtls_content::HANDSHAKE
                            && packet[off + 3] == 0
                            && packet[off + 4] == 1
                        {
                            return true;
                        }
                        off += 13 + len;
                    }
                    false
                }
                let mut abbreviated = hs.ready.is_empty()
                    && hs.pending.iter().any(|p| epoch1_handshake(p));
                if !abbreviated && hs.ready.is_empty() {
                    if let Ok(Some(packet)) =
                        conn.io.recv_packet(Duration::from_millis(1500))
                    {
                        abbreviated = epoch1_handshake(&packet);
                        hs.pending.push(packet);
                    }
                }
                abbreviated
            }
            _ => false,
        };
        if let (Some(session), true) = (resume, resumed) {
            // Abbreviated handshake (RFC 5077): the sealed ticket
            // carries the session; no certificates are exchanged,
            // and the fingerprint check runs against the ticket's
            // certificate, so identity enforcement is unchanged.
            conn.master_secret = session.master_secret.clone();
            conn.peer_certificate = Some(session.peer_certificate.clone());
            conn.negotiated_srtp_profile = session.srtp_profile;
            conn.resumed = true;
            conn.check_peer_fingerprint(config)?;
            conn.derive_keys(&conn.master_secret.clone());
            // Abbreviated flight order: the server's Finished
            // comes first (its verify_data covers the transcript
            // through ServerHello, snapshotted here), and ours
            // answers it — our verify_data covers the transcript
            // including the server's Finished, which is how
            // reference stacks check it.
            let mut resume_transcript = hs.transcript.clone();
            loop {
                let (msg_type, raw, body) = match peeked.take() {
                    Some(m) => m,
                    None => conn.pump_until_message(&mut hs, &flight)?,
                };
                if msg_type == dtls_handshake::NEW_SESSION_TICKET {
                    conn.store_ticket_body(&body);
                }
                if msg_type == dtls_handshake::FINISHED {
                    let expected = prf(
                        &conn.master_secret,
                        "server finished",
                        &sha256(&resume_transcript),
                        12,
                    );
                    if body != expected.as_slice() {
                        return Err(err("server Finished verification failed"));
                    }
                    hs.transcript.extend_from_slice(&raw);
                    break;
                }
                resume_transcript.extend_from_slice(&raw);
                hs.transcript.extend_from_slice(&raw);
            }
            let ccs = conn.send_record(dtls_content::CHANGE_CIPHER_SPEC, 0, &[1])?;
            let verify_data = prf(&conn.master_secret, "client finished", &hs.hash(), 12);
            let fin = conn.send_hs(&mut hs, dtls_handshake::FINISHED, &verify_data, 1)?;
            flight = vec![ccs, fin];
            if config.session_resumption {
                conn.capture_session_ticket(&mut hs);
                if conn.session.is_none() {
                    // No rotated ticket followed (servers must not
                    // send one post-handshake): the presented
                    // session remains valid for the next reconnect.
                    conn.session = Some(session.clone());
                }
            }
            return Ok(conn);
        }

        // Server flight: Certificate, ServerKeyExchange, [CertificateRequest], ServerHelloDone.
        let mut peer_ephemeral: Option<PublicKey> = None;
        let mut ske_signed_bytes: Option<Vec<u8>> = None;
        let mut ske_signature: Option<Vec<u8>> = None;
        let mut cert_requested = false;
        loop {
            let (msg_type, raw, body) = match peeked.take() {
                Some(m) => m,
                None => conn.pump_until_message(&mut hs, &flight)?,
            };
            hs.transcript.extend_from_slice(&raw);
            match msg_type {
                t if t == dtls_handshake::CERTIFICATE => {
                    let der = parse_first_cert(&body)?;
                    conn.peer_certificate = Some(der);
                }
                t if t == dtls_handshake::SERVER_KEY_EXCHANGE => {
                    // params: curve_type(1) namedcurve(2) len(1) point; then sigalg(2) len(2) sig
                    let mut r = Reader::new(&body);
                    let params_start = r.pos;
                    let curve_type = r.u8()?;
                    let group = r.u16()?;
                    if curve_type != 3 || group != GROUP_SECP256R1 {
                        return Err(err("server picked an unsupported ECDHE group"));
                    }
                    let point = r.vec8()?;
                    let params = &body[params_start..r.pos];
                    ske_signed_bytes = Some(params.to_vec());
                    let _sigalg = r.u16()?;
                    ske_signature = Some(r.vec16()?.to_vec());
                    peer_ephemeral = Some(
                        PublicKey::decode(point).ok_or_else(|| err("bad server ECDHE point"))?,
                    );
                }
                t if t == dtls_handshake::CERTIFICATE_REQUEST => {
                    cert_requested = true;
                }
                t if t == dtls_handshake::SERVER_HELLO_DONE => break,
                _ => return Err(err("unexpected message in server flight")),
            }
        }
        let peer_cert_der =
            conn.peer_certificate.clone().ok_or_else(|| err("server sent no certificate"))?;
        let peer_cert_key = crate::x509::parse_public_key(&peer_cert_der)
            .ok_or_else(|| err("cannot parse server certificate key"))?;
        // Verify ServerKeyExchange signature.
        {
            let params = ske_signed_bytes.ok_or_else(|| err("no ServerKeyExchange"))?;
            let sig_der = ske_signature.ok_or_else(|| err("no ServerKeyExchange signature"))?;
            let mut signed = Vec::new();
            signed.extend_from_slice(&conn.client_random);
            signed.extend_from_slice(&conn.server_random);
            signed.extend_from_slice(&params);
            let digest = sha256(&signed);
            let (r, s) = parse_ecdsa_sig_der(&sig_der)?;
            if !peer_cert_key.verify(&digest, &r, &s) {
                return Err(err("ServerKeyExchange signature invalid"));
            }
        }
        conn.check_peer_fingerprint(config)?;

        // Client flight.
        let (eph_private, eph_public) = PrivateKey::generate();
        let peer_eph = peer_ephemeral.ok_or_else(|| err("no server ephemeral"))?;
        let premaster = eph_private
            .ecdh(&peer_eph)
            .ok_or_else(|| err("ECDH failed"))?;
        let mut out_flight: Vec<Vec<u8>> = Vec::new();
        if cert_requested {
            let p = conn.send_hs(
                &mut hs,
                dtls_handshake::CERTIFICATE,
                &cert_list_body(&config.certificate.der),
                0,
            )?;
            out_flight.push(p);
        }
        let cke_body = {
            let point = eph_public.encode_uncompressed();
            let mut v = vec![point.len() as u8];
            v.extend_from_slice(&point);
            v
        };
        let p = conn.send_hs(&mut hs, dtls_handshake::CLIENT_KEY_EXCHANGE, &cke_body, 0)?;
        out_flight.push(p);

        // Master secret (EMS snapshot is the transcript through CKE).
        let session_hash = hs.hash();
        conn.master_secret = if server_hello.ems {
            prf(&premaster, "extended master secret", &session_hash, 48)
        } else {
            let mut seed = conn.client_random.to_vec();
            seed.extend_from_slice(&conn.server_random);
            prf(&premaster, "master secret", &seed, 48)
        };
        conn.derive_keys(&conn.master_secret.clone());

        if cert_requested {
            let (r, s) = config.certificate.private.sign(&session_hash);
            let mut cv_body = vec![0x04, 0x03]; // sha256 + ecdsa
            let der = ecdsa_sig_der(&r, &s);
            cv_body.extend_from_slice(&(der.len() as u16).to_be_bytes());
            cv_body.extend_from_slice(&der);
            let p = conn.send_hs(&mut hs, dtls_handshake::CERTIFICATE_VERIFY, &cv_body, 0)?;
            out_flight.push(p);
        }
        let ccs = conn.send_record(dtls_content::CHANGE_CIPHER_SPEC, 0, &[1])?;
        out_flight.push(ccs);
        let verify_data = prf(&conn.master_secret, "client finished", &hs.hash(), 12);
        let p = conn.send_hs(&mut hs, dtls_handshake::FINISHED, &verify_data, 1)?;
        out_flight.push(p);
        flight = out_flight;

        // Server CCS + Finished.
        loop {
            let (msg_type, raw, body) = conn.pump_until_message(&mut hs, &flight)?;
            if msg_type == dtls_handshake::NEW_SESSION_TICKET {
                conn.store_ticket_body(&body);
            }
            if msg_type == dtls_handshake::FINISHED {
                let expected =
                    prf(&conn.master_secret, "server finished", &hs.hash(), 12);
                if body != expected.as_slice() {
                    return Err(err("server Finished verification failed"));
                }
                hs.transcript.extend_from_slice(&raw);
                break;
            }
            hs.transcript.extend_from_slice(&raw);
        }
        if config.session_resumption {
            conn.capture_session_ticket(&mut hs);
        }
        Ok(conn)
    }

    /// Best-effort capture of a NewSessionTicket sent after the
    /// server's Finished. Never fails the connection.
    fn capture_session_ticket(&mut self, hs: &mut Hs) {
        if self.session.is_some() {
            return;
        }
        let find_ticket = |hs: &Hs| -> Option<Vec<u8>> {
            hs.ready
                .values()
                .find(|(t, _, _)| *t == dtls_handshake::NEW_SESSION_TICKET)
                .map(|(_, _, body)| body.clone())
        };
        let mut body = find_ticket(hs);
        if body.is_none() {
            // One short poll for a ticket sent in its own datagram.
            if let Ok(Some(packet)) = self.io.recv_packet(Duration::from_millis(250)) {
                if let Ok(records) = self.parse_records(&packet) {
                    for record in records {
                        if record.content_type == dtls_content::HANDSHAKE {
                            hs.feed_handshake_bytes(&record.body);
                        }
                    }
                }
                body = find_ticket(hs);
            }
        }
        if let Some(body) = body {
            self.store_ticket_body(&body);
        }
    }

    /// Parse a NewSessionTicket body into resumption state.
    /// Called directly when the handshake pump surfaces the
    /// ticket (the usual case: it precedes the server Finished),
    /// so capture does not depend on packet timing.
    fn store_ticket_body(&mut self, body: &[u8]) {
        let mut r = Reader::new(body);
        let _ = r.take(4); // lifetime
        if let Ok(ticket) = r.vec16() {
            self.session = Some(DtlsSession {
                ticket: ticket.to_vec(),
                master_secret: self.master_secret.clone(),
                peer_certificate: self.peer_certificate.clone().unwrap_or_default(),
                srtp_profile: self.negotiated_srtp_profile,
            });
        }
    }

    /// DTLS server handshake (no HelloVerifyRequest cookie demand).
    pub fn accept(io: I, config: &DtlsConfig) -> io::Result<Self> {
        let mut conn = dtls_new!(io, Role::Server);
        conn.recv_cid = config.connection_id.clone();
        let mut hs = Hs::default();

        // ClientHello.
        let (_t, raw, body) = conn.pump_until_message(&mut hs, &[])?;
        hs.transcript.extend_from_slice(&raw);
        let (client_ems, client_srtp_profiles, client_ticket, client_session_id) = {
            let mut r = Reader::new(&body);
            let _v = [r.u8()?, r.u8()?];
            conn.client_random = r.take(32)?.try_into().unwrap();
            let session_id = r.vec8()?.to_vec();
            let _cookie = r.vec8()?;
            let suites = r.vec16()?;
            if !suites.chunks_exact(2).any(|c| u16::from_be_bytes([c[0], c[1]]) == SUITE) {
                return Err(err("client does not offer the required cipher suite"));
            }
            let _compression = r.vec8()?;
            let mut ems = false;
            let mut profiles = Vec::new();
            let mut ticket: Option<Vec<u8>> = None;
            let mut client_cid: Option<Vec<u8>> = None;
            if !r.done() {
                let exts = r.vec16()?;
                let mut er = Reader::new(exts);
                while !er.done() {
                    let ty = er.u16()?;
                    let data = er.vec16()?;
                    match ty {
                        23 => ems = true,
                        crate::proto_gen::dtls_ext::CONNECTION_ID => {
                            let mut cr = Reader::new(data);
                            client_cid = Some(cr.vec8()?.to_vec());
                        }
                        35 => ticket = Some(data.to_vec()),
                        14 => {
                            let mut sr = Reader::new(data);
                            let list = sr.vec16()?;
                            for c in list.chunks_exact(2) {
                                profiles.push(u16::from_be_bytes([c[0], c[1]]));
                            }
                        }
                        _ => {}
                    }
                }
            }
            conn.send_cid = client_cid;
            (ems, profiles, ticket, session_id)
        };
        let srtp_profile = [0x0007u16, 0x0001, 0x0002, 0x0008]
            .iter()
            .copied()
            .find(|p| client_srtp_profiles.contains(p));
        conn.negotiated_srtp_profile = srtp_profile;
        conn.server_random = random_bytes(32).try_into().unwrap();

        // Abbreviated handshake when the client presents a valid
        // ticket we sealed earlier (RFC 5077).
        if config.session_resumption {
            if let (Some(key), Some(ticket)) =
                (&config.session_ticket_key, &client_ticket)
            {
                if !ticket.is_empty() {
                    if let Some(session) = open_ticket(key, ticket) {
                        if !(config.require_peer_certificate
                            && session.peer_certificate.is_empty())
                        {
                            return conn.finish_resumed_accept(
                                &mut hs,
                                config,
                                session,
                                &client_session_id,
                                client_ems,
                            );
                        }
                    }
                }
            }
        }

        // Server flight.
        let mut flight = Vec::new();
        {
            let mut sh = Vec::new();
            sh.extend_from_slice(&DTLS_1_2);
            sh.extend_from_slice(&conn.server_random);
            sh.push(0);
            sh.extend_from_slice(&SUITE.to_be_bytes());
            sh.push(0);
            let mut exts = Vec::new();
            if let Some(profile) = srtp_profile {
                exts.extend_from_slice(&14u16.to_be_bytes());
                let data = [0u8, 2, (profile >> 8) as u8, profile as u8, 0];
                exts.extend_from_slice(&(data.len() as u16).to_be_bytes());
                exts.extend_from_slice(&data);
            }
            if client_ems {
                exts.extend_from_slice(&23u16.to_be_bytes());
                exts.extend_from_slice(&[0, 0]);
            }
            if let Some(cid) = &config.connection_id {
                exts.extend_from_slice(
                    &crate::proto_gen::dtls_ext::CONNECTION_ID.to_be_bytes(),
                );
                exts.extend_from_slice(&((cid.len() + 1) as u16).to_be_bytes());
                exts.push(cid.len() as u8);
                exts.extend_from_slice(cid);
            }
            if config.session_resumption && client_ticket.is_some() {
                // session_ticket (35), empty: signals a
                // NewSessionTicket follows. Without this echo
                // OpenSSL rejects the ticket as unexpected.
                exts.extend_from_slice(&35u16.to_be_bytes());
                exts.extend_from_slice(&[0, 0]);
            }
            exts.extend_from_slice(&65281u16.to_be_bytes());
            exts.extend_from_slice(&[0, 1, 0]);
            sh.extend_from_slice(&(exts.len() as u16).to_be_bytes());
            sh.extend_from_slice(&exts);
            flight.push(conn.send_hs(&mut hs, dtls_handshake::SERVER_HELLO, &sh, 0)?);
        }
        flight.push(conn.send_hs(
            &mut hs,
            dtls_handshake::CERTIFICATE,
            &cert_list_body(&config.certificate.der),
            0,
        )?);
        let (eph_private, eph_public) = PrivateKey::generate();
        {
            let mut params = vec![3u8];
            params.extend_from_slice(&GROUP_SECP256R1.to_be_bytes());
            let point = eph_public.encode_uncompressed();
            params.push(point.len() as u8);
            params.extend_from_slice(&point);
            let mut signed = Vec::new();
            signed.extend_from_slice(&conn.client_random);
            signed.extend_from_slice(&conn.server_random);
            signed.extend_from_slice(&params);
            let digest = sha256(&signed);
            let (r, s) = config.certificate.private.sign(&digest);
            let der = ecdsa_sig_der(&r, &s);
            let mut ske = params;
            ske.extend_from_slice(&[0x04, 0x03]);
            ske.extend_from_slice(&(der.len() as u16).to_be_bytes());
            ske.extend_from_slice(&der);
            flight.push(conn.send_hs(&mut hs, dtls_handshake::SERVER_KEY_EXCHANGE, &ske, 0)?);
        }
        {
            // CertificateRequest: ecdsa_sign(64), sign/hash pairs, empty DN list.
            let mut cr = vec![1u8, 64u8];
            let pairs: [u8; 12] = [0x04, 0x03, 0x05, 0x03, 0x06, 0x03, 0x04, 0x01, 0x05, 0x01, 0x06, 0x01];
            cr.extend_from_slice(&(pairs.len() as u16).to_be_bytes());
            cr.extend_from_slice(&pairs);
            cr.extend_from_slice(&[0, 0]);
            flight.push(conn.send_hs(&mut hs, dtls_handshake::CERTIFICATE_REQUEST, &cr, 0)?);
        }
        flight.push(conn.send_hs(&mut hs, dtls_handshake::SERVER_HELLO_DONE, &[], 0)?);

        // Client flight.
        let mut saw_client_cert = false;
        let mut cke_transcript_hash: Option<[u8; 32]> = None;
        loop {
            let (msg_type, raw, body) = conn.pump_until_message(&mut hs, &flight)?;
            match msg_type {
                t if t == dtls_handshake::CERTIFICATE => {
                    hs.transcript.extend_from_slice(&raw);
                    if !body.is_empty() && body != [0u8, 0, 0] {
                        match parse_first_cert(&body) {
                            Ok(der) => {
                                conn.peer_certificate = Some(der);
                                saw_client_cert = true;
                            }
                            Err(_) => saw_client_cert = false,
                        }
                    }
                }
                t if t == dtls_handshake::CLIENT_KEY_EXCHANGE => {
                    hs.transcript.extend_from_slice(&raw);
                    let mut r = Reader::new(&body);
                    let point = r.vec8()?;
                    let peer_eph = PublicKey::decode(point)
                        .ok_or_else(|| err("bad client ECDHE point"))?;
                    let premaster = eph_private
                        .ecdh(&peer_eph)
                        .ok_or_else(|| err("ECDH failed"))?;
                    cke_transcript_hash = Some(hs.hash());
                    conn.master_secret = if client_ems {
                        prf(&premaster, "extended master secret", &cke_transcript_hash.unwrap(), 48)
                    } else {
                        let mut seed = conn.client_random.to_vec();
                        seed.extend_from_slice(&conn.server_random);
                        prf(&premaster, "master secret", &seed, 48)
                    };
                    conn.derive_keys(&conn.master_secret.clone());
                }
                t if t == dtls_handshake::CERTIFICATE_VERIFY => {
                    // Verify against the transcript through ClientKeyExchange.
                    let peer_key = conn
                        .peer_certificate
                        .as_deref()
                        .and_then(crate::x509::parse_public_key)
                        .ok_or_else(|| err("CertificateVerify without certificate"))?;
                    let hash = cke_transcript_hash
                        .ok_or_else(|| err("CertificateVerify before ClientKeyExchange"))?;
                    let mut r = Reader::new(&body);
                    let _alg = r.u16()?;
                    let sig = r.vec16()?;
                    let (sr, ss) = parse_ecdsa_sig_der(sig)?;
                    if !peer_key.verify(&hash, &sr, &ss) {
                        return Err(err("CertificateVerify signature invalid"));
                    }
                    hs.transcript.extend_from_slice(&raw);
                }
                t if t == dtls_handshake::FINISHED => {
                    let expected =
                        prf(&conn.master_secret, "client finished", &hs.hash(), 12);
                    if body != expected.as_slice() {
                        return Err(err("client Finished verification failed"));
                    }
                    hs.transcript.extend_from_slice(&raw);
                    break;
                }
                _ => return Err(err("unexpected message in client flight")),
            }
        }
        if config.require_peer_certificate && !saw_client_cert {
            return Err(err("peer presented no certificate"));
        }
        conn.check_peer_fingerprint(config)?;

        // Issue a session ticket when resumption is enabled and
        // the client offered ticket support. Like OpenSSL, the
        // ticket goes out at epoch 0 before CCS: an epoch-1 ticket
        // after Finished arrives post-handshake at OpenSSL
        // clients, which reject it as unexpected_message. The
        // ticket joins the Finished transcript on both sides.
        if config.session_resumption && client_ticket.is_some() {
            conn.issue_session_ticket(&mut hs, config, 0);
        }

        // Server CCS + Finished.
        let ccs = conn.send_record(dtls_content::CHANGE_CIPHER_SPEC, 0, &[1])?;
        let _ = ccs;
        let verify_data = prf(&conn.master_secret, "server finished", &hs.hash(), 12);
        conn.send_hs(&mut hs, dtls_handshake::FINISHED, &verify_data, 1)?;
        Ok(conn)
    }

    /// Abbreviated server handshake for a valid ticket: ServerHello
    /// (signaling resumption), then CCS/Finished both ways. The
    /// peer certificate comes from the sealed ticket, so the
    /// fingerprint check enforces exactly what the full
    /// handshake enforced when the ticket was issued.
    fn finish_resumed_accept(
        mut self,
        hs: &mut Hs,
        config: &DtlsConfig,
        session: DtlsSession,
        client_session_id: &[u8],
        client_ems: bool,
    ) -> io::Result<Self> {
        self.master_secret = session.master_secret.clone();
        self.peer_certificate = Some(session.peer_certificate.clone());
        self.negotiated_srtp_profile = session.srtp_profile;
        self.resumed = true;

        let mut sh = Vec::new();
        sh.extend_from_slice(&DTLS_1_2);
        sh.extend_from_slice(&self.server_random);
        // Echo the client's session id: OpenSSL only recognizes
        // ticket resumption when the id it offered comes back.
        sh.push(client_session_id.len() as u8);
        sh.extend_from_slice(client_session_id);
        sh.extend_from_slice(&SUITE.to_be_bytes());
        sh.push(0); // compression: null
        let mut exts = Vec::new();
        if let Some(profile) = session.srtp_profile {
            exts.extend_from_slice(&14u16.to_be_bytes());
            let data = [0u8, 2, (profile >> 8) as u8, profile as u8, 0];
            exts.extend_from_slice(&(data.len() as u16).to_be_bytes());
            exts.extend_from_slice(&data);
        }
        // No session_ticket extension in the resumed hello:
        // OpenSSL signals ticket acceptance by the echoed
        // session id alone (its own servers omit 35 here).
        if client_ems {
            exts.extend_from_slice(&23u16.to_be_bytes());
            exts.extend_from_slice(&[0, 0]);
        }
        exts.extend_from_slice(&65281u16.to_be_bytes());
        exts.extend_from_slice(&[0, 1, 0]);
        sh.extend_from_slice(&(exts.len() as u16).to_be_bytes());
        sh.extend_from_slice(&exts);
        let packet = self.send_hs(hs, dtls_handshake::SERVER_HELLO, &sh, 0)?;

        self.derive_keys(&self.master_secret.clone());

        // Abbreviated flight order: our CCS + Finished go out
        // before the client's Finished is read. Our verify_data
        // covers the transcript through ServerHello; the client's
        // answer is checked against the transcript including
        // our Finished (send_hs has already appended it).
        let ccs_packet = self.send_record(dtls_content::CHANGE_CIPHER_SPEC, 0, &[1])?;
        let verify_data = prf(&self.master_secret, "server finished", &hs.hash(), 12);
        let fin_packet = self.send_hs(hs, dtls_handshake::FINISHED, &verify_data, 1)?;
        // Retransmit the whole flight (ServerHello included, in
        // case the client never saw it) while awaiting the answer.
        let flight = vec![packet, ccs_packet, fin_packet];

        // Client CCS + Finished.
        loop {
            let (msg_type, raw, body) = self.pump_until_message(hs, &flight)?;
            if msg_type == dtls_handshake::FINISHED {
                let expected = prf(&self.master_secret, "client finished", &hs.hash(), 12);
                if body != expected.as_slice() {
                    return Err(err("client Finished verification failed"));
                }
                hs.transcript.extend_from_slice(&raw);
                break;
            }
            hs.transcript.extend_from_slice(&raw);
        }
        self.check_peer_fingerprint(config)?;
        // No ticket rotation here: a post-handshake
        // NewSessionTicket (epoch 1, after Finished) is rejected
        // by OpenSSL TLS 1.2 clients and poisons the data path.
        // The presented ticket stays valid for the next reconnect.
        Ok(self)
    }

    /// Seal and send a NewSessionTicket for the current session.
    /// Best effort: a failed send must not fail the established
    /// connection.
    fn issue_session_ticket(&mut self, hs: &mut Hs, config: &DtlsConfig, epoch: u16) {
        if let Some(key) = &config.session_ticket_key {
            let ticket = seal_ticket(
                key,
                &self.master_secret,
                self.negotiated_srtp_profile,
                self.peer_certificate.as_deref().unwrap_or(&[]),
            );
            let mut body = Vec::new();
            body.extend_from_slice(&(TICKET_LIFETIME_SECS as u32).to_be_bytes());
            body.extend_from_slice(&(ticket.len() as u16).to_be_bytes());
            body.extend_from_slice(&ticket);
            let _ = self.send_hs(hs, dtls_handshake::NEW_SESSION_TICKET, &body, epoch);
        }
    }
}
