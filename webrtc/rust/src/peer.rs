//! Full WebRTC peer: UDP socket + ICE (host candidates) + DTLS + SCTP.
//!
//! Lifecycle mirrors RTCPeerConnection for the datachannel-only case:
//! `create_offer` / `handle_offer` (returns the answer) /
//! `handle_answer`, then `connect` runs ICE checks, performs the DTLS
//! handshake over the nominated pair, and returns a `DcEndpoint`.

use crate::dtls::{Dtls, DtlsConfig, DtlsIo, Role};
use crate::endpoint::DcEndpoint;
use crate::ice::{Candidate, IceAgent};
use crate::sdp::{generate, parse, SessionDescription};
use crate::x509::Certificate;
use std::collections::VecDeque;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn bad<S: AsRef<str>>(msg: S) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.as_ref().to_string())
}

pub struct PeerConfig {
    /// Local IP addresses to advertise as host candidates. Empty means:
    /// 127.0.0.1 plus the default-route address (discovered without
    /// sending any traffic).
    pub local_ips: Vec<IpAddr>,
    pub require_peer_certificate: bool,
    /// STUN servers ("host:port") queried, in order, for
    /// server-reflexive candidates before an offer/answer is made.
    pub stun_servers: Vec<String>,
    /// TURN servers tried, in order, for a relay allocation before
    /// an offer/answer is made; the first success adds a relay
    /// candidate and relays the nominated pair's traffic.
    pub turn_servers: Vec<crate::turn::TurnServerConfig>,
}

impl Default for PeerConfig {
    fn default() -> Self {
        Self {
            local_ips: Vec::new(),
            require_peer_certificate: true,
            stun_servers: Vec::new(),
            turn_servers: Vec::new(),
        }
    }
}

fn default_route_ip() -> Option<IpAddr> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:53").ok()?;
    socket.local_addr().ok().map(|a| a.ip())
}

pub struct Peer {
    socket: UdpSocket,
    agent: IceAgent,
    certificate: Certificate,
    remote: Option<SessionDescription>,
    dtls_role: Role,
    config: PeerConfig,
    gathered: bool,
    turn: Option<crate::turn::TurnClient>,
    on_local_candidate: Option<Box<dyn FnMut(&str) + Send>>,
    consent_interval: Option<Duration>,
    consent_expiry: Duration,
    on_consent_failure: Option<Box<dyn FnMut() + Send>>,
}

struct IceDtlsIo {
    socket: UdpSocket,
    peer: SocketAddr,
    inbox: Receiver<Vec<u8>>,
    turn: Option<crate::turn::TurnClient>,
    relay_active: bool,
}

impl DtlsIo for IceDtlsIo {
    fn send_packet(&mut self, packet: &[u8]) -> io::Result<()> {
        crate::turn::send_pair(&self.socket, self.turn.as_ref(), self.relay_active, packet, self.peer)
    }

    fn recv_packet(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        match self.inbox.recv_timeout(timeout) {
            Ok(packet) => Ok(Some(packet)),
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => Ok(None),
        }
    }
}

impl Peer {
    pub fn new(config: PeerConfig) -> io::Result<Self> {
        // A dual-stack IPv6 socket serves IPv6 candidates when
        // any local or STUN/TURN server address is IPv6 (IPv4
        // senders arrive mapped and are normalized on receive);
        // otherwise keep the plain IPv4 socket.
        fn text_is_v6(text: &str) -> bool {
            use std::net::ToSocketAddrs;
            text.to_socket_addrs()
                .map(|mut it| it.any(|a| a.ip().is_ipv6()))
                .unwrap_or(false)
        }
        let wants_v6 = config.local_ips.iter().any(|ip| ip.is_ipv6())
            || config.stun_servers.iter().any(|s| text_is_v6(s))
            || config.turn_servers.iter().any(|c| text_is_v6(&c.address));
        let socket = if wants_v6 {
            UdpSocket::bind((Ipv6Addr::UNSPECIFIED, 0))?
        } else {
            UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?
        };
        let port = socket.local_addr()?.port();
        let mut ips: Vec<IpAddr> = if config.local_ips.is_empty() {
            let mut v = vec![IpAddr::V4(Ipv4Addr::LOCALHOST)];
            if let Some(ip) = default_route_ip() {
                if !v.contains(&ip) {
                    v.push(ip);
                }
            }
            v
        } else {
            config.local_ips.clone()
        };
        ips.dedup();
        let agent = IceAgent::new(true);
        Ok(Self {
            socket,
            agent,
            certificate: Certificate::generate_self_signed("dc-webrtc"),
            remote: None,
            dtls_role: Role::Server,
            config,
            gathered: false,
            turn: None,
            on_local_candidate: None,
            consent_interval: Some(Duration::from_secs(5)),
            consent_expiry: Duration::from_secs(30),
            on_consent_failure: None,
        })
        .map(|mut peer| {
            peer.agent.local_candidates = ips
                .iter()
                .enumerate()
                .map(|(i, ip)| Candidate::host(SocketAddr::new(*ip, port), &format!("{}", i + 1)))
                .collect();
            peer
        })
    }

