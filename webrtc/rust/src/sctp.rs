//! SCTP (RFC 9260) subset for WebRTC datachannels, as a pure
//! packet-in/packet-out state machine: callers feed received packets and
//! a millisecond clock, and get back packets to send plus events. That
//! makes the association deterministically testable without sockets and
//! lets it ride on anything message-shaped (here: DTLS records).
//!
//! Implemented: INIT/COOKIE 4-way handshake (HMAC state cookie),
//! DATA/SACK with gap reporting and fast retransmit, fragmentation and
//! reassembly, ordered and unordered delivery, PR-SCTP FORWARD-TSN for
//! partially-reliable abandonment, RE-CONFIG stream reset (RFC 6525,
//! for datachannel close), HEARTBEAT, SHUTDOWN handshake,
//! CRC-32C checksum (little-endian on the wire).

use alloc::vec::Vec;
use crate::crypto::{crc32c, hmac_sha256, random_bytes};
use crate::proto_gen::{sctp_chunk, sctp_param, sctp_reconfig};
use alloc::collections::{BTreeMap, BTreeSet, VecDeque};
#[cfg(feature = "std")]
use std::collections::{HashMap, HashSet};
#[cfg(not(feature = "std"))]
use alloc::collections::{BTreeMap as HashMap, BTreeSet as HashSet};

pub const SCTP_PORT: u16 = 5000;
const MAX_DATA_PAYLOAD: usize = 1000;
const INITIAL_RWND: u32 = 262_144;
const INITIAL_RTO_MS: u64 = 1000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Connected,
    Data { stream: u16, ppid: u32, payload: Vec<u8> },
    /// Both directions of a stream were reset (channel closed).
    StreamReset { stream: u16 },
    Closed,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SendOptions {
    pub unordered: bool,
    pub max_retransmits: Option<u32>,
    pub max_lifetime_ms: Option<u64>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    Closed,
    CookieWait,
    CookieEchoed,
    Established,
    ShutdownSent,
}

#[derive(Clone)]
struct OutChunk {
    tsn: u32,
    stream: u16,
    ssn: u16,
    ppid: u32,
    flags: u8,
    payload: Vec<u8>,
    opts: SendOptions,
    retransmits: u32,
    born_ms: u64,
    last_sent_ms: u64,
}

#[derive(Default)]
struct PartialMsg {
    ssn: u16,
    ppid: u32,
    unordered: bool,
    parts: BTreeMap<u32, Vec<u8>>,
    first_tsn: Option<u32>,
    last_tsn: Option<u32>,
}

#[derive(Default)]
struct StreamIn {
    next_ssn: u16,
    partials: HashMap<u32, PartialMsg>, // key: first TSN
    completed: BTreeMap<u16, (u32, Vec<u8>)>, // ordered, by SSN
}

pub struct Association {
    is_client: bool,
    local_port: u16,
    peer_port: u16,
    my_tag: u32,
    peer_tag: u32,
    state: State,
    next_tsn: u32,
    out_cum_done: u32, // highest TSN acked or abandoned, in order
    peer_cum_tsn: u32,
    peer_received: BTreeSet<u32>,
    peer_next_tsn_init: bool,
    out_ssn: HashMap<u16, u16>,
    unacked: BTreeMap<u32, OutChunk>,
    queued: VecDeque<(u16, u32, Vec<u8>, SendOptions)>,
    inflight_bytes: usize,
    peer_rwnd: u32,
    streams_in: HashMap<u16, StreamIn>,
    cookie_secret: [u8; 32],
    pending_cookie: Vec<u8>,
    last_init_ms: u64,
    last_packet_out_ms: u64,
    rto_ms: u64,
    miss_counts: HashMap<u32, u32>,
    abandoned_ordered: Vec<(u16, u16)>, // (stream, ssn) for FORWARD-TSN
    // Stream reset (RFC 6525) bookkeeping.
    reconf_seq: u32,
    resets: HashMap<u16, StreamResetState>,
    pending_reconf: Vec<PendingOutgoingReset>,
    local_reset_seqs: HashMap<u32, (u16, bool)>, // seq -> (stream, outgoing?)
    out_reset_done: HashSet<u16>,
    peer_initial_tsn: u32,
    last_peer_reconf_seq: Option<u32>,
}

#[derive(Default)]
struct StreamResetState {
    out_done: bool,
    in_done: bool,
    reported: bool,
}

struct PendingOutgoingReset {
    seq: u32,
    last_tsn: u32,
    streams: Vec<u16>,
}

fn pad4(data: &mut Vec<u8>) {
    while data.len() % 4 != 0 {
        data.push(0);
    }
}

fn chunk(chunk_type: u8, flags: u8, body: &[u8]) -> Vec<u8> {
    let mut out = vec![chunk_type, flags];
    out.extend_from_slice(&((body.len() + 4) as u16).to_be_bytes());
    out.extend_from_slice(body);
    pad4(&mut out);
    out
}

fn param(param_type: u16, value: &[u8]) -> Vec<u8> {
    let mut out = param_type.to_be_bytes().to_vec();
    out.extend_from_slice(&((value.len() + 4) as u16).to_be_bytes());
    out.extend_from_slice(value);
    pad4(&mut out);
    out
}

