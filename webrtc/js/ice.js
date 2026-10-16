// ICE (RFC 8445) agent — mirroring webrtc/rust/src/ice.rs:
// connectivity checks with short-term credentials, tie-breaker
// role-conflict repair, nomination. Remote candidates may arrive
// inline in SDP or trickled afterwards (addRemoteCandidate).

import crypto from "node:crypto";
import { StunAttribute, StunMessageType } from "./proto_gen.js";
import {
  StunMessage,
  bindingError,
  bindingSuccess,
  candidatePriority,
  formatIp,
  hostPriority,
  normalizeIp,
  pairPriority,
  parseIp,
  randomPassword,
  randomUfrag,
} from "./stun.js";

// Canonical text form for IP literals (compressed IPv6,
// dotted IPv4); hostnames (mDNS) pass through unchanged.
function canonicalAddress(address) {
  const parsed = parseIp(address);
  return parsed ? normalizeIp(formatIp(parsed.bytes)) : address;
}

export class Candidate {
  constructor({ foundation, component = 1, priority, address, port, type = "host", raddr = "", rport = 0 }) {
    this.foundation = foundation;
    this.component = component;
    this.priority = priority;
    this.address = canonicalAddress(address);
    this.port = port;
    this.type = type;
    this.raddr = raddr;
    this.rport = rport;
  }

  static host(address, port, foundation) {
    return new Candidate({ foundation, priority: hostPriority(1), address, port });
  }

  // Server-reflexive candidate learned from a STUN server (RFC 8445
  // section 5.1.2): address:port is the mapped address, base the host
  // candidate it was gathered from (same socket).
  static srflx(address, port, base, foundation) {
    return new Candidate({
      foundation,
      priority: candidatePriority(100, 1),
      address,
      port,
      type: "srflx",
      raddr: base.address,
      rport: base.port,
    });
  }

  // Relayed candidate from a TURN allocation (RFC 5766; type
  // preference 0: last resort, RFC 8445 section 5.1.1).
  static relay(address, port, base, foundation) {
    return new Candidate({
      foundation,
      priority: candidatePriority(0, 1),
      address,
      port,
      type: "relay",
      raddr: base.address,
      rport: base.port,
    });
  }

  get key() {
    return `${this.address}:${this.port}`;
  }

  toSdp() {
    // Related address comes before "generation 0": some parsers
    // (Firefox's nICEr) stop scanning extensions at unknown
    // attributes and then reject srflx/relay candidates whose
    // raddr they never saw. Browsers emit this order too.
    let out = `a=candidate:${this.foundation} ${this.component} udp ${this.priority} ${this.address} ${this.port} typ ${this.type}`;
    if (this.type === "srflx" || this.type === "relay") out += ` raddr ${this.raddr} rport ${this.rport}`;
    out += " generation 0";
    return out;
  }

  static fromSdp(value) {
    const parts = value.trim().split(/\s+/);
    if (parts.length < 8 || parts[6] !== "typ") return null;
    const cand = new Candidate({
      foundation: parts[0].replace(/^candidate:/, ""),
      component: Number(parts[1]),
      priority: Number(parts[3]),
      address: parts[4],
      port: Number(parts[5]),
      type: parts[7],
    });
    for (let i = 8; i + 1 < parts.length; i += 2) {
      if (parts[i] === "raddr") cand.raddr = parts[i + 1];
      if (parts[i] === "rport") cand.rport = Number(parts[i + 1]);
    }
    return cand;
  }
}

// Paces re-sends of the nominating check for one pair until its
// Binding success arrives.
const NOMINATION_RETRANSMIT_MS = 250;

export class IceAgent {
  constructor(controlling) {
    this.localUfrag = randomUfrag();
    this.localPwd = randomPassword();
    this.remoteUfrag = "";
    this.remotePwd = "";
    this.controlling = controlling;
    this.tieBreaker = crypto.randomBytes(8).readBigUInt64BE(0);
    this.localCandidates = [];
    this.remoteCandidates = [];
    this.outstanding = new Map(); // tid hex -> {remoteKey, remote, nominate}
    this.valid = new Set();
    this.nominated = null;
    // Pair key -> ms epoch of the last nominating check sent
    // (paces nomination retransmission; see dueChecks).
    this.nominatingSentAt = new Map();
    // When consent for the nominated pair was last confirmed
    // (nomination, or a Binding success for it; ms epoch).
    this.lastConsentMs = 0;
    // ICE generations (RFC 8445 section 5.1 restarts):
    // nominatedGen is the generation that produced the current
    // nomination. While they differ a restart is in flight:
    // checks run again and consent pauses; the old pair keeps
    // serving media until renomination.
    this.generation = 0;
    this.nominatedGen = 0;
  }