    /// Query one STUN server ("host:port") for a server-reflexive
    /// candidate (RFC 8445 section 5.1.2). The request rides the
    /// peer's own socket so the mapping is the one ICE checks will
    /// use. Returns Ok(true) when a candidate was added; unreachable
    /// servers are reported as errors by this explicit form (the
    /// PeerConfig-driven gathering ignores them).
    pub fn gather_srflx(&mut self, server: &str, timeout: Duration) -> io::Result<bool> {
        use std::net::ToSocketAddrs;
        let server_addr = server
            .to_socket_addrs()?
            .next()
            .ok_or_else(|| bad("stun server does not resolve"))?;
        let request = crate::stun::Message::new(crate::proto_gen::stun_msg::BINDING_REQUEST);
        let tid = request.transaction_id;
        self.socket.send_to(&request.encode(None), server_addr)?;
        let deadline = std::time::Instant::now() + timeout;
        self.socket.set_read_timeout(Some(Duration::from_millis(50)))?;
        let mut buf = vec![0u8; 2048];
        let mut mapped = None;
        while std::time::Instant::now() < deadline {
            match self.socket.recv_from(&mut buf) {
                Ok((n, _src)) => {
                    if let Some(msg) = crate::stun::Message::decode(&buf[..n]) {
                        if msg.msg_type == crate::proto_gen::stun_msg::BINDING_SUCCESS
                            && msg.transaction_id == tid
                        {
                            mapped = mapped_from_success(&msg);
                            break;
                        }
                    }
                }
                Err(e)
                    if e.kind() == io::ErrorKind::WouldBlock
                        || e.kind() == io::ErrorKind::TimedOut => {}
                Err(e) => {
                    let _ = self.socket.set_read_timeout(None);
                    return Err(e);
                }
            }
        }
        let _ = self.socket.set_read_timeout(None);
        let mapped = match mapped {
            Some(m) => m,
            None => return Ok(false),
        };
        if self.agent.local_candidates.iter().any(|c| c.addr == mapped) {
            return Ok(false); // already have this address (flat network)
        }
        let base = self.agent.local_candidates[0].clone();
        let foundation = format!("{}", self.agent.local_candidates.len() + 1);
        let cand = crate::ice::Candidate::srflx(mapped, &base, &foundation);
        self.agent.local_candidates.push(cand.clone());
        self.emit_local_candidate(&cand);
        Ok(true)
    }

    /// Run the TURN Allocate handshake against one server and add
    /// the relayed candidate (RFC 5766). Returns Ok(true) when a
    /// candidate was added. The PeerConfig-driven gathering ignores
    /// failures (host/srflx candidates still apply).
    pub fn allocate_turn(
        &mut self,
        cfg: &crate::turn::TurnServerConfig,
        timeout: Duration,
    ) -> io::Result<bool> {
        let client = crate::turn::allocate_turn(&self.socket, cfg, timeout)?;
        let relayed = client
            .relayed
            .ok_or_else(|| bad("turn: no relayed address"))?;
        self.turn = Some(client);
        if self.agent.local_candidates.iter().any(|c| c.addr == relayed) {
            return Ok(false); // already have this address (flat network)
        }
        let base = self.agent.local_candidates[0].clone();
        let foundation = format!("{}", self.agent.local_candidates.len() + 1);
        let cand = Candidate::relay(relayed, &base, &foundation);
        self.agent.local_candidates.push(cand.clone());
        self.emit_local_candidate(&cand);
        Ok(true)
    }

    fn emit_local_candidate(&mut self, cand: &Candidate) {
        if let Some(cb) = &mut self.on_local_candidate {
            cb(&cand.to_sdp());
        }
    }

