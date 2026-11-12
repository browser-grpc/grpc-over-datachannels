//! Threaded datachannel endpoint: owns a DTLS connection and the SCTP
//! association on one thread, exposes channels over std::sync::mpsc.
//! This is the layer a gRPC transport (or an application) sits on.

use crate::dcep::{
    decode_open, encode_ack, encode_open, is_ack, ChannelParams, PPID_BINARY, PPID_BINARY_EMPTY,
    PPID_DCEP, PPID_STRING, PPID_STRING_EMPTY,
};
use crate::dtls::{Dtls, DtlsIo, Role};
use crate::sctp::{Association, Event as SctpEvent};
use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub enum EndpointEvent {
    /// A peer opened a channel to us.
    ChannelOpened { channel: ChannelHandle },
    Message { stream: u16, text: bool, data: Vec<u8> },
    ChannelClosed { stream: u16 },
}

/// DC message chunking (mirrors js/src/chunking.js and the
/// JS/Go stacks): browsers cap one RTCDataChannel message at
/// the negotiated max-message-size (262144 in Chromium), so
/// endpoints with chunking enabled split binary messages over
/// 64 KiB into [0xF0, flags]-headed chunks and reassemble on
/// receipt. 0xF0 is an unknown grpc-dc frame type, so a peer
/// without chunking ignores chunks per the forward-compat
/// rule instead of misdecoding them.
pub const DC_CHUNK_MAGIC: u8 = 0xF0;
pub const DC_CHUNK_FINAL: u8 = 0x01;
pub const MAX_DC_CHUNK_PAYLOAD: usize = 65536;

pub fn split_dc_message(data: &[u8]) -> Vec<Vec<u8>> {
    if data.len() <= MAX_DC_CHUNK_PAYLOAD {
        return vec![data.to_vec()];
    }
    let mut out = Vec::new();
    let mut off = 0;
    while off < data.len() {
        let n = MAX_DC_CHUNK_PAYLOAD.min(data.len() - off);
        let last = off + n >= data.len();
        let mut chunk = Vec::with_capacity(2 + n);
        chunk.push(DC_CHUNK_MAGIC);
        chunk.push(if last { DC_CHUNK_FINAL } else { 0 });
        chunk.extend_from_slice(&data[off..off + n]);
        out.push(chunk);
        off += n;
    }
    out
}

#[derive(Default)]
pub struct DcChunkReassembler {
    parts: Option<Vec<Vec<u8>>>,
}

impl DcChunkReassembler {
    /// Push one wire message; Some(whole) when a message is
    /// complete (non-chunk messages pass through untouched).
    pub fn push(&mut self, data: &[u8]) -> Option<Vec<u8>> {
        if self.parts.is_none() && (data.len() < 2 || data[0] != DC_CHUNK_MAGIC) {
            return Some(data.to_vec());
        }
        if data.len() < 2 || data[0] != DC_CHUNK_MAGIC {
            self.parts = None;
            return Some(data.to_vec());
        }
        let final_chunk = data[1] & DC_CHUNK_FINAL != 0;
        self.parts.get_or_insert_with(Vec::new).push(data[2..].to_vec());
        if !final_chunk {
            return None;
        }
        let parts = self.parts.take().unwrap_or_default();
        let total: usize = parts.iter().map(|p| p.len()).sum();
        let mut out = Vec::with_capacity(total);
        for part in parts {
            out.extend_from_slice(&part);
        }
        Some(out)
    }
}

enum Cmd {
    Open {
        params: ChannelParams,
        respond: Sender<ChannelHandle>,
    },
    SendData {
        stream: u16,
        text: bool,
        data: Vec<u8>,
    },
    SetChunking {
        enabled: bool,
    },
    CloseChannel {
        stream: u16,
    },
    Shutdown,
}

#[derive(Clone)]
pub struct ChannelHandle {
    pub stream: u16,
    pub label: String,
    pub protocol: String,
    cmd_tx: Sender<Cmd>,
}