fn parse_params(data: &[u8]) -> Vec<(u16, Vec<u8>)> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos + 4 <= data.len() {
        let ty = u16::from_be_bytes([data[pos], data[pos + 1]]);
        let len = u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize;
        if len < 4 || pos + len > data.len() {
            break;
        }
        out.push((ty, data[pos + 4..pos + len].to_vec()));
        pos += (len + 3) & !3;
    }
    out
}

struct ChunkView<'a> {
    chunk_type: u8,
    flags: u8,
    body: &'a [u8],
}

fn reconfig_response_param(seq: u32, result: u32) -> Vec<u8> {
    let mut value = seq.to_be_bytes().to_vec();
    value.extend_from_slice(&result.to_be_bytes());
    param(sctp_reconfig::RECONFIGURATION_RESPONSE, &value)
}

fn parse_chunks(data: &[u8]) -> Vec<ChunkView<'_>> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos + 4 <= data.len() {
        let len = u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize;
        if len < 4 || pos + len > data.len() {
            break;
        }
        out.push(ChunkView {
            chunk_type: data[pos],
            flags: data[pos + 1],
            body: &data[pos + 4..pos + len],
        });
        pos += (len + 3) & !3;
    }
    out
}

impl Association {
    pub fn new_client(local_port: u16, peer_port: u16) -> Self {
        let tag = u32::from_be_bytes(random_bytes(4).try_into().unwrap()) | 1;
        let tsn = u32::from_be_bytes(random_bytes(4).try_into().unwrap());
        Self {
            is_client: true,
            local_port,
            peer_port,
            my_tag: tag,
            peer_tag: 0,
            state: State::Closed,
            next_tsn: tsn,
            out_cum_done: tsn.wrapping_sub(1),
            peer_cum_tsn: 0,
            peer_received: BTreeSet::new(),
            peer_next_tsn_init: false,
            out_ssn: HashMap::new(),
            unacked: BTreeMap::new(),
            queued: VecDeque::new(),
            inflight_bytes: 0,
            peer_rwnd: INITIAL_RWND,
            streams_in: HashMap::new(),
            cookie_secret: random_bytes(32).try_into().unwrap(),
            pending_cookie: Vec::new(),
            last_init_ms: 0,
            last_packet_out_ms: 0,
            rto_ms: INITIAL_RTO_MS,
            miss_counts: HashMap::new(),
            abandoned_ordered: Vec::new(),
            reconf_seq: tsn,
            resets: HashMap::new(),
            pending_reconf: Vec::new(),
            local_reset_seqs: HashMap::new(),
            out_reset_done: HashSet::new(),
            peer_initial_tsn: 0,
            last_peer_reconf_seq: None,
        }
    }

    /// A listening (server) association endpoint for one peer.
    pub fn new_server(local_port: u16, peer_port: u16) -> Self {
        let mut a = Self::new_client(local_port, peer_port);
        a.is_client = false;
        a
    }

    pub fn is_established(&self) -> bool {
        self.state == State::Established
    }