    /// Register the trickle callback for local candidates and
    /// immediately replay the candidates gathered so far;
    /// candidates gathered later (srflx/TURN at offer/answer time,
    /// or explicit gather calls) fire as they are added.
    pub fn set_on_local_candidate(&mut self, cb: impl FnMut(&str) + Send + 'static) {
        self.on_local_candidate = Some(Box::new(cb));
        let lines = self.local_candidate_lines();
        if let Some(cb) = &mut self.on_local_candidate {
            for line in &lines {
                cb(line);
            }
        }
    }

    /// Local candidates as SDP lines ("a=candidate:...") for
    /// trickle signaling.
    pub fn local_candidate_lines(&self) -> Vec<String> {
        self.agent.local_candidates.iter().map(|c| c.to_sdp()).collect()
    }

    /// Trickle one remote candidate in after the remote
    /// description was applied (RFC 8445 trickle ICE). Accepts a
    /// full SDP line ("a=candidate:..."), the bare candidate value
    /// ("candidate:...", as browsers hand to addIceCandidate), an
    /// end-of-candidates line, or an empty string; the latter two
    /// are accepted no-ops. Returns true when a new candidate was
    /// added (duplicates and malformed lines return false). For
    /// candidates arriving while connect() runs, use
    /// connect_trickled's channel instead (connect consumes the
    /// peer).
    pub fn add_remote_candidate(&mut self, line: &str) -> bool {
        match parse_trickle_line(line) {
            Some(cand) => self.agent.add_remote_candidate(cand),
            None => false,
        }
    }

    /// Configure ICE consent freshness (RFC 7675): after
    /// nomination, a Binding check is sent on the nominated pair
    /// every `interval` (None disables; default 5 s). If no
    /// response arrives within `expiry` (default 30 s), the
    /// endpoint is shut down and `on_failure` fires once. Call
    /// before connect.
    pub fn set_consent(
        &mut self,
        interval: Option<Duration>,
        expiry: Duration,
        on_failure: impl FnMut() + Send + 'static,
    ) {
        self.consent_interval = interval;
        self.consent_expiry = expiry;
        self.on_consent_failure = Some(Box::new(on_failure));
    }

    /// PeerConfig-driven gathering, run once before an offer/answer
    /// is produced; failures are ignored (host candidates apply).
    fn gather_from_config(&mut self) {
        if self.gathered {
            return;
        }
        self.gathered = true;
        let servers = self.config.stun_servers.clone();
        for server in &servers {
            let _ = self.gather_srflx(server, Duration::from_millis(1200));
        }
        let turn_servers = self.config.turn_servers.clone();
        for cfg in &turn_servers {
            if self.allocate_turn(cfg, Duration::from_secs(2)).is_ok() {
                break; // one relay candidate is enough
            }
        }
    }

    fn local_description(&self, setup: &str) -> SessionDescription {
        SessionDescription {
            ufrag: self.agent.local_ufrag.clone(),
            pwd: self.agent.local_pwd.clone(),
            fingerprint: self.certificate.fingerprint(),
            setup: setup.to_string(),
            candidates: self.agent.local_candidates.clone(),
            sctp_port: crate::sctp::SCTP_PORT,
        }
    }

    pub fn create_offer(&mut self) -> String {
        self.gather_from_config();
        self.agent.controlling = true;
        // actpass: we can take either DTLS role; the answer decides.
        self.dtls_role = Role::Server;
        generate(&self.local_description("actpass"), true)
    }

    pub fn handle_offer(&mut self, offer_sdp: &str) -> io::Result<String> {
        self.gather_from_config();
        let remote = parse(offer_sdp).map_err(bad)?;
        self.apply_remote(remote);
        self.agent.controlling = false;
        // Answer as DTLS client (setup=active), the common WebRTC choice.
        self.dtls_role = Role::Client;
        Ok(generate(&self.local_description("active"), false))
    }

    pub fn handle_answer(&mut self, answer_sdp: &str) -> io::Result<()> {
        let remote = parse(answer_sdp).map_err(bad)?;
        // Answer setup=active → the answerer is the DTLS client, so we
        // are the server; setup=passive → we are the client.
        self.dtls_role = if remote.setup == "active" {
            Role::Server
        } else {
            Role::Client
        };
        self.apply_remote(remote);
        Ok(())
    }

    fn apply_remote(&mut self, remote: SessionDescription) {
        self.agent.set_remote(&remote.ufrag, &remote.pwd, remote.candidates.clone());
        self.remote = Some(remote);
    }

