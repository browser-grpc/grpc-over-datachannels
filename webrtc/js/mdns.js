// Minimal mDNS (RFC 6762) A-record resolution: browsers hide host IPs
// behind "<uuid>.local" ICE candidates, and a native peer must resolve
// them to reach the browser. One multicast query to 224.0.0.251:5353,
// first matching answer wins. Node builtins only.

import dgram from "node:dgram";

function encodeName(name) {
  const parts = [];
  for (const label of name.replace(/\.$/, "").split(".")) {
    const bytes = Buffer.from(label, "ascii");
    parts.push(Buffer.from([bytes.length]), bytes);
  }
  parts.push(Buffer.from([0]));
  return Buffer.concat(parts);
}

function buildQuery(id, name) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(id, 0);
  header.writeUInt16BE(1, 4); // QDCOUNT
  const question = Buffer.concat([encodeName(name), Buffer.from([0, 1, 0, 1])]); // A, IN
  return Buffer.concat([header, question]);
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

/** Extract an A record for `name` from a DNS response packet, or null. */
export function parseARecord(packet, name) {
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
    if (type === 1 && rdlen === 4 && r.name.toLowerCase() === wanted) {
      return [...rdata].join(".");
    }
    pos += 10 + rdlen;
  }
  return null;
}

const cache = new Map();

/** Resolve a ".local" hostname to an IPv4 address, or null. */
export async function resolveMdns(name, timeoutMs = 1500) {
  if (cache.has(name)) return cache.get(name);
  const ip = await new Promise((resolve) => {
    const socket = dgram.createSocket("udp4");
    const timer = setTimeout(() => done(null), timeoutMs);
    const done = (value) => {
      clearTimeout(timer);
      try {
        socket.close();
      } catch {
        /* already closed */
      }
      resolve(value);
    };
    socket.on("error", () => done(null));
    socket.on("message", (msg) => {
      const found = parseARecord(msg, name);
      if (found) done(found);
    });
    socket.bind(0, () => {
      try {
        socket.setMulticastTTL(255);
        const query = buildQuery(0x4d44, name);
        socket.send(query, 5353, "224.0.0.251");
        setTimeout(() => {
          try {
            socket.send(query, 5353, "224.0.0.251");
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