    fn packet(&self, vtag: u32, chunks: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.local_port.to_be_bytes());
        out.extend_from_slice(&self.peer_port.to_be_bytes());
        out.extend_from_slice(&vtag.to_be_bytes());
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.extend_from_slice(chunks);
        let sum = crc32c(&out);
        out[8..12].copy_from_slice(&sum.to_le_bytes());
        out
    }

    fn init_body(&self) -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&self.my_tag.to_be_bytes());
        body.extend_from_slice(&INITIAL_RWND.to_be_bytes());
        body.extend_from_slice(&1024u16.to_be_bytes()); // outbound streams offered
        body.extend_from_slice(&1024u16.to_be_bytes()); // inbound streams accepted
        body.extend_from_slice(&self.next_tsn.to_be_bytes());
        // Supported address types (IPv4) so strict peers are satisfied.
        body.extend_from_slice(&param(12, &[0, 5, 0, 6]));
        body.extend_from_slice(&param(sctp_param::FORWARD_TSN_SUPPORTED, &[]));
        // Supported Extensions: RE-CONFIG (130) and FORWARD-TSN (192).
        body.extend_from_slice(&param(
            sctp_param::SUPPORTED_EXTENSIONS,
            &[sctp_chunk::RE_CONFIG, sctp_chunk::FORWARD_TSN],
        ));
        body
    }

    // -- initiation -------------------------------------------------------------

    /// Client: produce the INIT packet and move to CookieWait.
    pub fn connect(&mut self, now_ms: u64) -> Vec<u8> {
        self.state = State::CookieWait;
        self.last_init_ms = now_ms;
        self.packet(0, &chunk(sctp_chunk::INIT, 0, &self.init_body()))
    }

    fn make_cookie(&self, peer_tag: u32, peer_tsn: u32, my_tsn: u32) -> Vec<u8> {
        // Layout: peer_tag(4) my_tag(4) peer_tsn(4) my_tsn(4) mac(16)
        let mut data = Vec::new();
        data.extend_from_slice(&peer_tag.to_be_bytes());
        data.extend_from_slice(&self.my_tag.to_be_bytes());
        data.extend_from_slice(&peer_tsn.to_be_bytes());
        data.extend_from_slice(&my_tsn.to_be_bytes());
        let mac = hmac_sha256(&self.cookie_secret, &[&data]);
        data.extend_from_slice(&mac[..16]);
        data
    }

    fn check_cookie(&self, cookie: &[u8]) -> Option<(u32, u32, u32, u32)> {
        if cookie.len() != 32 {
            return None;
        }
        let mac = hmac_sha256(&self.cookie_secret, &[&cookie[..16]]);
        if mac[..16] != cookie[16..] {
            return None;
        }
        let rd = |o: usize| u32::from_be_bytes(cookie[o..o + 4].try_into().unwrap());
        Some((rd(0), rd(4), rd(8), rd(12)))
    }

    // -- sending ------------------------------------------------------------------

    /// Close one stream (RFC 8831 §6.4): reset our outgoing side
    /// with an Outgoing SSN Reset Request. The peer resets its
    /// outgoing side in turn; Event::StreamReset fires once both
    /// directions are done.
    pub fn close_stream(&mut self, stream: u16) -> Vec<Vec<u8>> {
        match self.initiate_outgoing_reset(stream) {
            Some(packet) => vec![packet],
            None => Vec::new(),
        }
    }

    fn response_seq_for_outgoing(&self) -> u32 {
        // Next expected peer request sequence minus 1 (RFC 6525
        // §4.1): the last request sequence received, or the
        // peer's initial TSN minus 1.
        self.last_peer_reconf_seq
            .unwrap_or_else(|| self.peer_initial_tsn.wrapping_sub(1))
    }

    fn initiate_outgoing_reset(&mut self, stream: u16) -> Option<Vec<u8>> {
        if self.state != State::Established || self.out_reset_done.contains(&stream) {
            return None;
        }
        self.out_reset_done.insert(stream);
        self.queued.retain(|(s, _, _, _)| *s != stream);
        let seq = self.reconf_seq;
        self.reconf_seq = self.reconf_seq.wrapping_add(1);
        self.local_reset_seqs.insert(seq, (stream, true));
        self.resets.entry(stream).or_default();

        let mut value = seq.to_be_bytes().to_vec();
        value.extend_from_slice(&self.response_seq_for_outgoing().to_be_bytes());
        value.extend_from_slice(&self.next_tsn.wrapping_sub(1).to_be_bytes());
        value.extend_from_slice(&stream.to_be_bytes());
        let params = param(sctp_reconfig::OUTGOING_SSN_RESET_REQUEST, &value);
        Some(self.packet(self.peer_tag, &chunk(sctp_chunk::RE_CONFIG, 0, &params)))
    }

    fn maybe_report_reset(&mut self, stream: u16, events: &mut Vec<Event>) {
        let st = self.resets.entry(stream).or_default();
        if st.out_done && st.in_done && !st.reported {
            st.reported = true;
            events.push(Event::StreamReset { stream });
        }
    }

    fn reset_incoming_side(
        &mut self,
        stream: u16,
        packets: Option<&mut Vec<Vec<u8>>>,
        events: &mut Vec<Event>,
    ) {
        if self.streams_in.contains_key(&stream) {
            self.drain_stream(stream, events);
            let entry = self.streams_in.get_mut(&stream).unwrap();
            entry.partials.clear();
            entry.completed.clear();
            entry.next_ssn = 0;
        }
        self.resets.entry(stream).or_default().in_done = true;
        self.maybe_report_reset(stream, events);
        // RFC 8831 §6.4: seeing the peer reset its outgoing
        // side, reset our corresponding outgoing side too.
        if let Some(packets) = packets {
            if let Some(packet) = self.initiate_outgoing_reset(stream) {
                packets.push(packet);
            }
        }
    }

    fn reset_outgoing_side(&mut self, stream: u16, events: &mut Vec<Event>) {
        self.out_ssn.insert(stream, 0);
        self.out_reset_done.insert(stream);
        self.queued.retain(|(s, _, _, _)| *s != stream);
        let dropped: Vec<u32> = self
            .unacked
            .iter()
            .filter(|(_, c)| c.stream == stream)
            .map(|(&tsn, _)| tsn)
            .collect();
        for tsn in dropped {
            if let Some(c) = self.unacked.remove(&tsn) {
                self.inflight_bytes = self.inflight_bytes.saturating_sub(c.payload.len());
            }
        }
        self.resets.entry(stream).or_default().out_done = true;
        self.maybe_report_reset(stream, events);
    }

    fn process_pending_resets(&mut self, packets: &mut Vec<Vec<u8>>, events: &mut Vec<Event>) {
        let mut remaining = Vec::new();
        for pending in core::mem::take(&mut self.pending_reconf) {
            if (pending.last_tsn.wrapping_sub(self.peer_cum_tsn) as i32) > 0 {
                remaining.push(pending);
                continue;
            }
            for stream in &pending.streams {
                self.reset_incoming_side(*stream, Some(packets), events);
            }
            packets.push(self.packet(
                self.peer_tag,
                &chunk(sctp_chunk::RE_CONFIG, 0, &reconfig_response_param(pending.seq, 1)),
            ));
        }
        self.pending_reconf = remaining;
    }

    fn handle_reconfig(&mut self, body: &[u8], packets: &mut Vec<Vec<u8>>, events: &mut Vec<Event>) {
        let mut responses: Vec<u8> = Vec::new();
        for (ty, value) in parse_params(body) {
            match ty {
                t if t == sctp_reconfig::OUTGOING_SSN_RESET_REQUEST => {
                    // Value: request seq, response seq, sender
                    // last assigned TSN, streams (RFC 6525 §4.1).
                    if value.len() < 12 {
                        continue;
                    }
                    let seq = u32::from_be_bytes(value[0..4].try_into().unwrap());
                    let response_seq = u32::from_be_bytes(value[4..8].try_into().unwrap());
                    let last_tsn = u32::from_be_bytes(value[8..12].try_into().unwrap());
                    self.last_peer_reconf_seq = Some(seq);
                    // Implicit answer to our Incoming request
                    // whose sequence this echoes (§4.1).
                    if let Some(&(stream, false)) = self.local_reset_seqs.get(&response_seq) {
                        self.local_reset_seqs.remove(&response_seq);
                        self.resets.entry(stream).or_default().in_done = true;
                        self.maybe_report_reset(stream, events);
                    }
                    let mut streams: Vec<u16> = value[12..]
                        .chunks_exact(2)
                        .map(|c| u16::from_be_bytes([c[0], c[1]]))
                        .collect();
                    if streams.is_empty() {
                        streams = self.streams_in.keys().copied().collect();
                    }
                    if (last_tsn.wrapping_sub(self.peer_cum_tsn) as i32) > 0 {
                        self.pending_reconf.push(PendingOutgoingReset { seq, last_tsn, streams });
                        continue;
                    }
                    for stream in &streams.clone() {
                        self.reset_incoming_side(*stream, Some(packets), events);
                    }
                    responses.extend_from_slice(&reconfig_response_param(seq, 1));
                }
                t if t == sctp_reconfig::INCOMING_SSN_RESET_REQUEST => {
                    if value.len() < 4 {
                        continue;
                    }
                    let seq = u32::from_be_bytes(value[0..4].try_into().unwrap());
                    self.last_peer_reconf_seq = Some(seq);
                    for c in value[4..].chunks_exact(2) {
                        self.reset_outgoing_side(u16::from_be_bytes([c[0], c[1]]), events);
                    }
                    responses.extend_from_slice(&reconfig_response_param(seq, 1));
                }
                t if t == sctp_reconfig::RECONFIGURATION_RESPONSE => {
                    if value.len() < 8 {
                        continue;
                    }
                    let seq = u32::from_be_bytes(value[0..4].try_into().unwrap());
                    let result = u32::from_be_bytes(value[4..8].try_into().unwrap());
                    if let Some((stream, outgoing)) = self.local_reset_seqs.remove(&seq) {
                        if result == 0 || result == 1 {
                            if outgoing {
                                self.resets.entry(stream).or_default().out_done = true;
                            } else {
                                self.resets.entry(stream).or_default().in_done = true;
                            }
                            self.maybe_report_reset(stream, events);
                        }
                    }
                }
                _ => {
                    if value.len() >= 4 {
                        let seq = u32::from_be_bytes(value[0..4].try_into().unwrap());
                        responses.extend_from_slice(&reconfig_response_param(seq, 2));
                    }
                }
            }
        }
        if !responses.is_empty() {
            packets.push(self.packet(self.peer_tag, &chunk(sctp_chunk::RE_CONFIG, 0, &responses)));
        }
    }

    pub fn send_data(
        &mut self,
        stream: u16,
        ppid: u32,
        payload: &[u8],
        opts: SendOptions,
        now_ms: u64,
    ) -> Vec<Vec<u8>> {
        if self.out_reset_done.contains(&stream) {
            return Vec::new(); // stream reset/closing
        }
        if self.state != State::Established
            || self.inflight_bytes >= self.peer_rwnd as usize
        {
            // Not established, or the peer receive window is full:
            // hold the payload; handle_sack flushes the queue as
            // SACKs free window. Sending past rwnd anyway (the old
            // behavior) bursts megabytes into kernel buffers, which
            // drop most of it and throttle the association to RTO
            // retransmits (~1s stalls; bench-mux blast collapsed
            // from ~3800 to ~1000 msgs/s at 2000x1KiB).
            self.queued.push_back((stream, ppid, payload.to_vec(), opts));
            return Vec::new();
        }
        self.enqueue_and_flush(stream, ppid, payload, opts, now_ms)
    }

    fn enqueue_and_flush(
        &mut self,
        stream: u16,
        ppid: u32,
        payload: &[u8],
        opts: SendOptions,
        now_ms: u64,
    ) -> Vec<Vec<u8>> {
        let ssn = if opts.unordered {
            0
        } else {
            let counter = self.out_ssn.entry(stream).or_insert(0);
            let ssn = *counter;
            *counter = counter.wrapping_add(1);
            ssn
        };
        let fragments: Vec<&[u8]> = if payload.is_empty() {
            vec![&payload[..0]]
        } else {
            payload.chunks(MAX_DATA_PAYLOAD).collect()
        };
        let total = fragments.len();
        let mut chunks = Vec::new();
        for (i, frag) in fragments.iter().enumerate() {
            let mut flags = 0u8;
            if opts.unordered {
                flags |= 0x04;
            }
            if i == 0 {
                flags |= 0x02; // B
            }
            if i == total - 1 {
                flags |= 0x01; // E
            }
            let tsn = self.next_tsn;
            self.next_tsn = self.next_tsn.wrapping_add(1);
            let mut body = Vec::new();
            body.extend_from_slice(&tsn.to_be_bytes());
            body.extend_from_slice(&stream.to_be_bytes());
            body.extend_from_slice(&ssn.to_be_bytes());
            body.extend_from_slice(&ppid.to_be_bytes());
            body.extend_from_slice(frag);
            chunks.push(OutChunk {
                tsn,
                stream,
                ssn,
                ppid,
                flags,
                payload: frag.to_vec(),
                opts,
                retransmits: 0,
                born_ms: now_ms,
                last_sent_ms: now_ms,
            });
        }
        let mut packets = Vec::new();
        for c in chunks {
            self.inflight_bytes += c.payload.len();
            packets.push(self.packet(self.peer_tag, &data_chunk_bytes(&c)));
            self.unacked.insert(c.tsn, c);
        }
        self.last_packet_out_ms = now_ms;
        packets
    }

    fn flush_queue(&mut self, now_ms: u64) -> Vec<Vec<u8>> {
        let mut packets = Vec::new();
        while self.inflight_bytes < self.peer_rwnd as usize {
            let Some((stream, ppid, payload, opts)) = self.queued.pop_front() else {
                break;
            };
            packets.extend(self.enqueue_and_flush(stream, ppid, &payload, opts, now_ms));
        }
        packets
    }

    fn sack_packet(&self) -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&self.peer_cum_tsn.to_be_bytes());
        body.extend_from_slice(&INITIAL_RWND.to_be_bytes());
        // Gap blocks from peer_received above the cumulative TSN.
        let mut gaps: Vec<(u16, u16)> = Vec::new();
        let mut iter = self.peer_received.iter().peekable();
        while let Some(&start) = iter.next() {
            if start <= self.peer_cum_tsn {
                continue;
            }
            let mut end = start;
            while let Some(&&next) = iter.peek() {
                if next == end.wrapping_add(1) {
                    end = next;
                    iter.next();
                } else {
                    break;
                }
            }
            gaps.push((
                start.wrapping_sub(self.peer_cum_tsn) as u16,
                end.wrapping_sub(self.peer_cum_tsn) as u16,
            ));
        }
        body.extend_from_slice(&(gaps.len() as u16).to_be_bytes());
        body.extend_from_slice(&0u16.to_be_bytes()); // no duplicate TSNs reported
        for (s, e) in gaps {
            body.extend_from_slice(&s.to_be_bytes());
            body.extend_from_slice(&e.to_be_bytes());
        }
        self.packet(self.peer_tag, &chunk(sctp_chunk::SACK, 0, &body))
    }

    // -- receiving ------------------------------------------------------------------

    pub fn handle_packet(
        &mut self,
        packet: &[u8],
        now_ms: u64,
    ) -> (Vec<Vec<u8>>, Vec<Event>) {
        let mut packets = Vec::new();
        let mut events = Vec::new();
        if packet.len() < 12 {
            return (packets, events);
        }
        // Verify CRC32C (field stored little-endian).
        let mut check = packet.to_vec();
        check[8..12].copy_from_slice(&[0, 0, 0, 0]);
        if crc32c(&check) != u32::from_le_bytes(packet[8..12].try_into().unwrap()) {
            return (packets, events);
        }
        let vtag = u32::from_be_bytes(packet[4..8].try_into().unwrap());
        for view in parse_chunks(&packet[12..]) {
            match view.chunk_type {
                t if t == sctp_chunk::INIT => {
                    if self.is_client {
                        continue;
                    }
                    let mut r = view.body;
                    if r.len() < 16 {
                        continue;
                    }
                    let peer_tag = u32::from_be_bytes(r[0..4].try_into().unwrap());
                    let peer_tsn = u32::from_be_bytes(r[12..16].try_into().unwrap());
                    self.peer_initial_tsn = peer_tsn;
                    let _ = &mut r;
                    let my_tsn = self.next_tsn;
                    let cookie = self.make_cookie(peer_tag, peer_tsn, my_tsn);
                    let mut body = self.init_body();
                    body.extend_from_slice(&param(7, &cookie));
                    packets.push(self.packet(peer_tag, &chunk(sctp_chunk::INIT_ACK, 0, &body)));
                }
                t if t == sctp_chunk::INIT_ACK => {
                    if !self.is_client || self.state != State::CookieWait {
                        continue;
                    }
                    if view.body.len() < 16 {
                        continue;
                    }
                    self.peer_tag = u32::from_be_bytes(view.body[0..4].try_into().unwrap());
                    self.peer_initial_tsn =
                        u32::from_be_bytes(view.body[12..16].try_into().unwrap());
                    self.peer_cum_tsn = self.peer_initial_tsn.wrapping_sub(1);
                    self.peer_next_tsn_init = true;
                    for (ty, value) in parse_params(&view.body[16..]) {
                        if ty == 7 {
                            self.pending_cookie = value;
                        }
                    }
                    self.state = State::CookieEchoed;
                    self.last_init_ms = now_ms;
                    packets.push(
                        self.packet(self.peer_tag, &chunk(sctp_chunk::COOKIE_ECHO, 0, &self.pending_cookie)),
                    );
                }
                t if t == sctp_chunk::COOKIE_ECHO => {
                    if self.is_client {
                        continue;
                    }
                    let Some((peer_tag, my_tag, peer_tsn, my_tsn)) =
                        self.check_cookie(view.body)
                    else {
                        continue;
                    };
                    self.peer_tag = peer_tag;
                    self.my_tag = my_tag;
                    self.peer_initial_tsn = peer_tsn;
                    self.peer_cum_tsn = peer_tsn.wrapping_sub(1);
                    self.peer_next_tsn_init = true;
                    self.next_tsn = my_tsn;
                    self.out_cum_done = my_tsn.wrapping_sub(1);
                    self.state = State::Established;
                    packets.push(self.packet(self.peer_tag, &chunk(sctp_chunk::COOKIE_ACK, 0, &[])));
                    events.push(Event::Connected);
                    packets.extend(self.flush_queue(now_ms));
                }
                t if t == sctp_chunk::COOKIE_ACK => {
                    if self.is_client && self.state == State::CookieEchoed {
                        self.state = State::Established;
                        events.push(Event::Connected);
                        packets.extend(self.flush_queue(now_ms));
                    }
                }
                t if t == sctp_chunk::DATA => {
                    if vtag != self.my_tag && self.state == State::Established {
                        continue;
                    }
                    self.handle_data(view.flags, view.body, &mut events);
                    packets.push(self.sack_packet());
                }
                t if t == sctp_chunk::SACK => {
                    packets.extend(self.handle_sack(view.body, now_ms));
                }
                t if t == sctp_chunk::HEARTBEAT => {
                    let mut body = Vec::new();
                    body.extend_from_slice(view.body);
                    packets.push(self.packet(self.peer_tag, &chunk(sctp_chunk::HEARTBEAT_ACK, 0, &body)));
                }
                t if t == sctp_chunk::RE_CONFIG => {
                    // body is borrowed from the packet; own it
                    // for the handler's mutable borrows.
                    let body = view.body.to_vec();
                    self.handle_reconfig(&body, &mut packets, &mut events);
                }
                t if t == sctp_chunk::FORWARD_TSN => {
                    self.handle_forward_tsn(view.body, &mut events);
                    packets.push(self.sack_packet());
                }
                t if t == sctp_chunk::SHUTDOWN => {
                    if view.body.len() >= 4 {
                        // cumulative TSN ack piggybacked; just answer
                    }
                    packets.push(self.packet(self.peer_tag, &chunk(sctp_chunk::SHUTDOWN_ACK, 0, &[])));
                    self.state = State::Closed;
                    events.push(Event::Closed);
                }
                t if t == sctp_chunk::SHUTDOWN_ACK => {
                    packets.push(
                        self.packet(self.peer_tag, &chunk(sctp_chunk::SHUTDOWN_COMPLETE, 0, &[])),
                    );
                    self.state = State::Closed;
                    events.push(Event::Closed);
                }
                t if t == sctp_chunk::SHUTDOWN_COMPLETE | sctp_chunk::ABORT => {
                    self.state = State::Closed;
                    events.push(Event::Closed);
                }
                _ => {} // unknown chunk: skip per RFC rules for 00/01 top bits handled loosely
            }
        }
        // Cumulative TSN may have advanced: apply deferred resets.
        self.process_pending_resets(&mut packets, &mut events);
        (packets, events)
    }

    fn handle_data(&mut self, flags: u8, body: &[u8], events: &mut Vec<Event>) {
        if body.len() < 12 {
            return;
        }
        let tsn = u32::from_be_bytes(body[0..4].try_into().unwrap());
        let stream = u16::from_be_bytes(body[4..6].try_into().unwrap());
        let ssn = u16::from_be_bytes(body[6..8].try_into().unwrap());
        let ppid = u32::from_be_bytes(body[8..12].try_into().unwrap());
        let payload = body[12..].to_vec();
        let unordered = flags & 0x04 != 0;
        let is_begin = flags & 0x02 != 0;
        let is_end = flags & 0x01 != 0;

        // TSN bookkeeping for SACK generation.
        if (tsn.wrapping_sub(self.peer_cum_tsn) as i32) > 0 {
            self.peer_received.insert(tsn);
            while self.peer_received.contains(&self.peer_cum_tsn.wrapping_add(1)) {
                self.peer_cum_tsn = self.peer_cum_tsn.wrapping_add(1);
                self.peer_received.remove(&self.peer_cum_tsn);
            }
        }

        let entry = self.streams_in.entry(stream).or_default();
        // Find or create the partial message this fragment belongs to.
        let key = if is_begin { tsn } else {
            // Fragment continuation: attach to the open partial whose
            // fragments end just before this TSN.
            entry
                .partials
                .iter()
                .find(|(_, p)| p.parts.keys().max().map_or(false, |&m| m.wrapping_add(1) == tsn))
                .map(|(&k, _)| k)
                .unwrap_or(tsn)
        };
        let partial = entry.partials.entry(key).or_default();
        if is_begin {
            partial.ssn = ssn;
            partial.ppid = ppid;
            partial.unordered = unordered;
            partial.first_tsn = Some(tsn);
        }
        if is_end {
            partial.last_tsn = Some(tsn);
        }
        partial.parts.insert(tsn, payload);

        let complete = match (partial.first_tsn, partial.last_tsn) {
            (Some(first), Some(last)) => {
                let count = last.wrapping_sub(first) as usize + 1;
                partial.parts.len() == count
                    && (0..count).all(|i| partial.parts.contains_key(&first.wrapping_add(i as u32)))
            }
            _ => false,
        };
        if complete {
            let partial = entry.partials.remove(&key).unwrap();
            let mut payload = Vec::new();
            let first = partial.first_tsn.unwrap();
            for i in 0..partial.parts.len() {
                payload.extend_from_slice(&partial.parts[&first.wrapping_add(i as u32)]);
            }
            if partial.unordered {
                events.push(Event::Data { stream, ppid: partial.ppid, payload });
                return;
            }
            entry.completed.insert(partial.ssn, (partial.ppid, payload));
            // `entry` borrow ends here; drain in SSN order below.
            self.drain_stream(stream, events);
        }
    }

    fn handle_forward_tsn(&mut self, body: &[u8], events: &mut Vec<Event>) {
        if body.len() < 4 {
            return;
        }
        let new_cum = u32::from_be_bytes(body[0..4].try_into().unwrap());
        if (new_cum.wrapping_sub(self.peer_cum_tsn) as i32) > 0 {
            self.peer_received.retain(|&t| (t.wrapping_sub(new_cum) as i32) > 0);
            self.peer_cum_tsn = new_cum;
        }
        let mut pos = 4;
        while pos + 4 <= body.len() {
            let stream = u16::from_be_bytes(body[pos..pos + 2].try_into().unwrap());
            let ssn = u16::from_be_bytes(body[pos + 2..pos + 4].try_into().unwrap());
            pos += 4;
            let entry = self.streams_in.entry(stream).or_default();
            entry.completed.retain(|&s, _| s > ssn);
            if entry.next_ssn <= ssn {
                entry.next_ssn = ssn.wrapping_add(1);
            }
            entry.partials.retain(|_, p| p.unordered || p.ssn != ssn);
            self.drain_stream(stream, events);
        }
    }

    fn drain_stream(&mut self, stream: u16, events: &mut Vec<Event>) {
        let entry = self.streams_in.entry(stream).or_default();
        while let Some((ppid, payload)) = entry.completed.remove(&entry.next_ssn) {
            entry.next_ssn = entry.next_ssn.wrapping_add(1);
            events.push(Event::Data { stream, ppid, payload });
        }
    }

    fn handle_sack(&mut self, body: &[u8], now_ms: u64) -> Vec<Vec<u8>> {
        let mut packets = Vec::new();
        if body.len() < 12 {
            return packets;
        }
        let cum = u32::from_be_bytes(body[0..4].try_into().unwrap());
        self.peer_rwnd = u32::from_be_bytes(body[4..8].try_into().unwrap());
        let num_gaps = u16::from_be_bytes(body[8..10].try_into().unwrap()) as usize;
        let mut acked: Vec<u32> = Vec::new();
        let mut gap_ranges: Vec<(u32, u32)> = Vec::new();
        let mut pos = 12;
        for _ in 0..num_gaps {
            if pos + 4 > body.len() {
                break;
            }
            let s = u16::from_be_bytes(body[pos..pos + 2].try_into().unwrap()) as u32;
            let e = u16::from_be_bytes(body[pos + 2..pos + 4].try_into().unwrap()) as u32;
            pos += 4;
            gap_ranges.push((cum.wrapping_add(s), cum.wrapping_add(e)));
            for t in s..=e {
                acked.push(cum.wrapping_add(t));
            }
        }
        // Cumulative + gap acked TSNs leave the retransmission queue.
        let mut freed = 0usize;
        let keys: Vec<u32> = self.unacked.keys().copied().collect();
        for tsn in keys {
            let in_gap = gap_ranges.iter().any(|&(s, e)| {
                (tsn.wrapping_sub(s) as i32) >= 0 && (tsn.wrapping_sub(e) as i32) <= 0
            });
            if (tsn.wrapping_sub(cum) as i32) <= 0 || in_gap {
                if let Some(c) = self.unacked.remove(&tsn) {
                    freed += c.payload.len();
                }
                self.miss_counts.remove(&tsn);
            }
        }
        self.inflight_bytes = self.inflight_bytes.saturating_sub(freed);
        self.advance_out_cum();
        // Fast retransmit: TSNs below the first gap start counted as missed.
        if let Some(&(first_start, _)) = gap_ranges.first() {
            let missing: Vec<u32> = self
                .unacked
                .keys()
                .copied()
                .filter(|&t| (t.wrapping_sub(cum) as i32) > 0 && (t.wrapping_sub(first_start) as i32) < 0)
                .collect();
            for tsn in missing {
                let count = {
                    let e = self.miss_counts.entry(tsn).or_insert(0);
                    *e += 1;
                    *e
                };
                if count >= 3 {
                    if let Some(c) = self.unacked.get(&tsn).cloned() {
                        self.miss_counts.remove(&tsn);
                        packets.push(self.packet(self.peer_tag, &data_chunk_bytes(&c)));
                        if let Some(stored) = self.unacked.get_mut(&tsn) {
                            stored.retransmits += 1;
                            stored.last_sent_ms = now_ms;
                        }
                    }
                }
            }
        }
        packets.extend(self.flush_queue(now_ms));
        packets
    }

    // -- timers -------------------------------------------------------------------

    pub fn tick(&mut self, now_ms: u64) -> (Vec<Vec<u8>>, Vec<Event>) {
        let mut packets = Vec::new();
        let events = Vec::new();
        match self.state {
            State::CookieWait | State::CookieEchoed if now_ms - self.last_init_ms >= self.rto_ms => {
                self.last_init_ms = now_ms;
                if self.state == State::CookieWait {
                    packets.push(self.packet(0, &chunk(sctp_chunk::INIT, 0, &self.init_body())));
                } else {
                    packets.push(
                        self.packet(self.peer_tag, &chunk(sctp_chunk::COOKIE_ECHO, 0, &self.pending_cookie)),
                    );
                }
            }
            _ => {}
        }
        if self.state == State::Established {
            // PR-SCTP abandonment is decided at retransmission time: a
            // chunk whose lifetime expired, or whose retransmission
            // budget is spent, is abandoned (FORWARD-TSN) instead of
            // being sent again; other expired chunks are retransmitted.
            let mut abandoned_any = false;
            let candidates: Vec<OutChunk> = self.unacked.values().cloned().collect();
            let mut to_retransmit: Vec<OutChunk> = Vec::new();
            for c in candidates {
                let expired = now_ms - c.last_sent_ms >= self.rto_ms;
                let lifetime_out =
                    c.opts.max_lifetime_ms.map_or(false, |life| now_ms - c.born_ms > life);
                let budget_out =
                    expired && c.opts.max_retransmits.map_or(false, |max| c.retransmits >= max);
                if lifetime_out || budget_out {
                    if let Some(gone) = self.unacked.remove(&c.tsn) {
                        self.inflight_bytes =
                            self.inflight_bytes.saturating_sub(gone.payload.len());
                        if !gone.opts.unordered {
                            self.abandoned_ordered.push((gone.stream, gone.ssn));
                        }
                        abandoned_any = true;
                    }
                } else if expired {
                    to_retransmit.push(c);
                }
            }
            if abandoned_any {
                self.advance_out_cum();
                let mut body = Vec::new();
                body.extend_from_slice(&self.out_cum_done.to_be_bytes());
                for (stream, ssn) in self.abandoned_ordered.drain(..) {
                    body.extend_from_slice(&stream.to_be_bytes());
                    body.extend_from_slice(&ssn.to_be_bytes());
                }
                packets.push(self.packet(self.peer_tag, &chunk(sctp_chunk::FORWARD_TSN, 0, &body)));
            }
            for c in &to_retransmit {
                packets.push(self.packet(self.peer_tag, &data_chunk_bytes(c)));
            }
            for c in to_retransmit {
                if let Some(stored) = self.unacked.get_mut(&c.tsn) {
                    stored.retransmits += 1;
                    stored.last_sent_ms = now_ms;
                }
            }
            // Heartbeat if the association has been quiet.
            if now_ms - self.last_packet_out_ms >= 30_000 {
                self.last_packet_out_ms = now_ms;
                let info = now_ms.to_be_bytes();
                let body = param(1, &info);
                packets.push(self.packet(self.peer_tag, &chunk(sctp_chunk::HEARTBEAT, 0, &body)));
            }
        }
        (packets, events)
    }

    fn advance_out_cum(&mut self) {
        loop {
            let next = self.out_cum_done.wrapping_add(1);
            if next == self.next_tsn || self.unacked.contains_key(&next) {
                break;
            }
            self.out_cum_done = next;
        }
    }

    pub fn close(&mut self, _now_ms: u64) -> Vec<Vec<u8>> {
        if self.state == State::Established {
            self.state = State::ShutdownSent;
            let mut body = Vec::new();
            body.extend_from_slice(&self.peer_cum_tsn.to_be_bytes());
            vec![self.packet(self.peer_tag, &chunk(sctp_chunk::SHUTDOWN, 0, &body))]
        } else {
            Vec::new()
        }
    }
}

fn data_chunk_bytes(c: &OutChunk) -> Vec<u8> {
    let mut body = Vec::new();
    body.extend_from_slice(&c.tsn.to_be_bytes());
    body.extend_from_slice(&c.stream.to_be_bytes());
    body.extend_from_slice(&c.ssn.to_be_bytes());
    body.extend_from_slice(&c.ppid.to_be_bytes());
    body.extend_from_slice(&c.payload);
    chunk(sctp_chunk::DATA, c.flags, &body)
}