impl ChannelHandle {
    pub fn send_binary(&self, data: &[u8]) -> io::Result<()> {
        self.cmd_tx
            .send(Cmd::SendData { stream: self.stream, text: false, data: data.to_vec() })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "endpoint closed"))
    }

    pub fn send_text(&self, text: &str) -> io::Result<()> {
        self.cmd_tx
            .send(Cmd::SendData { stream: self.stream, text: true, data: text.as_bytes().to_vec() })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "endpoint closed"))
    }

    pub fn close(&self) {
        let _ = self.cmd_tx.send(Cmd::CloseChannel { stream: self.stream });
    }
}

pub struct DcEndpoint {
    cmd_tx: Sender<Cmd>,
    event_rx: std::sync::Mutex<Receiver<EndpointEvent>>,
    alive: Arc<AtomicBool>,
    dtls_session: std::sync::Mutex<Option<crate::dtls::DtlsSession>>,
}

impl DcEndpoint {
    /// Take ownership of an established DTLS connection and run the
    /// SCTP/DCEP stack on a new thread.
    pub fn spawn<I: DtlsIo + Send + 'static>(dtls: Dtls<I>, role: Role, local_port: u16) -> Self {
        Self::spawn_with_alive_flag(dtls, role, local_port, Arc::new(AtomicBool::new(true)))
    }

    /// Like spawn, but clears `alive` when the endpoint thread
    /// exits (shutdown, transport failure, or drop). The flag is
    /// created by the caller (starting true) so companion
    /// threads that must run before the endpoint exists — e.g.
    /// the peer's packet demultiplexer — can stop with it
    /// instead of answering traffic for a dead endpoint.
    pub fn spawn_with_alive_flag<I: DtlsIo + Send + 'static>(
        dtls: Dtls<I>,
        role: Role,
        local_port: u16,
        alive: Arc<AtomicBool>,
    ) -> Self {
        let (cmd_tx, cmd_rx) = channel::<Cmd>();
        let (event_tx, event_rx) = channel::<EndpointEvent>();
        let thread_cmd_tx = cmd_tx.clone();
        let thread_alive = alive.clone();
        std::thread::spawn(move || {
            run_loop(dtls, role, local_port, cmd_rx, thread_cmd_tx, event_tx);
            thread_alive.store(false, Ordering::SeqCst);
        });
        Self {
            cmd_tx,
            event_rx: std::sync::Mutex::new(event_rx),
            alive,
            dtls_session: std::sync::Mutex::new(None),
        }
    }

    /// Attach DTLS resumption state captured during the
    /// handshake (set by `Peer` before returning the endpoint).
    pub fn set_dtls_session(&self, session: Option<crate::dtls::DtlsSession>) {
        *self.dtls_session.lock().unwrap() = session;
    }

    /// Take the DTLS resumption state captured during the
    /// handshake, if the server issued a session ticket. Persist
    /// it and pass it back as `PeerConfig::resume_session` on the
    /// next connect for an abbreviated handshake.
    pub fn take_dtls_session(&self) -> Option<crate::dtls::DtlsSession> {
        self.dtls_session.lock().unwrap().take()
    }

    /// True while the endpoint thread is running.
    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    pub fn open_channel(&self, params: ChannelParams) -> io::Result<ChannelHandle> {
        let (tx, rx) = channel();
        self.cmd_tx
            .send(Cmd::Open { params, respond: tx })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "endpoint closed"))?;
        rx.recv()
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "endpoint closed"))
    }

    pub fn recv_event(&self) -> Option<EndpointEvent> {
        self.event_rx.lock().unwrap().recv().ok()
    }

    pub fn recv_event_timeout(&self, timeout: Duration) -> Option<EndpointEvent> {
        self.event_rx.lock().unwrap().recv_timeout(timeout).ok()
    }

    pub fn shutdown(&self) {
        let _ = self.cmd_tx.send(Cmd::Shutdown);
    }

    /// A cloneable handle that shuts this endpoint down (used by
    /// the ICE consent thread, which outlives the connect call).
    pub fn shutdown_handle(&self) -> ShutdownHandle {
        ShutdownHandle { cmd_tx: self.cmd_tx.clone() }
    }

    /// Enable DC message chunking for large binary messages
    /// (see split_dc_message). Enable on both ends of a link
    /// that must carry messages over the peer's RTCDataChannel
    /// max-message-size (browsers: 256 KiB).
    pub fn set_chunk_messages(&self, enabled: bool) {
        let _ = self.cmd_tx.send(Cmd::SetChunking { enabled });
    }
}