  // Begin an ICE restart: fresh local credentials, check state
  // cleared, generation bumped. The nominated pair is retained
  // until a pair from the new generation is nominated.
  restart() {
    this.localUfrag = randomUfrag();
    this.localPwd = randomPassword();
    this.generation += 1;
    this.valid = new Set();
    this.outstanding = new Map();
    this.nominatingSentAt = new Map();
  }

  // Whether the nominated pair belongs to the current
  // generation (no restart in flight).
  get renominated() {
    return this.nominated !== null && this.nominatedGen === this.generation;
  }

  setRemote(ufrag, pwd, candidates) {
    this.remoteUfrag = ufrag;
    this.remotePwd = pwd;
    this.remoteCandidates = candidates;
    // New remote credentials invalidate prior check state
    // (initial connect: already empty).
    this.valid = new Set();
    this.outstanding = new Map();
    this.nominatingSentAt = new Map();
  }

  // Trickle one remote candidate in after the remote description
  // (RFC 8445 §4.1.1). Returns false when the candidate is already
  // known (same address:port) so duplicate trickle is a no-op.
  addRemoteCandidate(cand) {
    if (this.remoteCandidates.some((c) => c.key === cand.key)) return false;
    this.remoteCandidates.push(cand);
    return true;
  }

  get localPriority() {
    return this.localCandidates[0]?.priority ?? hostPriority(1);
  }

  buildCheck(remote, nominate) {
    const msg = new StunMessage(StunMessageType.BINDING_REQUEST);
    msg.attrs.push([
      StunAttribute.USERNAME,
      Buffer.from(`${this.remoteUfrag}:${this.localUfrag}`),
    ]);
    const prio = Buffer.alloc(4);
    prio.writeUInt32BE(this.localPriority, 0);
    msg.attrs.push([StunAttribute.PRIORITY, prio]);
    const tb = Buffer.alloc(8);
    tb.writeBigUInt64BE(this.tieBreaker, 0);
    msg.attrs.push([
      this.controlling ? StunAttribute.ICE_CONTROLLING : StunAttribute.ICE_CONTROLLED,
      tb,
    ]);
    if (nominate && this.controlling) msg.attrs.push([StunAttribute.USE_CANDIDATE, Buffer.alloc(0)]);
    const bytes = msg.encode(Buffer.from(this.remotePwd));
    this.outstanding.set(msg.transactionId.toString("hex"), { remote, nominate });
    return { bytes, remote };
  }

  // One consent-freshness Binding request for the nominated
  // pair (RFC 8445 section 10 / RFC 7675); null pre-nomination.
  consentCheck() {
    // Paused pre-nomination and while a restart is in flight.
    if (!this.renominated) return null;
    const key = `${this.nominated.address}:${this.nominated.port}`;
    const cand =
      this.remoteCandidates.find((c) => c.key === key) ??
      Candidate.host(this.nominated.address, this.nominated.port, "peer-reflexive");
    return this.buildCheck(cand, false);
  }

  // Mark consent as freshly confirmed (e.g. the DTLS
  // handshake just completed over this pair).
  touchConsent() {
    if (this.nominated) this.lastConsentMs = Date.now();
  }

  // Whether consent for the nominated pair has lapsed (no
  // Binding success for it within expiryMs).
  consentExpired(expiryMs) {
    if (!this.renominated || !this.lastConsentMs) return false;
    return Date.now() - this.lastConsentMs > expiryMs;
  }

  dueChecks() {
    const out = [];
    if (this.renominated) return out;
    for (const remote of this.remoteCandidates) out.push(this.buildCheck(remote, false));
    if (this.controlling) {
      // Nominate the best valid pair, retransmitting the
      // nominating check until its success response lands
      // (RFC 8489 transactions are not fire-and-forget: a
      // single USE-CANDIDATE can be lost, or reach the peer
      // before its side of the pair has validated).
      const best = this.bestValidPair();
      if (best) {
        const last = this.nominatingSentAt.get(best.key);
        if (last === undefined || Date.now() - last >= NOMINATION_RETRANSMIT_MS) {
          this.nominatingSentAt.set(best.key, Date.now());
          out.push(this.buildCheck(best, true));
        }
      }
    }
    return out;
  }

