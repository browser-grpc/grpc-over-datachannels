//! ICE (RFC 8445) agent: connectivity checks with short-term
//! credentials, role-conflict repair by tie-breaker, and
//! nomination. Pure state machine — the peer owns the UDP socket
//! and feeds packets in. Remote candidates may arrive inline in
//! SDP or trickled afterwards (add_remote_candidate).

use alloc::string::{String, ToString};
use alloc::vec::Vec;
use crate::crypto::random_u64;
use crate::platform::Clock;
#[cfg(feature = "std")]
use crate::platform::SystemClock;
use crate::proto_gen::stun_attr;
use crate::stun::{
    binding_error, binding_success, candidate_priority, host_priority, pair_priority,
    random_password, random_ufrag, Message,
};
#[cfg(feature = "std")]
use std::collections::{HashMap, HashSet};
#[cfg(not(feature = "std"))]
use alloc::collections::{BTreeMap as HashMap, BTreeSet as HashSet};
use alloc::sync::Arc;
use core::net::{IpAddr, Ipv4Addr, SocketAddr};

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
    // Pair -> when its last nominating check was sent (paces
    // nomination retransmission; see due_checks).
    nominating_sent_at: HashMap<SocketAddr, u64>,
    last_consent: Option<u64>,
    /// Monotonic clock (platform-injected; system clock by
    /// default). All consent/nomination pacing reads through it.
    clock: Arc<dyn Clock>,
    // ICE generations (RFC 8445 section 5.1 restarts):
    // nominated_gen is the generation that produced the
    // current nomination. While they differ a restart is in
    // flight: checks run again and consent pauses; the old
    // pair keeps serving media until renomination.
    generation: u64,
    nominated_gen: u64,
}

/// Paces re-sends of the nominating check for one pair until
/// its Binding success arrives.
const NOMINATION_RETRANSMIT: core::time::Duration = core::time::Duration::from_millis(250);

#[cfg(feature = "std")]
fn default_clock() -> Arc<dyn Clock> {
    Arc::new(SystemClock::new())
}

#[cfg(not(feature = "std"))]
fn default_clock() -> Arc<dyn Clock> {
    Arc::new(crate::platform::ManualClock::new(0))
}

impl IceAgent {
    pub fn new(controlling: bool) -> Self {
        Self::new_with_clock(controlling, default_clock())
    }