#[derive(Clone)]
pub struct ShutdownHandle {
    cmd_tx: Sender<Cmd>,
}

impl ShutdownHandle {
    pub fn shutdown(&self) {
        let _ = self.cmd_tx.send(Cmd::Shutdown);
    }
}

struct ChannelState {
    params: ChannelParams,
    #[allow(dead_code)]
    acked: bool,
}

fn run_loop<I: DtlsIo>(
    mut dtls: Dtls<I>,
    role: Role,
    local_port: u16,
    cmd_rx: Receiver<Cmd>,
    cmd_tx: Sender<Cmd>,
    event_tx: Sender<EndpointEvent>,
) {
    let mut assoc = match role {
        Role::Client => Association::new_client(local_port, crate::sctp::SCTP_PORT),
        Role::Server => Association::new_server(local_port, crate::sctp::SCTP_PORT),
    };
    let start = Instant::now();
    let now = |start: Instant| start.elapsed().as_millis() as u64;

    // Initiate the SCTP handshake if we are the DTLS client (the side
    // that also opens even-numbered channels). The server side answers.
    if role == Role::Client {
        let init = assoc.connect(now(start));
        let _ = dtls.send_app(&init);
    }
    let mut next_stream: u16 = match role {
        Role::Client => 0, // DTLS client: even streams (RFC 8832)
        Role::Server => 1, // DTLS server: odd streams
    };
    let mut channels: HashMap<u16, ChannelState> = HashMap::new();
    let mut sctp_connected = false;
    let mut chunking = false;
    let mut reassemblers: HashMap<u16, DcChunkReassembler> = HashMap::new();

    loop {
        // 1) Inbound SCTP packets from DTLS. The pump is a single
        // thread (DTLS send/recv share one state), so application
        // commands and SCTP timers wait out the current receive
        // slice; 1 ms bounds that latency to ~1 ms per side while
        // idle wakeups stay negligible (1k/s per endpoint). This
        // slice dominated loopback RTT at 5 ms (bench-mux: 19 ms
        // mean before, ~2 ms after).
        // Drain every queued inbound packet before moving on, so
        // bursts do not serialize one packet per pump iteration.
        let mut first = true;
        loop {
            let timeout = if first {
                Duration::from_millis(1)
            } else {
                Duration::ZERO
            };
            first = false;
            match dtls.recv_app_timeout(timeout) {
                Ok(Some(packet)) => {
                    let (out, events) = assoc.handle_packet(&packet, now(start));
                    for p in out {
                        let _ = dtls.send_app(&p);
                    }
                    for event in events {
                        handle_sctp_event(
                            event,
                            &mut assoc,
                            &mut dtls,
                            &mut channels,
                            &cmd_tx,
                            &event_tx,
                            &mut sctp_connected,
                            chunking,
                            &mut reassemblers,
                            now(start),
                        );
                    }
                }
                Ok(None) => break,
                Err(_) => return,
            }
        }

        // 2) SCTP timers.
        let (out, events) = assoc.tick(now(start));
        for p in out {
            let _ = dtls.send_app(&p);
        }
        for event in events {
            handle_sctp_event(
                event,
                &mut assoc,
                &mut dtls,
                &mut channels,
                &cmd_tx,
                &event_tx,
                &mut sctp_connected,
                chunking,
                &mut reassemblers,
                now(start),
            );
        }

        // 3) Application commands (non-blocking drain).
        loop {
            match cmd_rx.try_recv() {
                Ok(Cmd::Open { params, respond }) => {
                    let stream = next_stream;
                    next_stream = next_stream.wrapping_add(2);
                    let handle = ChannelHandle {
                        stream,
                        label: params.label.clone(),
                        protocol: params.protocol.clone(),
                        cmd_tx: cmd_tx.clone(),
                    };
                    let open = encode_open(&params);
                    channels.insert(stream, ChannelState { params, acked: false });
                    for p in assoc.send_data(stream, PPID_DCEP, &open, Default::default(), now(start)) {
                        let _ = dtls.send_app(&p);
                    }
                    let _ = respond.send(handle);
                }
                Ok(Cmd::SetChunking { enabled }) => {
                    chunking = enabled;
                }
                Ok(Cmd::SendData { stream, text, data }) => {
                    if let Some(state) = channels.get(&stream) {
                        let opts = state.params.send_options();
                        if chunking && !text && data.len() > MAX_DC_CHUNK_PAYLOAD {
                            for chunk in split_dc_message(&data) {
                                for p in assoc.send_data(stream, PPID_BINARY, &chunk, opts, now(start)) {
                                    let _ = dtls.send_app(&p);
                                }
                            }
                            continue;
                        }
                        let ppid = match (text, data.is_empty()) {
                            (true, false) => PPID_STRING,
                            (true, true) => PPID_STRING_EMPTY,
                            (false, false) => PPID_BINARY,
                            (false, true) => PPID_BINARY_EMPTY,
                        };
                        for p in assoc.send_data(stream, ppid, &data, opts, now(start)) {
                            let _ = dtls.send_app(&p);
                        }
                    }
                }
                Ok(Cmd::CloseChannel { stream }) => {
                    // Signal an SCTP stream reset; the channel
                    // is removed and ChannelClosed emitted when
                    // the reset completes.
                    for p in assoc.close_stream(stream) {
                        let _ = dtls.send_app(&p);
                    }
                }
                Ok(Cmd::Shutdown) => {
                    for p in assoc.close(now(start)) {
                        let _ = dtls.send_app(&p);
                    }
                    return;
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => return,
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn handle_sctp_event<I: DtlsIo>(
    event: SctpEvent,
    assoc: &mut Association,
    dtls: &mut Dtls<I>,
    channels: &mut HashMap<u16, ChannelState>,
    cmd_tx: &Sender<Cmd>,
    event_tx: &Sender<EndpointEvent>,
    sctp_connected: &mut bool,
    chunking: bool,
    reassemblers: &mut HashMap<u16, DcChunkReassembler>,
    now_ms: u64,
) {
    match event {
        SctpEvent::Connected => {
            *sctp_connected = true;
        }
        SctpEvent::Data { stream, ppid, payload } => match ppid {
            PPID_DCEP => {
                if is_ack(&payload) {
                    if let Some(state) = channels.get_mut(&stream) {
                        state.acked = true;
                    }
                } else if let Some(params) = decode_open(&payload) {
                    let handle = ChannelHandle {
                        stream,
                        label: params.label.clone(),
                        protocol: params.protocol.clone(),
                        cmd_tx: cmd_tx.clone(),
                    };
                    channels.insert(stream, ChannelState { params, acked: true });
                    for p in assoc.send_data(stream, PPID_DCEP, &encode_ack(), Default::default(), now_ms) {
                        let _ = dtls.send_app(&p);
                    }
                    let _ = event_tx.send(EndpointEvent::ChannelOpened { channel: handle });
                }
            }
            PPID_STRING | PPID_STRING_EMPTY => {
                let _ = event_tx.send(EndpointEvent::Message { stream, text: true, data: payload });
            }
            PPID_BINARY | PPID_BINARY_EMPTY => {
                if chunking {
                    let whole = reassemblers.entry(stream).or_default().push(&payload);
                    if let Some(data) = whole {
                        let _ = event_tx.send(EndpointEvent::Message { stream, text: false, data });
                    }
                } else {
                    let _ = event_tx.send(EndpointEvent::Message { stream, text: false, data: payload });
                }
            }
            _ => {}
        },
        SctpEvent::StreamReset { stream } => {
            channels.remove(&stream);
            reassemblers.remove(&stream);
            let _ = event_tx.send(EndpointEvent::ChannelClosed { stream });
        }
        SctpEvent::Closed => {}
    }
}
