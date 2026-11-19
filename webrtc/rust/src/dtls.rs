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
    /// Send several packets, ideally in one syscall batch
    /// (sendmmsg where the transport supports it). The
    /// default sends them one by one.
    fn send_packets(&mut self, packets: &[Vec<u8>]) -> io::Result<()> {
        for p in packets {
            self.send_packet(p)?;
        }
        Ok(())
    }
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
    #[cfg(target_os = "linux")]
    fn send_packets(&mut self, packets: &[Vec<u8>]) -> io::Result<()> {
        crate::mux::batch::sendmmsg_batch(&self.socket, packets, self.peer)
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

/// Sans-io DTLS connection (established phase): record
/// crypto, replay window, and session state with no I/O of
/// its own. Pump it from any driver: feed datagrams to
/// handle_datagram, send what encrypt_app returns. The
/// handshake that produces a core is driven by Dtls below
/// (the flight state machine stays driven; see the
/// SPEC-WEBRTC shared-core assessment).
pub struct DtlsCore {
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

pub struct Dtls<I: DtlsIo> {
    io: I,
    core: DtlsCore,
}

impl DtlsCore {
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

    fn build_record(&mut self, content_type: u8, epoch: u16, body: &[u8]) -> io::Result<Vec<u8>> {
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
        // Datagram transport: unauthenticated or replayed records
        // are silently discarded (RFC 9147), never fatal — one
        // bad or stale record must not kill the receive pump.
        // A discarded record surfaces as content_type 0, which
        // every consumer ignores.
        let dropped = Record { content_type: 0, body: Vec::new() };
        let plaintext = match aes128_gcm_decrypt(&keys.key, &nonce, ciphertext, &aad, &tag) {
            Some(p) => p,
            None => return Ok((dropped, consumed)),
        };
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
                        return Ok((dropped, consumed));
                    }
                    self.read_replay_window |= 1 << diff;
                }
            }
        }
        Ok((Record { content_type, body: plaintext }, consumed))
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

    /// Decrypt one inbound datagram: Some(payload) for an
    /// application-data record, None for anything else
    /// (alerts are an error, mirroring the driven receive).
    pub fn handle_datagram(&mut self, packet: &[u8]) -> io::Result<Option<Vec<u8>>> {
        let records = self.parse_records(packet)?;
        for record in records {
            match record.content_type {
                t if t == dtls_content::APPLICATION_DATA => return Ok(Some(record.body)),
                t if t == dtls_content::ALERT => return Err(err("alert from peer")),
                _ => continue,
            }
        }
        Ok(None)
    }

    /// Encrypt one application payload into a datagram.
    pub fn encrypt_app(&mut self, data: &[u8]) -> io::Result<Vec<u8>> {
        self.build_record(dtls_content::APPLICATION_DATA, 1, data)
    }

    /// Resumption state captured from a NewSessionTicket.
    pub fn take_session(&mut self) -> Option<DtlsSession> {
        self.session.take()
    }

    /// Whether this connection resumed a prior session.
    pub fn was_resumed(&self) -> bool {
        self.resumed
    }

    /// Whether epoch-1 keys are installed (handshake done).
    pub fn established(&self) -> bool {
        self.write_keys.is_some() && self.read_keys.is_some()
    }

    /// Timer driver for the established phase: no flights
    /// are outstanding once keys exist (retransmission only
    /// exists during the driven handshake), so this is
    /// always empty; it completes the pump contract
    /// (handle_datagram / encrypt_app / tick) drivers use.
    pub fn tick(&mut self, _now_ms: u64) -> Vec<Vec<u8>> {
        Vec::new()
    }

    /// Build one handshake record (transcript + seq updated),
    /// without sending: the record-layer half of send_hs for
    /// sans-io pumps.
    fn build_hs(&mut self, hs: &mut Hs, msg_type: u8, body: &[u8], epoch: u16) -> io::Result<Vec<u8>> {
        let raw = handshake_message(msg_type, hs.send_seq, body);
        hs.send_seq += 1;
        let packet = self.build_record(dtls_content::HANDSHAKE, epoch, &raw)?;
        hs.transcript.extend_from_slice(&raw);
        Ok(packet)
    }

    /// Parse a NewSessionTicket body into resumption state.
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

    /// Build a NewSessionTicket record for the current
    /// session (None without a ticket key). Best effort by
    /// design: callers ignore failure.
    fn build_session_ticket(&mut self, hs: &mut Hs, key: &[u8; 32], epoch: u16) -> Option<Vec<u8>> {
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
        self.build_hs(hs, dtls_handshake::NEW_SESSION_TICKET, &body, epoch).ok()
    }
}

fn err(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}

// ---------------------------------------------------------------------------
// sans-io handshake (DtlsHandshake)
// ---------------------------------------------------------------------------

