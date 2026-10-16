// Minimal mDNS (RFC 6762) A/AAAA resolution: browsers hide host IPs
// behind "<uuid>.local" ICE candidates, and a native peer must resolve
// them to reach the browser. One multicast query to 224.0.0.251:5353,
// first matching answer wins. Node builtins only.

import dgram from "node:dgram";
import os from "node:os";

function encodeName(name) {
  const parts = [];
  for (const label of name.replace(/\.$/, "").split(".")) {
    const bytes = Buffer.from(label, "ascii");
    parts.push(Buffer.from([bytes.length]), bytes);
  }
  parts.push(Buffer.from([0]));
  return Buffer.concat(parts);
}

export function buildQuery(id, name) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(id, 0);
  header.writeUInt16BE(2, 4); // QDCOUNT: A and AAAA
  // IN|QU: the QU bit (RFC 6762 section 5.4) asks for a
  // unicast response to our ephemeral port; without it some
  // responders answer by multicast to :5353 only (we listen
  // there too; see resolveMdns).
  const wire = encodeName(name);
  const questions = Buffer.concat([
    wire, Buffer.from([0, 1, 0x80, 1]), // A
    wire, Buffer.from([0, 28, 0x80, 1]), // AAAA
  ]);
  return Buffer.concat([header, questions]);
}

function readName(buf, offset) {
  const labels = [];
  let pos = offset;
  let jumpedTo = null;
  for (let guard = 0; guard < 32; guard++) {
    const len = buf[pos];
    if (len === undefined) return { name: null, next: pos };
    if (len === 0) {
      return { name: labels.join("."), next: jumpedTo ?? pos + 1 };
    }
    if ((len & 0xc0) === 0xc0) {
      if (pos + 1 >= buf.length) return { name: null, next: pos };
      const target = ((len & 0x3f) << 8) | buf[pos + 1];
      if (jumpedTo === null) jumpedTo = pos + 2;
      pos = target;
      continue;
    }
    labels.push(buf.subarray(pos + 1, pos + 1 + len).toString("ascii"));
    pos += 1 + len;
  }
  return { name: null, next: pos };
}

function parseRecord(packet, name, wantType, wantLen) {
  if (packet.length < 12) return null;
  const qd = packet.readUInt16BE(4);
  const an = packet.readUInt16BE(6);
  let pos = 12;
  for (let i = 0; i < qd; i++) {
    const r = readName(packet, pos);
    if (r.name === null) return null;
    pos = r.next + 4;
  }
  const wanted = name.replace(/\.$/, "").toLowerCase();
  for (let i = 0; i < an; i++) {
    const r = readName(packet, pos);
    if (r.name === null || pos + 10 > packet.length) return null;
    pos = r.next;
    const type = packet.readUInt16BE(pos);
    const rdlen = packet.readUInt16BE(pos + 8);
    const rdata = packet.subarray(pos + 10, pos + 10 + rdlen);
    if (type === wantType && rdlen === wantLen && r.name.toLowerCase() === wanted) {
      return rdata;
    }
    pos += 10 + rdlen;
  }
  return null;
}

/** Extract an A record for `name` from a DNS response packet, or null. */
export function parseARecord(packet, name) {
  const rdata = parseRecord(packet, name, 1, 4);
  return rdata ? [...rdata].join(".") : null;
}

/** Extract an AAAA record for `name` from a DNS response packet, or null. */
export function parseAAAARecord(packet, name) {
  const rdata = parseRecord(packet, name, 28, 16);
  if (!rdata) return null;
  const groups = [];
  for (let i = 0; i < 16; i += 2) groups.push(rdata.readUInt16BE(i).toString(16));
  // Longest run of zero groups collapses to "::" (RFC 5952).
  let bestStart = -1, bestLen = 0, runStart = -1, runLen = 0;
  groups.forEach((g, i) => {
    if (g === "0") { if (runStart < 0) { runStart = i; runLen = 0; } runLen += 1; }
    else { if (runLen > bestLen) { bestStart = runStart; bestLen = runLen; } runStart = -1; runLen = 0; }
  });
  if (runLen > bestLen) { bestStart = runStart; bestLen = runLen; }
  if (bestLen < 2) return groups.join(":");
  const head = groups.slice(0, bestStart).join(":");
  const tail = groups.slice(bestStart + bestLen).join(":");
  return `${head}::${tail}`;
}

const cache = new Map();

/** Resolve a ".local" hostname to an IP address, or null. */
export async function resolveMdns(name, timeoutMs = 1500) {
  if (cache.has(name)) return cache.get(name);
  const ip = await new Promise((resolve) => {
    // Responders may answer unicast to the query socket (the
    // query asks with the QU bit) or multicast to the group
    // address — Chromium does the latter — so listen on both:
    // the ephemeral query socket and a group membership on
    // :5353 (best effort; the port may be taken).
    const sockets = [dgram.createSocket("udp4")];
    try {
      sockets.push(dgram.createSocket({ type: "udp4", reuseAddr: true }));
    } catch {
      /* query socket only */
    }
    let settled = false;
    const timer = setTimeout(() => done(null), timeoutMs);
    const done = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      for (const socket of sockets) {
        try {
          socket.close();
        } catch {
          /* already closed */
        }
      }
      resolve(value);
    };
    for (const socket of sockets) {
      socket.on("error", () => {});
      socket.on("message", (msg) => {
        const found = parseARecord(msg, name) ?? parseAAAARecord(msg, name);
        if (found) done(found);
      });
    }
    const [querySocket, groupSocket] = sockets;
    if (groupSocket) {
      groupSocket.bind(5353, () => {
        for (const list of Object.values(os.networkInterfaces())) {
          for (const entry of list ?? []) {
            if (entry.family === "IPv4" && !entry.internal) {
              try {
                groupSocket.addMembership("224.0.0.251", entry.address);
              } catch {
                /* interface not multicast-capable */
              }
            }
          }
        }
        try {
          groupSocket.addMembership("224.0.0.251");
        } catch {
          /* default interface membership failed */
        }
      });
    }
    querySocket.bind(0, () => {
      try {
        querySocket.setMulticastTTL(255);
        const query = buildQuery(0, name);
        querySocket.send(query, 5353, "224.0.0.251");
        setTimeout(() => {
          try {
            querySocket.send(query, 5353, "224.0.0.251");
          } catch {
            /* closed */
          }
        }, 250);
      } catch {
        done(null);
      }
    });
  });
  if (ip) cache.set(name, ip);
  return ip;
}