    /// Run ICE connectivity checks, then the DTLS handshake over the
    /// nominated pair, and spawn the datachannel endpoint.
    pub fn connect(self) -> io::Result<DcEndpoint> {
        self.connect_inner(None)
    }

    /// connect() with trickle ICE: candidate lines arriving on the
    /// channel while ICE runs are added to the agent (empty and
    /// end-of-candidates lines are ignored). Use when the remote
    /// description carried few or no candidates. Note TURN
    /// permissions are created from the candidates known when
    /// connect starts; candidates trickled later reach the peer
    /// directly or peer-reflexively, not through the relay.
    pub fn connect_trickled(self, trickle: Receiver<String>) -> io::Result<DcEndpoint> {
        self.connect_inner(Some(trickle))
    }

    fn connect_inner(self, trickle: Option<Receiver<String>>) -> io::Result<DcEndpoint> {
        let Peer {
            socket,
            mut agent,
            certificate,
            remote,
            dtls_role,
            config,
            mut turn,
            consent_interval,
            consent_expiry,
            on_consent_failure,
            ..
        } = self;
        let remote_desc = remote.ok_or_else(|| bad("no remote description"))?;
        // Resolve mDNS ".local" remote candidates (browsers
        // obfuscate host addresses). Peer-reflexive learning in
        // the ICE agent covers the case where multicast resolution
        // is unavailable (mirrors the Go peer's connect).
        for candidate in &mut agent.remote_candidates {
            if let Some(name) = &candidate.mdns_name {
                if let Some(ip) = crate::mdns::resolve_ipv4(name) {
                    candidate.addr = SocketAddr::new(IpAddr::V4(ip), candidate.addr.port());
                }
            }
        }
        // Relay the session when an allocation exists: permissions
        // for every remote candidate first, then all pair traffic
        // goes through the allocation (wrapped by turn::send_pair).
        let mut relay_active = false;
        if let Some(client) = &mut turn {
            let addrs: Vec<SocketAddr> = agent
                .remote_candidates
                .iter()
                .map(|c| c.addr)
                .filter(|a| !a.ip().is_unspecified())
                .collect();
            crate::turn::create_permissions(&socket, client, &addrs, Duration::from_secs(2));
            crate::turn::bind_channels(&socket, client, &addrs, Duration::from_secs(2));
            // Keep the allocation, permissions, and bindings
            // alive for sessions outliving their first expiry.
            if let Ok(refresh_socket) = socket.try_clone() {
                crate::turn::spawn_refresher(refresh_socket, client.clone(), addrs);
            }
            relay_active = true;
        }
        let (dtls_tx, dtls_rx) = channel::<Vec<u8>>();
        let agent = Arc::new(Mutex::new(agent));
        let (selected, trickled_addrs) =
            run_ice(&socket, &agent, &dtls_tx, turn.as_ref(), relay_active, trickle.as_ref())?;
        // Candidates trickled in during ICE got send-only
        // permissions in the loop; now that socket reads are
        // free (demux thread not yet spawned), bind their
        // channels awaited-style and keep them refreshed.
        if let Some(client) = &mut turn {
            if !trickled_addrs.is_empty() {
                crate::turn::bind_channels(
                    &socket,
                    client,
                    &trickled_addrs,
                    Duration::from_secs(2),
                );
                if let Ok(refresh_socket) = socket.try_clone() {
                    crate::turn::spawn_refresher(
                        refresh_socket,
                        client.clone(),
                        trickled_addrs,
                    );
                }
            }
        }
        // Demultiplexing thread: keeps answering consent checks after
        // nomination and feeds DTLS packets to the handshake/endpoint.
        // It stops when the endpoint does (alive flag), so a shut-down
        // peer goes silent instead of answering checks forever.
        let alive = Arc::new(AtomicBool::new(true));
        let demux_socket = socket.try_clone()?;
        // The timeout is also the poll cadence for the TURN
        // stream inbox (TCP/TLS allocations), hence 25 ms.
        let _ = demux_socket.set_read_timeout(Some(Duration::from_millis(25)));
        let demux_agent = agent.clone();
        let demux_turn = turn.clone();
        let demux_alive = alive.clone();
        std::thread::spawn(move || loop {
            if !demux_alive.load(Ordering::SeqCst) {
                return;
            }
            // Collect this iteration's packets: framed messages
            // off a TCP/TLS TURN stream (attributed to the
            // server) plus at most one UDP datagram.
            let mut packets: Vec<(Vec<u8>, SocketAddr)> = Vec::new();
            if let Some(client) = demux_turn.as_ref() {
                for msg in client.drain_inbox() {
                    packets.push((msg, client.server));
                }
            }
            let mut buf = vec![0u8; 65536];
            match demux_socket.recv_from(&mut buf) {
                Ok((n, src)) => {
                    buf.truncate(n);
                    if !buf.is_empty() {
                        packets.push((buf, crate::stun::normalize_addr(src)));
                    }
                }
                Err(e)
                    if e.kind() == io::ErrorKind::WouldBlock
                        || e.kind() == io::ErrorKind::TimedOut => {}
                Err(_) => return,
            }
            for (buf, src) in packets {
                // Relayed traffic arrives as TURN Data
                // indications; unwrap to (payload, peer).
                let (buf, src) = match crate::turn::unwrap_incoming(demux_turn.as_ref(), &buf, src) {
                    Some((data, peer)) => (data, peer),
                    None => continue,
                };
                if buf.is_empty() {
                    continue;
                }
                if buf[0] < 4 {
                    let (responses, _) = {
                        let mut agent = demux_agent.lock().unwrap();
                        agent.handle_stun(&buf, src)
                    };
                    for (bytes, dest) in responses {
                        let _ = crate::turn::send_pair(
                            &demux_socket,
                            demux_turn.as_ref(),
                            relay_active,
                            &bytes,
                            dest,
                        );
                    }
                } else if (20..64).contains(&buf[0]) {
                    if dtls_tx.send(buf).is_err() {
                        return;
                    }
                }
            }
        });

        let dtls_config = DtlsConfig {
            certificate,
            expected_peer_fingerprint: Some(remote_desc.fingerprint.clone()),
            require_peer_certificate: config.require_peer_certificate,
        };
        let consent_socket = socket.try_clone()?;
        let io = IceDtlsIo { socket, peer: selected, inbox: dtls_rx, turn: turn.clone(), relay_active };
        let dtls = match dtls_role {
            Role::Client => Dtls::connect(io, &dtls_config)?,
            Role::Server => Dtls::accept(io, &dtls_config)?,
        };
        let endpoint = DcEndpoint::spawn_with_alive_flag(dtls, dtls_role, crate::sctp::SCTP_PORT, alive.clone());
        // Consent freshness (RFC 7675): periodically re-check
        // the nominated pair; on expiry shut the endpoint down
        // and fire the failure callback once.
        if let Some(interval) = consent_interval {
            let consent_agent = agent.clone();
            let shutdown = endpoint.shutdown_handle();
            let mut on_failure = on_consent_failure;
            // The DTLS handshake just proved the pair; start the
            // consent clock from here, not from nomination.
            consent_agent.lock().unwrap().touch_consent();
            std::thread::spawn(move || loop {
                std::thread::sleep(interval);
                if !alive.load(Ordering::SeqCst) {
                    return; // endpoint shut down deliberately: not a failure
                }
                let check = consent_agent.lock().unwrap().consent_check();
                let had_check = check.is_some();
                if let Some((bytes, dest)) = check {
                    let _ = crate::turn::send_pair(
                        &consent_socket,
                        turn.as_ref(),
                        relay_active,
                        &bytes,
                        dest,
                    );
                }
                if consent_agent.lock().unwrap().consent_expired(consent_expiry) {
                    if let Some(cb) = &mut on_failure {
                        cb();
                    }
                    shutdown.shutdown();
                    return;
                }
                if !had_check {
                    return; // no nominated pair (torn down)
                }
            });
        }
        Ok(endpoint)
    }
}