    /// New agent reading time from `clock` (embedded/RTOS and
    /// deterministic tests inject a manual clock here).
    pub fn new_with_clock(controlling: bool, clock: Arc<dyn Clock>) -> Self {
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
            nominating_sent_at: HashMap::new(),
            last_consent: None,
            generation: 0,
            nominated_gen: 0,
            clock,
        }
    }

    fn now_ms(&self) -> u64 {
        self.clock.now_ms()
    }

    /// Begin an ICE restart (RFC 8445 section 5.1): fresh local
    /// credentials, check state cleared, generation bumped. The
    /// nominated pair is retained until a pair from the new
    /// generation is nominated.
    pub fn restart(&mut self) {
        self.local_ufrag = random_ufrag();
        self.local_pwd = random_password();
        self.generation += 1;
        self.valid.clear();
        self.outstanding.clear();
        self.nominating_sent_at.clear();
    }

    /// The current ICE generation (0 at connect, +1 per restart).
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Whether the nominated pair belongs to the current
    /// generation (no restart in flight).
    pub fn renominated(&self) -> bool {
        self.nominated.is_some() && self.nominated_gen == self.generation
    }

    pub fn set_remote(&mut self, ufrag: &str, pwd: &str, candidates: Vec<Candidate>) {
        self.remote_ufrag = ufrag.to_string();
        self.remote_pwd = pwd.to_string();
        self.remote_candidates = candidates;
        // New remote credentials invalidate prior check state
        // (initial connect: already empty).
        self.valid.clear();
        self.outstanding.clear();
        self.nominating_sent_at.clear();
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
        if self.renominated() {
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
            // Nominate the best valid pair, retransmitting the
            // nominating check until its success response lands
            // (RFC 8489 transactions are not fire-and-forget: a
            // single USE-CANDIDATE can be lost, or reach the
            // peer before its side of the pair has validated).
            if let Some(best) = self.best_valid_pair() {
                let due = self.nominating_sent_at.get(&best).map_or(true, |last| {
                    self.now_ms().saturating_sub(*last)
                        >= NOMINATION_RETRANSMIT.as_millis() as u64
                });
                if due {
                    let now = self.now_ms();
                    self.nominating_sent_at.insert(best, now);
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
        // Paused pre-nomination and while a restart is in flight.
        if !self.renominated() {
            return None;
        }
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
            self.last_consent = Some(self.now_ms());
        }
    }

    /// Whether consent for the nominated pair has lapsed (no
    /// Binding success for it within `expiry`).
    pub fn consent_expired(&self, expiry: core::time::Duration) -> bool {
        if !self.renominated() {
            return false;
        }
        match (self.nominated, self.last_consent) {
            (Some(_), Some(last)) => {
                self.now_ms().saturating_sub(last) > expiry.as_millis() as u64
            }
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
                self.nominated_gen = self.generation;
                self.last_consent = Some(self.now_ms());
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
                    self.last_consent = Some(self.now_ms());
                }
                if nominate {
                    self.nominated = Some(remote);
                    self.nominated_gen = self.generation;
                    self.last_consent = Some(self.now_ms());
                    events.push(IceEvent::Nominated { remote });
                }
            }
        }
        (responses, events)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    fn nominating_count(checks: &[(Vec<u8>, SocketAddr)]) -> usize {
        checks
            .iter()
            .filter(|(bytes, _)| {
                Message::decode(bytes)
                    .map(|msg| msg.attr(stun_attr::USE_CANDIDATE).is_some())
                    .unwrap_or(false)
            })
            .count()
    }

    /// The nominating check is a STUN transaction, not a
    /// one-shot: it must be retransmitted (paced) until its
    /// Binding success arrives, and stop once nominated.
    #[test]
    fn nomination_check_retransmits_until_answered() {
        let addr = |port| SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
        // Manual clocks make pacing deterministic (platform seam).
        let a_clock = std::sync::Arc::new(crate::platform::ManualClock::new(0));
        let mut a = IceAgent::new_with_clock(true, a_clock.clone());
        let mut b = IceAgent::new(false);
        a.local_candidates = vec![Candidate::host(addr(4000), "a")];
        b.local_candidates = vec![Candidate::host(addr(5000), "b")];
        a.set_remote(&b.local_ufrag.clone(), &b.local_pwd.clone(), b.local_candidates.clone());
        b.set_remote(&a.local_ufrag.clone(), &a.local_pwd.clone(), a.local_candidates.clone());

        // B's regular check validates the pair at A.
        let b_checks = b.due_checks();
        a.handle_stun(&b_checks[0].0, addr(5000));

        let checks = a.due_checks();
        assert_eq!(nominating_count(&checks), 1, "first due_checks nominates");
        let checks = a.due_checks();
        assert_eq!(nominating_count(&checks), 0, "immediate re-poll is paced");

        // Advance past the retransmit interval.
        a_clock.advance(251);
        let checks = a.due_checks();
        assert_eq!(nominating_count(&checks), 1, "retransmit after the interval");

        // Deliver it to B and return the success: nominated,
        // and checks stop.
        let nominating = checks
            .iter()
            .find(|(bytes, _)| {
                Message::decode(bytes)
                    .map(|msg| msg.attr(stun_attr::USE_CANDIDATE).is_some())
                    .unwrap_or(false)
            })
            .expect("nominating check present");
        let (responses, _) = b.handle_stun(&nominating.0, addr(4000));
        assert_eq!(responses.len(), 1);
        a.handle_stun(&responses[0].0, addr(5000));
        assert_eq!(a.nominated, Some(addr(5000)));
        assert!(a.due_checks().is_empty(), "checks stop after nomination");
    }
}
