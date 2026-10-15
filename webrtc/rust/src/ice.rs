//! ICE (RFC 8445) agent: connectivity checks with short-term
//! credentials, role-conflict repair by tie-breaker, and
//! nomination. Pure state machine — the peer owns the UDP socket
//! and feeds packets in. Remote candidates may arrive inline in
//! SDP or trickled afterwards (add_remote_candidate).

use crate::crypto::random_u64;
use crate::proto_gen::stun_attr;
use crate::stun::{
    binding_error, binding_success, candidate_priority, host_priority, pair_priority,
    random_password, random_ufrag, Message,
};
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub foundation: String,
    pub component: u16,
    pub priority: u32,
    pub addr: SocketAddr,
    /// Base (host) candidate address for server-reflexive candidates;
    /// None for host candidates.
    pub srflx_base: Option<SocketAddr>,
    /// Original mDNS ".local" name when the SDP address did not
    /// parse as an IP literal. `addr` then holds an unspecified-IP
    /// placeholder with the advertised port until the peer resolves
    /// the name (connect) or peer-reflexive learning rewrites it
    /// from the first integrity-valid check (handle_stun), mirroring
    /// ice.js / ice.go.
    pub mdns_name: Option<String>,
    /// True for TURN relayed candidates (srflx_base then holds the
    /// allocation's base address for the raddr/rport SDP fields).
    pub is_relay: bool,
}

impl Candidate {
    pub fn host(addr: SocketAddr, foundation: &str) -> Self {
        Self {
            foundation: foundation.to_string(),
            component: 1,
            priority: host_priority(1),
            addr,
            srflx_base: None,
            mdns_name: None,
            is_relay: false,
        }
    }

    /// Server-reflexive candidate learned from a STUN server
    /// (RFC 8445 section 5.1.2): `addr` is the mapped address, `base`
    /// the host candidate it was gathered from (same socket).
    pub fn srflx(addr: SocketAddr, base: &Candidate, foundation: &str) -> Self {
        Self {
            foundation: foundation.to_string(),
            component: 1,
            priority: candidate_priority(100, 1),
            addr,
            srflx_base: Some(base.addr),
            mdns_name: None,
            is_relay: false,
        }
    }

    /// Relayed candidate from a TURN allocation (RFC 5766; type
    /// preference 0: last resort, RFC 8445 section 5.1.1).
    pub fn relay(addr: SocketAddr, base: &Candidate, foundation: &str) -> Self {
        Self {
            foundation: foundation.to_string(),
            component: 1,
            priority: candidate_priority(0, 1),
            addr,
            srflx_base: Some(base.addr),
            mdns_name: None,
            is_relay: true,
        }
    }

    pub fn is_srflx(&self) -> bool {
        self.srflx_base.is_some()
    }

    pub fn to_sdp(&self) -> String {
        // Related address comes before "generation 0": some parsers
        // (Firefox's nICEr) stop scanning extensions at unknown
        // attributes and then reject srflx/relay candidates whose
        // raddr they never saw. Browsers emit this order too.
        let mut out = format!(
            "a=candidate:{} {} udp {} {} {} typ {}",
            self.foundation,
            self.component,
            self.priority,
            self.addr.ip(),
            self.addr.port(),
            if self.is_relay {
                "relay"
            } else if self.is_srflx() {
                "srflx"
            } else {
                "host"
            }
        );
        if let Some(base) = self.srflx_base {
            out += &format!(" raddr {} rport {}", base.ip(), base.port());
        }
        out += " generation 0";
        out
    }

    pub fn from_sdp(value: &str) -> Option<Self> {
        // candidate:<foundation> <component> udp <priority> <ip> <port> typ host ...
        let parts: Vec<&str> = value.split_whitespace().collect();
        if parts.len() < 8 || parts[6] != "typ" {
            return None;
        }
        // Browsers advertise mDNS "<uuid>.local" host candidates.
        // Keep unresolvable ones as unspecified-IP placeholders
        // (resolution happens at connect; peer-reflexive learning
        // is the fallback) instead of resolving here: resolution
        // can stall for seconds on multicast timeouts and dropping
        // the candidate loses the pair entirely (mirrors ice.js).
        let port: u16 = parts[5].parse().ok()?;
        // Parse the IP on its own (never "ip:port" text: IPv6
        // literals would need brackets and would fall into the
        // mDNS placeholder branch instead).
        let (addr, mdns_name) = match parts[4].parse::<IpAddr>() {
            Ok(ip) => (SocketAddr::new(crate::stun::normalize_ip(ip), port), None),
            Err(_) => (
                SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), port),
                Some(parts[4].to_string()),
            ),
        };
        // srflx and relay candidates carry "raddr <ip> rport <port>".
        let is_relay = parts[7] == "relay";
        let srflx_base = if parts[7] == "srflx" || is_relay {
            let mut raddr = None;
            let mut rport = None;
            let mut i = 8;
            while i + 1 < parts.len() {
                match parts[i] {
                    "raddr" => raddr = parts[i + 1].parse().ok(),
                    "rport" => rport = parts[i + 1].parse().ok(),
                    _ => {}
                }
                i += 2;
            }
            match (raddr, rport) {
                (Some(ip), Some(port)) => Some(SocketAddr::new(ip, port)),
                _ => Some(addr),
            }
        } else {
            None
        };
        Some(Self {
            foundation: parts[0].trim_start_matches("candidate:").to_string(),
            component: parts[1].parse().ok()?,
            priority: parts[3].parse().ok()?,
            addr,
            srflx_base,
            mdns_name,
            is_relay,
        })
    }
}