/// Parse one trickled candidate line; None for empty,
/// end-of-candidates, and malformed lines (all accepted no-ops).
fn parse_trickle_line(line: &str) -> Option<Candidate> {
    let text = line.trim();
    if text.is_empty() || text.contains("end-of-candidates") {
        return None;
    }
    Candidate::from_sdp(text.strip_prefix("a=").unwrap_or(text))
}

/// Runs ICE checks to nomination. Also returns the peer
/// addresses trickled in mid-connect, so the caller can bind
/// TURN channels for them and keep their permissions refreshed.
fn run_ice(
    socket: &UdpSocket,
    agent: &Arc<Mutex<IceAgent>>,
    dtls_stash: &Sender<Vec<u8>>,
    turn: Option<&crate::turn::TurnClient>,
    relay_active: bool,
    trickle: Option<&Receiver<String>>,
) -> io::Result<(SocketAddr, Vec<SocketAddr>)> {
    socket.set_read_timeout(Some(Duration::from_millis(25)))?;
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut last_check = Instant::now() - Duration::from_millis(100);
    let mut trickled_addrs: Vec<SocketAddr> = Vec::new();
    loop {
        if let Some(selected) = agent.lock().unwrap().nominated {
            return Ok((selected, trickled_addrs));
        }
        // Trickle: fold in any candidates signaled since the
        // remote description (mDNS names resolved as at connect).
        if let Some(rx) = trickle {
            while let Ok(line) = rx.try_recv() {
                if let Some(mut cand) = parse_trickle_line(&line) {
                    if let Some(name) = &cand.mdns_name {
                        if let Some(ip) = crate::mdns::resolve_ipv4(name) {
                            cand.addr = SocketAddr::new(IpAddr::V4(ip), cand.addr.port());
                        }
                    }
                    let addr = cand.addr;
                    let added = agent.lock().unwrap().add_remote_candidate(cand);
                    // A trickled candidate also needs a TURN
                    // permission or the relay silently drops
                    // its traffic (channel binding is deferred
                    // to the caller; see turn::send_permission).
                    if added {
                        if let Some(client) = turn {
                            if !addr.ip().is_unspecified() && !trickled_addrs.contains(&addr) {
                                trickled_addrs.push(addr);
                                crate::turn::send_permission(socket, client, &addr);
                            }
                        }
                    }
                }
            }
        }
        if Instant::now() > deadline {
            return Err(bad("ICE nomination timed out"));
        }
        if last_check.elapsed() >= Duration::from_millis(50) {
            last_check = Instant::now();
            let checks = agent.lock().unwrap().due_checks();
            for (bytes, dest) in checks {
                let _ = crate::turn::send_pair(socket, turn, relay_active, &bytes, dest);
            }
        }
        // Collect this iteration's packets: framed messages off
        // a TCP/TLS TURN stream (already attributed to the
        // server) plus at most one UDP datagram.
        let mut packets: Vec<(Vec<u8>, SocketAddr)> = Vec::new();
        if let Some(client) = turn {
            for msg in client.drain_inbox() {
                packets.push((msg, client.server));
            }
        }
        let mut buf = vec![0u8; 65536];
        match socket.recv_from(&mut buf) {
            Ok((n, src)) => {
                buf.truncate(n);
                if !buf.is_empty() {
                    packets.push((buf, crate::stun::normalize_addr(src)));
                }
            }
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::TimedOut => {}
            Err(e) => return Err(e),
        }
        for (buf, src) in packets {
            // Relayed traffic arrives as TURN Data
            // indications; unwrap to (payload, peer).
            let (buf, src) = match crate::turn::unwrap_incoming(turn, &buf, src) {
                Some((data, peer)) => (data, peer),
                None => continue,
            };
            if buf.is_empty() {
                continue;
            }
            if buf[0] < 4 {
                let (responses, _) = agent.lock().unwrap().handle_stun(&buf, src);
                for (bytes, dest) in responses {
                    let _ = crate::turn::send_pair(socket, turn, relay_active, &bytes, dest);
                }
            } else if (20..64).contains(&buf[0]) {
                // Early DTLS (peer started before nomination finished
                // on our side): stash for the handshake.
                let _ = dtls_stash.send(buf);
            }
        }
    }
}

/// Parse a mapped address out of a Binding success: XOR-MAPPED-ADDRESS
/// preferred, plain MAPPED-ADDRESS as fallback.
fn mapped_from_success(msg: &crate::stun::Message) -> Option<std::net::SocketAddr> {
    if let Some(value) = msg.attr(crate::proto_gen::stun_attr::XOR_MAPPED_ADDRESS) {
        return crate::stun::decode_xor_mapped(value, &msg.transaction_id);
    }
    let value = msg.attr(crate::proto_gen::stun_attr::MAPPED_ADDRESS)?;
    if value.len() < 8 || value[1] != 1 {
        return None;
    }
    let port = u16::from_be_bytes(value[2..4].try_into().ok()?);
    let ip = std::net::Ipv4Addr::new(value[4], value[5], value[6], value[7]);
    Some(std::net::SocketAddr::from((ip, port)))
}