/// Epoch-1 handshake record test (resumption classification),
/// lifted verbatim from the driven client.
fn epoch1_handshake(packet: &[u8]) -> bool {
    let mut off = 0;
    while off + 13 <= packet.len() {
        let len = u16::from_be_bytes([packet[off + 11], packet[off + 12]]) as usize;
        if packet[off] == dtls_content::HANDSHAKE && packet[off + 3] == 0 && packet[off + 4] == 1 {
            return true;
        }
        off += 13 + len;
    }
    false
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum HsStage {
    ClientAwaitServerHello,
    ClientClassifyResumption,
    ClientAwaitResumeFinished,
    ClientAwaitServerFlight,
    ClientAwaitServerFinished,
    CaptureTicket,
    ServerAwaitClientHello,
    ServerAwaitClientFlight,
    ServerAwaitResumeClientFinished,
    Established,
    Failed,
}

/// Resumable DTLS handshake: the flight machine of
/// connect/accept as a pump-driven state machine. Hosts
/// feed datagrams (`handle_datagram`), call `tick` at
/// `next_timeout`, and send what comes out; on
/// `established()` the finished `DtlsCore` is theirs via
/// `into_core`. Wire behavior mirrors the driven handshake
/// flight-for-flight (same transcripts, same retransmit
/// budget: 6 x 1 s of silence per wait).
pub struct DtlsHandshake {
    core: DtlsCore,
    hs: Hs,
    stage: HsStage,
    flight: Vec<Vec<u8>>,
    retries_left: u32,
    deadline_ms: Option<u64>,
    now_ms: u64,
    failure: Option<String>,
    certificate: Certificate,
    expected_fingerprint: Option<String>,
    require_peer_cert: bool,
    session_resumption: bool,
    ticket_key: Option<[u8; 32]>,
    connection_id: Option<Vec<u8>>,
    pair_hint: Option<Vec<u8>>,
    resume: Option<DtlsSession>,
    cookie: Vec<u8>,
    offered_session_id: Vec<u8>,
    resume_transcript: Vec<u8>,
    peer_ephemeral: Option<PublicKey>,
    ske_signed: Option<Vec<u8>>,
    ske_sig: Option<Vec<u8>>,
    cert_requested: bool,
    server_ems: bool,
    server_eph_private: Option<PrivateKey>,
    client_ems: bool,
    client_ticket: Option<Vec<u8>>,
    saw_client_cert: bool,
    cke_hash: Option<[u8; 32]>,
    stage_deadline_ms: u64,
}

fn fresh_core(role: Role) -> DtlsCore {
    DtlsCore {
        role,
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
}

impl DtlsHandshake {
    fn blank(
        core: DtlsCore,
        config: &DtlsConfig,
        resume: Option<DtlsSession>,
        stage: HsStage,
        now_ms: u64,
    ) -> Self {
        Self {
            core,
            hs: Hs::default(),
            stage,
            flight: Vec::new(),
            retries_left: 6,
            deadline_ms: Some(now_ms + 1000),
            now_ms,
            failure: None,
            certificate: config.certificate.clone(),
            expected_fingerprint: config.expected_peer_fingerprint.clone(),
            require_peer_cert: config.require_peer_certificate,
            session_resumption: config.session_resumption,
            ticket_key: config.session_ticket_key,
            connection_id: config.connection_id.clone(),
            pair_hint: config.pair_hint.clone(),
            resume,
            cookie: Vec::new(),
            offered_session_id: Vec::new(),
            resume_transcript: Vec::new(),
            peer_ephemeral: None,
            ske_signed: None,
            ske_sig: None,
            cert_requested: false,
            server_ems: false,
            server_eph_private: None,
            client_ems: false,
            client_ticket: None,
            saw_client_cert: false,
            cke_hash: None,
            stage_deadline_ms: 0,
        }
    }

    /// Client handshake; returns the machine and the first
    /// flight (ClientHello) to send.
    pub fn new_client(
        config: &DtlsConfig,
        resume: Option<&DtlsSession>,
        now_ms: u64,
    ) -> io::Result<(Self, Vec<Vec<u8>>)> {
        let mut core = fresh_core(Role::Client);
        core.recv_cid = config.connection_id.clone();
        core.client_random = random_bytes(32).try_into().unwrap();
        let mut this = Self::blank(core, config, resume.cloned(), HsStage::ClientAwaitServerHello, now_ms);
        this.offered_session_id = match resume {
            Some(_) => random_bytes(32),
            None => Vec::new(),
        };
        let flight = this.client_hello_flight()?;
        this.set_flight(flight.clone(), now_ms);
        Ok((this, flight))
    }

    /// Server handshake (no initial flight).
    pub fn new_server(config: &DtlsConfig, now_ms: u64) -> Self {
        let mut core = fresh_core(Role::Server);
        core.recv_cid = config.connection_id.clone();
        Self::blank(core, config, None, HsStage::ServerAwaitClientHello, now_ms)
    }

    fn client_hello_flight(&mut self) -> io::Result<Vec<Vec<u8>>> {
        let ticket_offer: Option<&[u8]> = match &self.resume {
            Some(session) => Some(&session.ticket),
            None if self.session_resumption => Some(&[]),
            None => None,
        };
        let body = client_hello_body(
            &self.core.client_random,
            &self.cookie,
            true,
            ticket_offer,
            &self.offered_session_id,
            self.connection_id.as_deref(),
            self.pair_hint.as_deref(),
        );
        let packet = self.core.build_hs(&mut self.hs, dtls_handshake::CLIENT_HELLO, &body, 0)?;
        Ok(vec![packet])
    }

    fn set_flight(&mut self, flight: Vec<Vec<u8>>, now_ms: u64) {
        self.flight = flight;
        self.retries_left = 6;
        self.deadline_ms = Some(now_ms + 1000);
    }

    fn fail(&mut self, msg: impl Into<String>) {
        self.stage = HsStage::Failed;
        self.failure = Some(msg.into());
    }

    fn check_fingerprint(&self) -> io::Result<()> {
        if let Some(expected) = &self.expected_fingerprint {
            let actual = self
                .core
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

    /// Feed one inbound datagram; returns datagrams to send.
    pub fn handle_datagram(&mut self, packet: &[u8], now_ms: u64) -> Vec<Vec<u8>> {
        self.now_ms = now_ms;
        if matches!(self.stage, HsStage::Established | HsStage::Failed) {
            return Vec::new();
        }
        if let Err(e) = self.feed(packet) {
            self.fail(e.to_string());
            return Vec::new();
        }
        // Resumption classification looks at the raw packet,
        // exactly like the driven peek.
        if self.stage == HsStage::ClientClassifyResumption && epoch1_handshake(packet) {
            self.begin_resumed();
        }
        let mut out = Vec::new();
        self.step(&mut out);
        out
    }

    fn feed(&mut self, packet: &[u8]) -> io::Result<()> {
        let (records, parse_err) = self.core.parse_records_partial(packet);
        for record in records {
            match record.content_type {
                t if t == dtls_content::HANDSHAKE => {
                    self.hs.feed_handshake_bytes(&record.body)
                }
                t if t == dtls_content::CHANGE_CIPHER_SPEC => self.hs.ccs_received = true,
                t if t == dtls_content::ALERT => {
                    return Err(err("fatal alert from peer during handshake"))
                }
                _ => {}
            }
        }
        match parse_err {
            None => Ok(()),
            Some(_) if self.core.read_keys.is_none() => {
                self.hs.pending.push(packet.to_vec());
                Ok(())
            }
            Some(e) => Err(e),
        }
    }

    /// Next handshake message, draining deferred datagrams
    /// first (the pump's pending loop).
    fn next_msg(&mut self) -> Option<(u8, Vec<u8>, Vec<u8>)> {
        loop {
            if let Some(m) = self.hs.next() {
                return Some(m);
            }
            let mut progressed = false;
            let mut i = 0;
            while i < self.hs.pending.len() {
                let (records, parse_err) =
                    self.core.parse_records_partial(&self.hs.pending[i].clone());
                if parse_err.is_none() {
                    self.hs.pending.remove(i);
                    progressed = true;
                } else {
                    i += 1;
                }
                for record in records {
                    match record.content_type {
                        t if t == dtls_content::HANDSHAKE => {
                            self.hs.feed_handshake_bytes(&record.body)
                        }
                        t if t == dtls_content::CHANGE_CIPHER_SPEC => {
                            self.hs.ccs_received = true
                        }
                        _ => {}
                    }
                }
            }
            if !progressed {
                return None;
            }
        }
    }

    /// Timer entry: retransmit the current flight when the
    /// silence deadline passes (6 retries, then failure),
    /// and advance the timed stages (classification and
    /// ticket-capture windows).
    pub fn tick(&mut self, now_ms: u64) -> Vec<Vec<u8>> {
        self.now_ms = now_ms;
        let mut out = Vec::new();
        match self.stage {
            HsStage::Established | HsStage::Failed => return out,
            HsStage::ClientClassifyResumption => {
                if now_ms >= self.stage_deadline_ms {
                    self.stage = HsStage::ClientAwaitServerFlight;
                    self.step(&mut out);
                }
                return out;
            }
            HsStage::CaptureTicket => {
                if now_ms >= self.stage_deadline_ms {
                    if self.core.session.is_none() {
                        if let Some(session) = &self.resume {
                            self.core.session = Some(session.clone());
                        }
                    }
                    self.stage = HsStage::Established;
                }
                return out;
            }
            _ => {}
        }
        if let Some(deadline) = self.deadline_ms {
            if now_ms >= deadline {
                if self.retries_left == 0 {
                    self.fail("handshake timed out");
                    return out;
                }
                self.retries_left -= 1;
                self.deadline_ms = Some(now_ms + 1000);
                out.extend(self.flight.iter().cloned());
            }
        }
        out
    }

    /// Milliseconds until the next tick is due (0 = now).
    pub fn next_timeout(&self, now_ms: u64) -> Option<u64> {
        match self.stage {
            HsStage::Established | HsStage::Failed => None,
            HsStage::ClientClassifyResumption | HsStage::CaptureTicket => {
                Some(self.stage_deadline_ms.saturating_sub(now_ms))
            }
            _ => self
                .deadline_ms
                .map(|d| d.saturating_sub(now_ms)),
        }
    }

    pub fn established(&self) -> bool {
        self.stage == HsStage::Established
    }

    pub fn failure(&self) -> Option<&str> {
        self.failure.as_deref()
    }

    /// Encrypt app data (established phase only).
    pub fn encrypt_app(&mut self, data: &[u8]) -> Option<Vec<u8>> {
        if self.established() {
            self.core.encrypt_app(data).ok()
        } else {
            None
        }
    }

    /// Decrypt one app datagram (established phase only):
    /// Some(Ok(Some(payload))) for app data, Some(Ok(None))
    /// for other records, Some(Err) on alert/crypto failure,
    /// None before establishment.
    pub fn handle_app_datagram(&mut self, packet: &[u8]) -> Option<io::Result<Option<Vec<u8>>>> {
        if self.established() {
            Some(self.core.handle_datagram(packet))
        } else {
            None
        }
    }

    /// Captured resumption state (established phase).
    pub fn take_session(&mut self) -> Option<DtlsSession> {
        if self.established() {
            self.core.take_session()
        } else {
            None
        }
    }

    /// Peer certificate fingerprint, once known.
    pub fn peer_fingerprint(&self) -> Option<String> {
        self.core.peer_fingerprint()
    }

    /// Whether this handshake resumed a prior session.
    pub fn was_resumed(&self) -> bool {
        self.core.was_resumed()
    }

    /// The finished connection, once established.
    pub fn into_core(self) -> Option<DtlsCore> {
        if self.stage == HsStage::Established {
            Some(self.core)
        } else {
            None
        }
    }

    fn begin_resumed(&mut self) {
        let session = self.resume.clone().expect("resumed without session");
        self.core.master_secret = session.master_secret.clone();
        self.core.peer_certificate = Some(session.peer_certificate.clone());
        self.core.negotiated_srtp_profile = session.srtp_profile;
        self.core.resumed = true;
        if let Err(e) = self.check_fingerprint() {
            self.fail(e.to_string());
            return;
        }
        self.core.derive_keys(&self.core.master_secret.clone());
        self.resume_transcript = self.hs.transcript.clone();
        self.stage = HsStage::ClientAwaitResumeFinished;
    }

    fn step(&mut self, out: &mut Vec<Vec<u8>>) {
        loop {
            match self.stage {
                HsStage::Established | HsStage::Failed => return,
                HsStage::ClientClassifyResumption | HsStage::CaptureTicket => {
                    if self.stage == HsStage::CaptureTicket {
                        self.capture_step();
                    }
                    return;
                }
                _ => {}
            }
            let Some((msg_type, raw, body)) = self.next_msg() else {
                return;
            };
            let result = match self.stage {
                HsStage::ClientAwaitServerHello => self.on_server_hello(msg_type, raw, body, out),
                HsStage::ClientAwaitResumeFinished => {
                    self.on_resume_finished(msg_type, raw, body, out)
                }
                HsStage::ClientAwaitServerFlight => self.on_server_flight(msg_type, raw, body, out),
                HsStage::ClientAwaitServerFinished => {
                    self.on_server_finished(msg_type, raw, body, out)
                }
                HsStage::ServerAwaitClientHello => self.on_client_hello(msg_type, raw, body, out),
                HsStage::ServerAwaitClientFlight => {
                    self.on_client_flight(msg_type, raw, body, out)
                }
                HsStage::ServerAwaitResumeClientFinished => {
                    self.on_resume_client_finished(msg_type, raw, body, out)
                }
                _ => unreachable!(),
            };
            if let Err(e) = result {
                self.fail(e.to_string());
                return;
            }
        }
    }

    fn capture_step(&mut self) {
        if self.core.session.is_some() {
            self.stage = HsStage::Established;
            return;
        }
        // Ticket already queued in ready messages?
        let queued = self
            .hs
            .ready
            .values()
            .find(|(t, _, _)| *t == dtls_handshake::NEW_SESSION_TICKET)
            .map(|(_, _, body)| body.clone());
        if let Some(body) = queued {
            self.core.store_ticket_body(&body);
            self.stage = HsStage::Established;
            return;
        }
        if let Some((msg_type, _raw, body)) = self.next_msg() {
            if msg_type == dtls_handshake::NEW_SESSION_TICKET {
                self.core.store_ticket_body(&body);
                self.stage = HsStage::Established;
            }
        }
    }

    fn on_server_hello(
        &mut self,
        msg_type: u8,
        raw: Vec<u8>,
        body: Vec<u8>,
        _out: &mut Vec<Vec<u8>>,
    ) -> io::Result<()> {
        match msg_type {
            t if t == dtls_handshake::HELLO_VERIFY_REQUEST => {
                let mut r = Reader::new(&body);
                let _v = [r.u8()?, r.u8()?];
                self.cookie = r.vec8()?.to_vec();
                self.hs.transcript.clear();
                self.hs.send_seq = 0;
                self.hs.expect_seq = 0;
                let flight = self.client_hello_flight()?;
                self.set_flight(flight.clone(), self.now_ms);
                _out.extend(flight);
                Ok(())
            }
            t if t == dtls_handshake::SERVER_HELLO => {
                let mut hello = parse_server_hello(&body)?;
                hello.resumed = self.resume.is_some()
                    && !self.offered_session_id.is_empty()
                    && hello.session_id == self.offered_session_id;
                self.hs.transcript.extend_from_slice(&raw);
                self.server_ems = hello.ems;
                self.core.server_random = hello.server_random;
                self.core.negotiated_srtp_profile = hello.srtp_profile;
                self.core.send_cid = hello.peer_cid.clone();
                match (self.resume.is_some(), hello.resumed) {
                    (true, true) => self.begin_resumed(),
                    (true, false) => {
                        // Classification by ready/pending state,
                        // else a 1500 ms window (driven peek).
                        let abbreviated = self.hs.ready.is_empty()
                            && self.hs.pending.iter().any(|p| epoch1_handshake(p));
                        if abbreviated {
                            self.begin_resumed();
                        } else if self.hs.ready.is_empty() {
                            self.stage_deadline_ms = self.now_ms + 1500;
                            self.stage = HsStage::ClientClassifyResumption;
                        } else {
                            self.stage = HsStage::ClientAwaitServerFlight;
                        }
                    }
                    _ => self.stage = HsStage::ClientAwaitServerFlight,
                }
                Ok(())
            }
            _ => Err(err("unexpected message before ServerHello")),
        }
    }

    fn on_resume_finished(
        &mut self,
        msg_type: u8,
        raw: Vec<u8>,
        body: Vec<u8>,
        out: &mut Vec<Vec<u8>>,
    ) -> io::Result<()> {
        if msg_type == dtls_handshake::NEW_SESSION_TICKET {
            self.core.store_ticket_body(&body);
            self.resume_transcript.extend_from_slice(&raw);
            self.hs.transcript.extend_from_slice(&raw);
            return Ok(());
        }
        if msg_type == dtls_handshake::FINISHED {
            let expected = prf(
                &self.core.master_secret,
                "server finished",
                &sha256(&self.resume_transcript),
                12,
            );
            if body != expected.as_slice() {
                return Err(err("server Finished verification failed"));
            }
            self.hs.transcript.extend_from_slice(&raw);
            let ccs = self.core.build_record(dtls_content::CHANGE_CIPHER_SPEC, 0, &[1])?;
            let verify_data =
                prf(&self.core.master_secret, "client finished", &self.hs.hash(), 12);
            let fin = self.core.build_hs(&mut self.hs, dtls_handshake::FINISHED, &verify_data, 1)?;
            let flight = vec![ccs, fin];
            self.set_flight(flight.clone(), self.now_ms);
            out.extend(flight);
            if self.session_resumption {
                if self.core.session.is_some() {
                    self.stage = HsStage::Established;
                } else {
                    self.stage_deadline_ms = self.now_ms + 250;
                    self.stage = HsStage::CaptureTicket;
                }
            } else {
                self.stage = HsStage::Established;
            }
            return Ok(());
        }
        self.resume_transcript.extend_from_slice(&raw);
        self.hs.transcript.extend_from_slice(&raw);
        Ok(())
    }

    fn on_server_flight(
        &mut self,
        msg_type: u8,
        raw: Vec<u8>,
        body: Vec<u8>,
        out: &mut Vec<Vec<u8>>,
    ) -> io::Result<()> {
        self.hs.transcript.extend_from_slice(&raw);
        match msg_type {
            t if t == dtls_handshake::CERTIFICATE => {
                self.core.peer_certificate = Some(parse_first_cert(&body)?);
                Ok(())
            }
            t if t == dtls_handshake::SERVER_KEY_EXCHANGE => {
                let mut r = Reader::new(&body);
                let params_start = r.pos;
                let curve_type = r.u8()?;
                let group = r.u16()?;
                if curve_type != 3 || group != GROUP_SECP256R1 {
                    return Err(err("server picked an unsupported ECDHE group"));
                }
                let point = r.vec8()?;
                let params = &body[params_start..r.pos];
                self.ske_signed = Some(params.to_vec());
                let _sigalg = r.u16()?;
                self.ske_sig = Some(r.vec16()?.to_vec());
                self.peer_ephemeral = Some(
                    PublicKey::decode(point).ok_or_else(|| err("bad server ECDHE point"))?,
                );
                Ok(())
            }
            t if t == dtls_handshake::CERTIFICATE_REQUEST => {
                self.cert_requested = true;
                Ok(())
            }
            t if t == dtls_handshake::SERVER_HELLO_DONE => {
                self.finish_server_flight(out)
            }
            _ => Err(err("unexpected message in server flight")),
        }
    }

    fn finish_server_flight(&mut self, out: &mut Vec<Vec<u8>>) -> io::Result<()> {
        let peer_cert_der = self
            .core
            .peer_certificate
            .clone()
            .ok_or_else(|| err("server sent no certificate"))?;
        let peer_cert_key = crate::x509::parse_public_key(&peer_cert_der)
            .ok_or_else(|| err("cannot parse server certificate key"))?;
        {
            let params = self.ske_signed.clone().ok_or_else(|| err("no ServerKeyExchange"))?;
            let sig_der = self.ske_sig.clone().ok_or_else(|| err("no ServerKeyExchange signature"))?;
            let mut signed = Vec::new();
            signed.extend_from_slice(&self.core.client_random);
            signed.extend_from_slice(&self.core.server_random);
            signed.extend_from_slice(&params);
            let digest = sha256(&signed);
            let (r, s) = parse_ecdsa_sig_der(&sig_der)?;
            if !peer_cert_key.verify(&digest, &r, &s) {
                return Err(err("ServerKeyExchange signature invalid"));
            }
        }
        self.check_fingerprint()?;

        let (eph_private, eph_public) = PrivateKey::generate();
        let peer_eph = self.peer_ephemeral.clone().ok_or_else(|| err("no server ephemeral"))?;
        let premaster = eph_private.ecdh(&peer_eph).ok_or_else(|| err("ECDH failed"))?;
        let mut flight: Vec<Vec<u8>> = Vec::new();
        if self.cert_requested {
            flight.push(self.core.build_hs(
                &mut self.hs,
                dtls_handshake::CERTIFICATE,
                &cert_list_body(&self.certificate.der),
                0,
            )?);
        }
        let cke_body = {
            let point = eph_public.encode_uncompressed();
            let mut v = vec![point.len() as u8];
            v.extend_from_slice(&point);
            v
        };
        flight.push(self.core.build_hs(&mut self.hs, dtls_handshake::CLIENT_KEY_EXCHANGE, &cke_body, 0)?);
        let session_hash = self.hs.hash();
        // ems was recorded on the core? ServerHelloInfo.ems is
        // consulted via master-secret derivation below.
        self.core.master_secret = if self.server_ems {
            prf(&premaster, "extended master secret", &session_hash, 48)
        } else {
            let mut seed = self.core.client_random.to_vec();
            seed.extend_from_slice(&self.core.server_random);
            prf(&premaster, "master secret", &seed, 48)
        };
        self.core.derive_keys(&self.core.master_secret.clone());
        if self.cert_requested {
            let (r, s) = self.certificate.private.sign(&session_hash);
            let mut cv_body = vec![0x04, 0x03];
            let der = ecdsa_sig_der(&r, &s);
            cv_body.extend_from_slice(&(der.len() as u16).to_be_bytes());
            cv_body.extend_from_slice(&der);
            flight.push(self.core.build_hs(&mut self.hs, dtls_handshake::CERTIFICATE_VERIFY, &cv_body, 0)?);
        }
        flight.push(self.core.build_record(dtls_content::CHANGE_CIPHER_SPEC, 0, &[1])?);
        let verify_data = prf(&self.core.master_secret, "client finished", &self.hs.hash(), 12);
        flight.push(self.core.build_hs(&mut self.hs, dtls_handshake::FINISHED, &verify_data, 1)?);
        self.set_flight(flight.clone(), self.now_ms);
        out.extend(flight);
        self.stage = HsStage::ClientAwaitServerFinished;
        Ok(())
    }

    fn on_server_finished(
        &mut self,
        msg_type: u8,
        raw: Vec<u8>,
        body: Vec<u8>,
        _out: &mut Vec<Vec<u8>>,
    ) -> io::Result<()> {
        if msg_type == dtls_handshake::NEW_SESSION_TICKET {
            self.core.store_ticket_body(&body);
        }
        if msg_type == dtls_handshake::FINISHED {
            let expected = prf(&self.core.master_secret, "server finished", &self.hs.hash(), 12);
            if body != expected.as_slice() {
                return Err(err("server Finished verification failed"));
            }
            self.hs.transcript.extend_from_slice(&raw);
            if self.session_resumption {
                if self.core.session.is_some() {
                    self.stage = HsStage::Established;
                } else {
                    self.stage_deadline_ms = self.now_ms + 250;
                    self.stage = HsStage::CaptureTicket;
                }
            } else {
                self.stage = HsStage::Established;
            }
            return Ok(());
        }
        self.hs.transcript.extend_from_slice(&raw);
        Ok(())
    }

    fn on_client_hello(
        &mut self,
        msg_type: u8,
        raw: Vec<u8>,
        body: Vec<u8>,
        out: &mut Vec<Vec<u8>>,
    ) -> io::Result<()> {
        if msg_type != dtls_handshake::CLIENT_HELLO {
            return Err(err("expected ClientHello"));
        }
        self.hs.transcript.extend_from_slice(&raw);
        let (client_ems, client_srtp_profiles, client_ticket, client_session_id) = {
            let mut r = Reader::new(&body);
            let _v = [r.u8()?, r.u8()?];
            self.core.client_random = r.take(32)?.try_into().unwrap();
            let session_id = r.vec8()?.to_vec();
            let _cookie = r.vec8()?;
            let suites = r.vec16()?;
            if !suites
                .chunks_exact(2)
                .any(|c| u16::from_be_bytes([c[0], c[1]]) == SUITE)
            {
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
            self.core.send_cid = client_cid;
            (ems, profiles, ticket, session_id)
        };
        self.client_ems = client_ems;
        self.client_ticket = client_ticket.clone();
        let srtp_profile = [0x0007u16, 0x0001, 0x0002, 0x0008]
            .iter()
            .copied()
            .find(|p| client_srtp_profiles.contains(p));
        self.core.negotiated_srtp_profile = srtp_profile;
        self.core.server_random = random_bytes(32).try_into().unwrap();

        if self.session_resumption {
            if let (Some(key), Some(ticket)) = (&self.ticket_key, &client_ticket) {
                if !ticket.is_empty() {
                    if let Some(session) = open_ticket(key, ticket) {
                        if !(self.require_peer_cert && session.peer_certificate.is_empty()) {
                            return self.begin_resumed_accept(session, &client_session_id, out);
                        }
                    }
                }
            }
        }

        let mut flight = Vec::new();
        {
            let mut sh = Vec::new();
            sh.extend_from_slice(&DTLS_1_2);
            sh.extend_from_slice(&self.core.server_random);
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
            if let Some(cid) = &self.connection_id {
                exts.extend_from_slice(&crate::proto_gen::dtls_ext::CONNECTION_ID.to_be_bytes());
                exts.extend_from_slice(&((cid.len() + 1) as u16).to_be_bytes());
                exts.push(cid.len() as u8);
                exts.extend_from_slice(cid);
            }
            if self.session_resumption && client_ticket.is_some() {
                exts.extend_from_slice(&35u16.to_be_bytes());
                exts.extend_from_slice(&[0, 0]);
            }
            exts.extend_from_slice(&65281u16.to_be_bytes());
            exts.extend_from_slice(&[0, 1, 0]);
            sh.extend_from_slice(&(exts.len() as u16).to_be_bytes());
            sh.extend_from_slice(&exts);
            flight.push(self.core.build_hs(&mut self.hs, dtls_handshake::SERVER_HELLO, &sh, 0)?);
        }
        flight.push(self.core.build_hs(
            &mut self.hs,
            dtls_handshake::CERTIFICATE,
            &cert_list_body(&self.certificate.der),
            0,
        )?);
        let (eph_private, eph_public) = PrivateKey::generate();
        self.server_eph_private = Some(eph_private);
        {
            let mut params = vec![3u8];
            params.extend_from_slice(&GROUP_SECP256R1.to_be_bytes());
            let point = eph_public.encode_uncompressed();
            params.push(point.len() as u8);
            params.extend_from_slice(&point);
            let mut signed = Vec::new();
            signed.extend_from_slice(&self.core.client_random);
            signed.extend_from_slice(&self.core.server_random);
            signed.extend_from_slice(&params);
            let digest = sha256(&signed);
            let (r, s) = self.certificate.private.sign(&digest);
            let der = ecdsa_sig_der(&r, &s);
            let mut ske = params;
            ske.extend_from_slice(&[0x04, 0x03]);
            ske.extend_from_slice(&(der.len() as u16).to_be_bytes());
            ske.extend_from_slice(&der);
            flight.push(self.core.build_hs(&mut self.hs, dtls_handshake::SERVER_KEY_EXCHANGE, &ske, 0)?);
        }
        {
            let mut cr = vec![1u8, 64u8];
            let pairs: [u8; 12] = [0x04, 0x03, 0x05, 0x03, 0x06, 0x03, 0x04, 0x01, 0x05, 0x01, 0x06, 0x01];
            cr.extend_from_slice(&(pairs.len() as u16).to_be_bytes());
            cr.extend_from_slice(&pairs);
            cr.extend_from_slice(&[0, 0]);
            flight.push(self.core.build_hs(&mut self.hs, dtls_handshake::CERTIFICATE_REQUEST, &cr, 0)?);
        }
        flight.push(self.core.build_hs(&mut self.hs, dtls_handshake::SERVER_HELLO_DONE, &[], 0)?);
        self.set_flight(flight.clone(), self.now_ms);
        out.extend(flight);
        self.stage = HsStage::ServerAwaitClientFlight;
        Ok(())
    }

    fn begin_resumed_accept(
        &mut self,
        session: DtlsSession,
        client_session_id: &[u8],
        out: &mut Vec<Vec<u8>>,
    ) -> io::Result<()> {
        self.core.master_secret = session.master_secret.clone();
        self.core.peer_certificate = Some(session.peer_certificate.clone());
        self.core.negotiated_srtp_profile = session.srtp_profile;
        self.core.resumed = true;

        let mut sh = Vec::new();
        sh.extend_from_slice(&DTLS_1_2);
        sh.extend_from_slice(&self.core.server_random);
        sh.push(client_session_id.len() as u8);
        sh.extend_from_slice(client_session_id);
        sh.extend_from_slice(&SUITE.to_be_bytes());
        sh.push(0);
        let mut exts = Vec::new();
        if let Some(profile) = session.srtp_profile {
            exts.extend_from_slice(&14u16.to_be_bytes());
            let data = [0u8, 2, (profile >> 8) as u8, profile as u8, 0];
            exts.extend_from_slice(&(data.len() as u16).to_be_bytes());
            exts.extend_from_slice(&data);
        }
        if self.client_ems {
            exts.extend_from_slice(&23u16.to_be_bytes());
            exts.extend_from_slice(&[0, 0]);
        }
        exts.extend_from_slice(&65281u16.to_be_bytes());
        exts.extend_from_slice(&[0, 1, 0]);
        sh.extend_from_slice(&(exts.len() as u16).to_be_bytes());
        sh.extend_from_slice(&exts);
        let sh_packet = self.core.build_hs(&mut self.hs, dtls_handshake::SERVER_HELLO, &sh, 0)?;
        self.core.derive_keys(&self.core.master_secret.clone());
        let ccs_packet = self.core.build_record(dtls_content::CHANGE_CIPHER_SPEC, 0, &[1])?;
        let verify_data = prf(&self.core.master_secret, "server finished", &self.hs.hash(), 12);
        let fin_packet = self.core.build_hs(&mut self.hs, dtls_handshake::FINISHED, &verify_data, 1)?;
        let flight = vec![sh_packet, ccs_packet, fin_packet];
        self.set_flight(flight.clone(), self.now_ms);
        out.extend(flight);
        self.stage = HsStage::ServerAwaitResumeClientFinished;
        Ok(())
    }

    fn on_client_flight(
        &mut self,
        msg_type: u8,
        raw: Vec<u8>,
        body: Vec<u8>,
        out: &mut Vec<Vec<u8>>,
    ) -> io::Result<()> {
        match msg_type {
            t if t == dtls_handshake::CERTIFICATE => {
                self.hs.transcript.extend_from_slice(&raw);
                if !body.is_empty() && body != [0u8, 0, 0] {
                    match parse_first_cert(&body) {
                        Ok(der) => {
                            self.core.peer_certificate = Some(der);
                            self.saw_client_cert = true;
                        }
                        Err(_) => self.saw_client_cert = false,
                    }
                }
                Ok(())
            }
            t if t == dtls_handshake::CLIENT_KEY_EXCHANGE => {
                self.hs.transcript.extend_from_slice(&raw);
                let mut r = Reader::new(&body);
                let point = r.vec8()?;
                let peer_eph = PublicKey::decode(point).ok_or_else(|| err("bad client ECDHE point"))?;
                let eph_private = self
                    .server_eph_private
                    .as_ref()
                    .ok_or_else(|| err("no server ephemeral"))?;
                let premaster = eph_private.ecdh(&peer_eph).ok_or_else(|| err("ECDH failed"))?;
                self.cke_hash = Some(self.hs.hash());
                self.core.master_secret = if self.client_ems {
                    prf(&premaster, "extended master secret", &self.cke_hash.unwrap(), 48)
                } else {
                    let mut seed = self.core.client_random.to_vec();
                    seed.extend_from_slice(&self.core.server_random);
                    prf(&premaster, "master secret", &seed, 48)
                };
                self.core.derive_keys(&self.core.master_secret.clone());
                Ok(())
            }
            t if t == dtls_handshake::CERTIFICATE_VERIFY => {
                let peer_key = self
                    .core
                    .peer_certificate
                    .as_deref()
                    .and_then(crate::x509::parse_public_key)
                    .ok_or_else(|| err("CertificateVerify without certificate"))?;
                let hash = self
                    .cke_hash
                    .ok_or_else(|| err("CertificateVerify before ClientKeyExchange"))?;
                let mut r = Reader::new(&body);
                let _alg = r.u16()?;
                let sig = r.vec16()?;
                let (sr, ss) = parse_ecdsa_sig_der(sig)?;
                if !peer_key.verify(&hash, &sr, &ss) {
                    return Err(err("CertificateVerify signature invalid"));
                }
                self.hs.transcript.extend_from_slice(&raw);
                Ok(())
            }
            t if t == dtls_handshake::FINISHED => {
                let expected = prf(&self.core.master_secret, "client finished", &self.hs.hash(), 12);
                if body != expected.as_slice() {
                    return Err(err("client Finished verification failed"));
                }
                self.hs.transcript.extend_from_slice(&raw);
                if self.require_peer_cert && !self.saw_client_cert {
                    return Err(err("peer presented no certificate"));
                }
                self.check_fingerprint()?;
                let mut flight: Vec<Vec<u8>> = Vec::new();
                if self.session_resumption && self.client_ticket.is_some() {
                    if let Some(key) = &self.ticket_key {
                        if let Some(packet) = self.core.build_session_ticket(&mut self.hs, key, 0) {
                            flight.push(packet);
                        }
                    }
                }
                flight.push(self.core.build_record(dtls_content::CHANGE_CIPHER_SPEC, 0, &[1])?);
                let verify_data = prf(&self.core.master_secret, "server finished", &self.hs.hash(), 12);
                flight.push(self.core.build_hs(&mut self.hs, dtls_handshake::FINISHED, &verify_data, 1)?);
                out.extend(flight);
                self.stage = HsStage::Established;
                Ok(())
            }
            _ => Err(err("unexpected message in client flight")),
        }
    }

    fn on_resume_client_finished(
        &mut self,
        msg_type: u8,
        raw: Vec<u8>,
        body: Vec<u8>,
        _out: &mut Vec<Vec<u8>>,
    ) -> io::Result<()> {
        if msg_type == dtls_handshake::FINISHED {
            let expected = prf(&self.core.master_secret, "client finished", &self.hs.hash(), 12);
            if body != expected.as_slice() {
                return Err(err("client Finished verification failed"));
            }
            self.hs.transcript.extend_from_slice(&raw);
            self.check_fingerprint()?;
            self.stage = HsStage::Established;
            return Ok(());
        }
        self.hs.transcript.extend_from_slice(&raw);
        Ok(())
    }
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
    /// The sans-io core (established-phase state).
    pub fn core(&self) -> &DtlsCore {
        &self.core
    }

    /// Consume the driver, leaving the pump-driven core.
    pub fn into_core(self) -> DtlsCore {
        self.core
    }

    /// Attach a core to a driver (e.g. after a driven
    /// handshake produced it, or to re-driver a core that
    /// was pumped sans-io).
    pub fn from_core(core: DtlsCore, io: I) -> Self {
        Self { io, core }
    }

    pub fn peer_fingerprint(&self) -> Option<String> {
        self.core.peer_fingerprint()
    }

    pub fn srtp_profile(&self) -> Option<u16> {
        self.core.srtp_profile()
    }

    pub fn export_keying_material(&self, label: &str, context: &[u8], len: usize) -> Vec<u8> {
        self.core.export_keying_material(label, context, len)
    }







    fn send_record(&mut self, content_type: u8, epoch: u16, body: &[u8]) -> io::Result<Vec<u8>> {
        let packet = self.core.build_record(content_type, epoch, body)?;
        self.io.send_packet(&packet)?;
        Ok(packet)
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


impl<I: DtlsIo> Dtls<I> {
    pub fn send_app(&mut self, data: &[u8]) -> io::Result<()> {
        self.send_record(dtls_content::APPLICATION_DATA, 1, data)?;
        Ok(())
    }

    /// Encrypt and send several application payloads, one
    /// DTLS record each, handed to the transport as a single
    /// batch (one sendmmsg where supported).
    pub fn send_app_batch(&mut self, datas: &[Vec<u8>]) -> io::Result<()> {
        if datas.len() == 1 {
            return self.send_app(&datas[0]);
        }
        let mut records = Vec::with_capacity(datas.len());
        for d in datas {
            records.push(self.core.build_record(dtls_content::APPLICATION_DATA, 1, d)?);
        }
        self.io.send_packets(&records)
    }

    /// Whether this connection came from an abbreviated
    /// (ticket-resumed) handshake rather than a full one.
    pub fn was_resumed(&self) -> bool {
        self.core.resumed
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
                    for record in self.core.parse_records(&packet)? {
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
        // Sub-millisecond timeouts must survive on std: the
        // endpoint pump passes 50 us receive slices while
        // active, and a whole-ms deadline would truncate those
        // to zero (the receive then never waits and packets
        // stall). Bare-metal builds keep the ms platform-clock
        // deadline (their callers pass >= 1 ms timeouts).
        #[cfg(feature = "std")]
        let deadline = std::time::Instant::now() + timeout;
        #[cfg(not(feature = "std"))]
        let deadline_ms = crate::platform::clock().now_ms() + timeout.as_millis() as u64;
        loop {
            #[cfg(feature = "std")]
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            #[cfg(not(feature = "std"))]
            let remaining = Duration::from_millis(
                deadline_ms.saturating_sub(crate::platform::clock().now_ms()),
            );
            if remaining.is_zero() {
                return Ok(None);
            }
            match self.io.recv_packet(remaining)? {
                Some(packet) => {
                    for record in self.core.parse_records(&packet)? {
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
        self.core.session.take()
    }

    fn handshake(
        io: I,
        config: &DtlsConfig,
        resume: Option<&DtlsSession>,
    ) -> io::Result<Self> {
        let clock = crate::platform::clock();
        let (machine, flight) = DtlsHandshake::new_client(config, resume, clock.now_ms())?;
        Self::drive(io, machine, flight)
    }

    /// Drive a DtlsHandshake to establishment over this
    /// connection's datagram IO.
    fn drive(mut io: I, mut machine: DtlsHandshake, initial: Vec<Vec<u8>>) -> io::Result<Self> {
        for packet in &initial {
            io.send_packet(packet)?;
        }
        let clock = crate::platform::clock();
        loop {
            if machine.established() {
                let core = machine.into_core().expect("established core");
                return Ok(Self::from_core(core, io));
            }
            if let Some(failure) = machine.failure() {
                return Err(err(failure));
            }
            let now = clock.now_ms();
            match machine.next_timeout(now) {
                Some(0) => {
                    for packet in machine.tick(now) {
                        io.send_packet(&packet)?;
                    }
                }
                wait => {
                    let timeout = Duration::from_millis(wait.unwrap_or(1000).max(1));
                    match io.recv_packet(timeout)? {
                        Some(packet) => {
                            let now = clock.now_ms();
                            for out in machine.handle_datagram(&packet, now) {
                                io.send_packet(&out)?;
                            }
                        }
                        None => {
                            let now = clock.now_ms();
                            for out in machine.tick(now) {
                                io.send_packet(&out)?;
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn accept(io: I, config: &DtlsConfig) -> io::Result<Self> {
        let clock = crate::platform::clock();
        let machine = DtlsHandshake::new_server(config, clock.now_ms());
        Self::drive(io, machine, Vec::new())
    }
}