pub enum IceEvent {
    PairValid { remote: SocketAddr },
    Nominated { remote: SocketAddr },
}

pub struct IceAgent {
    pub local_ufrag: String,
    pub local_pwd: String,
    pub remote_ufrag: String,
    pub remote_pwd: String,
    pub controlling: bool,
    pub tie_breaker: u64,
    pub local_candidates: Vec<Candidate>,
    pub remote_candidates: Vec<Candidate>,
    outstanding: HashMap<[u8; 12], (SocketAddr, bool)>, // tid -> (remote, nominate?)
    valid: HashSet<SocketAddr>,
    pub nominated: Option<SocketAddr>,
    nominating_sent_to: HashSet<SocketAddr>,
    last_consent: Option<std::time::Instant>,
}

impl IceAgent {
    pub fn new(controlling: bool) -> Self {
        Self {
            local_ufrag: random_ufrag(),
            local_pwd: random_password(),
            remote_ufrag: String::new(),
            remote_pwd: String::new(),
            controlling,
            tie_breaker: random_u64(),
            local_candidates: Vec::new(),
            remote_candidates: Vec::new(),
            outstanding: HashMap::new(),
            valid: HashSet::new(),
            nominated: None,
            nominating_sent_to: HashSet::new(),
            last_consent: None,
        }
    }

    pub fn set_remote(&mut self, ufrag: &str, pwd: &str, candidates: Vec<Candidate>) {
        self.remote_ufrag = ufrag.to_string();
        self.remote_pwd = pwd.to_string();
        self.remote_candidates = candidates;
    }

    /// Trickle one remote candidate in after the remote
    /// description (RFC 8445 section 4.1.1). Returns false when
    /// the candidate is already known (same address) so duplicate
    /// trickle is a no-op.
    pub fn add_remote_candidate(&mut self, cand: Candidate) -> bool {
        if self.remote_candidates.iter().any(|c| c.addr == cand.addr) {
            return false;
        }
        self.remote_candidates.push(cand);
        true
    }

    fn local_priority(&self) -> u32 {
        self.local_candidates.first().map(|c| c.priority).unwrap_or_else(|| host_priority(1))
    }

    /// Build a connectivity-check Binding request for one remote
    /// candidate. When `nominate`, includes USE-CANDIDATE (controlling).
    pub fn build_check(&mut self, remote: &Candidate, nominate: bool) -> (Vec<u8>, SocketAddr) {
        let mut msg = Message::new(crate::proto_gen::stun_msg::BINDING_REQUEST);
        msg.attrs.push((
            stun_attr::USERNAME,
            format!("{}:{}", self.remote_ufrag, self.local_ufrag).into_bytes(),
        ));
        msg.attrs
            .push((stun_attr::PRIORITY, self.local_priority().to_be_bytes().to_vec()));
        if self.controlling {
            msg.attrs
                .push((stun_attr::ICE_CONTROLLING, self.tie_breaker.to_be_bytes().to_vec()));
        } else {
            msg.attrs
                .push((stun_attr::ICE_CONTROLLED, self.tie_breaker.to_be_bytes().to_vec()));
        }
        if nominate && self.controlling {
            msg.attrs.push((stun_attr::USE_CANDIDATE, Vec::new()));
        }
        let bytes = msg.encode(Some(self.remote_pwd.as_bytes()));
        self.outstanding.insert(msg.transaction_id, (remote.addr, nominate));
        (bytes, remote.addr)
    }

    /// All checks due now: regular checks for every remote candidate, and
    /// (when controlling and some pair is already valid) a nominating
    /// check for the best valid pair.
    pub fn due_checks(&mut self) -> Vec<(Vec<u8>, SocketAddr)> {
        let mut out = Vec::new();
        if self.nominated.is_some() {
            return out;
        }
        let remotes = self.remote_candidates.clone();
        for remote in &remotes {
            // Unresolved mDNS placeholders cannot be addressed
            // until resolution or peer-reflexive rewriting.
            if remote.addr.ip().is_unspecified() {
                continue;
            }
            out.push(self.build_check(remote, false));
        }
        if self.controlling {
            if let Some(best) = self.best_valid_pair() {
                if !self.nominating_sent_to.contains(&best) {
                    self.nominating_sent_to.insert(best);
                    let candidate = self
                        .remote_candidates
                        .iter()
                        .find(|c| c.addr == best)
                        .cloned()
                        .unwrap_or_else(|| Candidate::host(best, "peer-reflexive"));
                    out.push(self.build_check(&candidate, true));
                }
            }
        }
        out
    }

