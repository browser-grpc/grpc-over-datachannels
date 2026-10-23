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
                Ok(Cmd::SendData { stream, text, data }) => {
                    if let Some(state) = channels.get(&stream) {
                        let opts = state.params.send_options();
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
                let _ = event_tx.send(EndpointEvent::Message { stream, text: false, data: payload });
            }
            _ => {}
        },
        SctpEvent::StreamReset { stream } => {
            channels.remove(&stream);
            let _ = event_tx.send(EndpointEvent::ChannelClosed { stream });
        }
        SctpEvent::Closed => {}
    }
}