  bestValidPair() {
    const valid = this.remoteCandidates.filter((c) => this.valid.has(c.key));
    if (valid.length) {
      return valid.sort(
        (a, b) =>
          pairPriority(this.localPriority, b.priority, this.controlling) -
          pairPriority(this.localPriority, a.priority, this.controlling),
      )[0];
    }
    // Peer-reflexive fallback (mirrors the Rust agent): the peer's
    // checks revealed a reachable address that no resolvable SDP
    // candidate matches — e.g. an mDNS candidate whose
    // peer-reflexive rewrite never fires because the browser stops
    // checking once its own pair validates. Nominate the learned
    // address directly.
    for (const key of this.valid) {
      const idx = key.lastIndexOf(":");
      if (idx < 0) continue;
      return Candidate.host(key.slice(0, idx), Number(key.slice(idx + 1)), "peer-reflexive");
    }
    return null;
  }

  /** Returns {responses: [{bytes, remote}], events: [{type, remote}]} */
  handleStun(raw, src) {
    const responses = [];
    const events = [];
    const msg = StunMessage.decode(raw);
    if (!msg) return { responses, events };
    if (msg.type === StunMessageType.BINDING_REQUEST) {
      const username = msg.attr(StunAttribute.USERNAME);
      if (!username) return { responses, events };
      const [targetUfrag] = username.toString().split(":");
      if (targetUfrag !== this.localUfrag) return { responses, events };
      if (!msg.checkIntegrity(raw, Buffer.from(this.localPwd))) {
        responses.push({ bytes: bindingError(msg, 401, "Unauthorized"), remote: src });
        return { responses, events };
      }
      if (this.controlling) {
        const tb = msg.attr(StunAttribute.ICE_CONTROLLING);
        if (tb) {
          const peerTb = tb.readBigUInt64BE(0);
          if (peerTb >= this.tieBreaker) {
            this.controlling = false;
          } else {
            responses.push({ bytes: bindingError(msg, 487, "Role Conflict"), remote: src });
            return { responses, events };
          }
        }
      } else {
        const tb = msg.attr(StunAttribute.ICE_CONTROLLED);
        if (tb) {
          const peerTb = tb.readBigUInt64BE(0);
          if (this.tieBreaker >= peerTb) {
            this.controlling = true;
          } else {
            responses.push({ bytes: bindingError(msg, 487, "Role Conflict"), remote: src });
            return { responses, events };
          }
        }
      }
      responses.push({ bytes: bindingSuccess(msg, src, Buffer.from(this.localPwd)), remote: src });
      // Peer-reflexive learning: browsers advertise mDNS ".local"
      // candidates that may be unresolvable (e.g. inside containers);
      // an integrity-valid check from the same port reveals the real
      // IP, so our own checks can reach that candidate too.
      for (const candidate of this.remoteCandidates) {
        if (candidate.port === src.port && !/^\d+\.\d+\.\d+\.\d+$/.test(candidate.address)) {
          candidate.address = src.address;
        }
      }
      const key = `${src.address}:${src.port}`;
      if (!this.valid.has(key)) {
        this.valid.add(key);
        events.push({ type: "pair-valid", remote: src });
      }
      if (!this.controlling && msg.attr(StunAttribute.USE_CANDIDATE)) {
        this.nominated = src;
        this.nominatedGen = this.generation;
        this.lastConsentMs = Date.now();
        events.push({ type: "nominated", remote: src });
      }
    } else if (msg.type === StunMessageType.BINDING_SUCCESS) {
      if (!msg.checkIntegrity(raw, Buffer.from(this.remotePwd))) {
        return { responses, events };
      }
      const tid = msg.transactionId.toString("hex");
      const entry = this.outstanding.get(tid);
      if (entry) {
        this.outstanding.delete(tid);
        const { remote, nominate } = entry;
        if (!this.valid.has(remote.key)) {
          this.valid.add(remote.key);
          events.push({ type: "pair-valid", remote });
        }
        if (this.nominated && remote.key === `${this.nominated.address}:${this.nominated.port}`) {
          this.lastConsentMs = Date.now();
        }
        if (nominate) {
          this.nominated = { address: remote.address, port: remote.port };
          this.nominatedGen = this.generation;
          this.lastConsentMs = Date.now();
          events.push({ type: "nominated", remote: this.nominated });
        }
      }
    }
    return { responses, events };
  }
}