    /// One consent-freshness Binding request for the nominated
    /// pair (RFC 8445 section 10 / RFC 7675); None before
    /// nomination.
    pub fn consent_check(&mut self) -> Option<(Vec<u8>, SocketAddr)> {
        let nominated = self.nominated?;
        let candidate = self
            .remote_candidates
            .iter()
            .find(|c| c.addr == nominated)
            .cloned()
            .unwrap_or_else(|| Candidate::host(nominated, "peer-reflexive"));
        Some(self.build_check(&candidate, false))
    }

    /// Mark consent as freshly confirmed (e.g. the DTLS
    /// handshake just completed over this pair).
    pub fn touch_consent(&mut self) {
        if self.nominated.is_some() {
            self.last_consent = Some(std::time::Instant::now());
        }
    }

    /// Whether consent for the nominated pair has lapsed (no
    /// Binding success for it within `expiry`).
    pub fn consent_expired(&self, expiry: std::time::Duration) -> bool {
        match (self.nominated, self.last_consent) {
            (Some(_), Some(last)) => last.elapsed() > expiry,
            _ => false,
        }
    }

    fn best_valid_pair(&self) -> Option<SocketAddr> {
        // Highest pair priority wins; with one local socket this reduces
        // to the valid remote with the highest candidate priority.
        self.remote_candidates
            .iter()
            .filter(|c| self.valid.contains(&c.addr))
            .max_by_key(|c| {
                pair_priority(
                    self.local_priority(),
                    c.priority,
                    self.controlling,
                )
            })
            .map(|c| c.addr)
            .or_else(|| self.valid.iter().next().copied())
    }

    /// Process one STUN packet. Returns (responses to send, events).
    pub fn handle_stun(
        &mut self,
        raw: &[u8],
        src: SocketAddr,
    ) -> (Vec<(Vec<u8>, SocketAddr)>, Vec<IceEvent>) {
        let mut responses = Vec::new();
        let mut events = Vec::new();
        let Some(msg) = Message::decode(raw) else {
            return (responses, events);
        };
        if msg.msg_type == crate::proto_gen::stun_msg::BINDING_REQUEST {
            // Incoming connectivity check.
            let Some(username) = msg.attr(stun_attr::USERNAME) else {
                return (responses, events);
            };
            let username = String::from_utf8_lossy(username).into_owned();
            let Some((target_ufrag, _)) = username.split_once(':') else {
                return (responses, events);
            };
            if target_ufrag != self.local_ufrag {
                return (responses, events);
            }
            if !msg.check_integrity(raw, self.local_pwd.as_bytes()) {
                responses.push((
                    binding_error(&msg, 401, "Unauthorized", None),
                    src,
                ));
                return (responses, events);
            }
            // Role conflict (RFC 8445 §7.3.1.1).
            if self.controlling {
                if let Some(tb) = msg.attr(stun_attr::ICE_CONTROLLING) {
                    let peer_tb = u64::from_be_bytes(tb.try_into().unwrap_or([0; 8]));
                    if peer_tb >= self.tie_breaker {
                        self.controlling = false; // repair: switch roles
                    } else {
                        responses.push((binding_error(&msg, 487, "Role Conflict", None), src));
                        return (responses, events);
                    }
                }
            } else if let Some(tb) = msg.attr(stun_attr::ICE_CONTROLLED) {
                let peer_tb = u64::from_be_bytes(tb.try_into().unwrap_or([0; 8]));
                if self.tie_breaker >= peer_tb {
                    self.controlling = true;
                } else {
                    responses.push((binding_error(&msg, 487, "Role Conflict", None), src));
                    return (responses, events);
                }
            }
            responses.push((binding_success(&msg, &src, self.local_pwd.as_bytes()), src));
            // Peer-reflexive learning (see ice.js): an
            // integrity-valid check from the same port reveals the
            // real IP behind an unresolvable mDNS candidate.
            for candidate in &mut self.remote_candidates {
                if candidate.addr.port() == src.port()
                    && candidate.addr.ip().is_unspecified()
                {
                    candidate.addr = src;
                }
            }
            if !self.valid.contains(&src) {
                self.valid.insert(src);
                events.push(IceEvent::PairValid { remote: src });
            }
            if !self.controlling && msg.attr(stun_attr::USE_CANDIDATE).is_some() {
                self.nominated = Some(src);
                self.last_consent = Some(std::time::Instant::now());
                events.push(IceEvent::Nominated { remote: src });
            }
        } else if msg.msg_type == crate::proto_gen::stun_msg::BINDING_SUCCESS {
            if !msg.check_integrity(raw, self.remote_pwd.as_bytes()) {
                return (responses, events);
            }
            if let Some((remote, nominate)) = self.outstanding.remove(&msg.transaction_id) {
                if !self.valid.contains(&remote) {
                    self.valid.insert(remote);
                    events.push(IceEvent::PairValid { remote });
                }
                if self.nominated == Some(remote) {
                    self.last_consent = Some(std::time::Instant::now());
                }
                if nominate {
                    self.nominated = Some(remote);
                    self.last_consent = Some(std::time::Instant::now());
                    events.push(IceEvent::Nominated { remote });
                }
            }
        }
        (responses, events)
    }
}
