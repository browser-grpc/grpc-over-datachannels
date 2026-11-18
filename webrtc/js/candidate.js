// ICE candidate value type (RFC 8445 §5.1) and its SDP
// form — shared by sdp.js, peer.js, and the Wasm ICE
// adapter. The ICE agent itself is the Rust core
// (crates/dc-ice-wasm) behind ice_wasm.js.
import { candidatePriority, formatIp, hostPriority, normalizeIp, parseIp } from "./stun.js";

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

