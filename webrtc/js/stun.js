// STUN (RFC 8489) Binding messages with short-term credentials:
// MESSAGE-INTEGRITY (HMAC-SHA1) and FINGERPRINT (CRC-32), plus
// XOR-MAPPED-ADDRESS — mirroring webrtc/rust/src/stun.rs.

import crypto from "node:crypto";
import net from "node:net";
import { CRC32_TABLE, StunAttribute, StunMessageType } from "./proto_gen.js";

export const MAGIC = 0x2112a442;

export function crc32(buf) {
  let crc = 0xffffffff;
  for (const b of buf) {
    crc = CRC32_TABLE[(crc ^ b) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

export class StunMessage {
  constructor(type) {
    this.type = type;
    this.transactionId = crypto.randomBytes(12);
    this.attrs = [];
  }

  attr(ty) {
    const found = this.attrs.find(([t]) => t === ty);
    return found ? found[1] : null;
  }

  encode(integrityKey = null) {
    const parts = [];
    for (const [ty, value] of this.attrs) {
      if (ty === StunAttribute.MESSAGE_INTEGRITY || ty === StunAttribute.FINGERPRINT) continue;
      const head = Buffer.alloc(4);
      head.writeUInt16BE(ty, 0);
      head.writeUInt16BE(value.length, 2);
      const padded = Buffer.alloc(4 + Math.ceil(value.length / 4) * 4);
      head.copy(padded);
      value.copy(padded, 4);
      parts.push(padded);
    }
    const body = Buffer.concat(parts);
    const header = Buffer.alloc(20);
    header.writeUInt16BE(this.type, 0);
    header.writeUInt32BE(MAGIC, 4);
    this.transactionId.copy(header, 8);
    if (!integrityKey) {
      header.writeUInt16BE(body.length, 2);
      return Buffer.concat([header, body]);
    }
    // Stage the length: through MI first (RFC 8489 §14.5), FP excluded
    // for the CRC (§14.7), final length written last.
    header.writeUInt16BE(body.length + 24, 2);
    const mac = crypto.createHmac("sha1", integrityKey).update(Buffer.concat([header, body])).digest();
    const mi = Buffer.alloc(24);
    mi.writeUInt16BE(StunAttribute.MESSAGE_INTEGRITY, 0);
    mi.writeUInt16BE(20, 2);
    mac.copy(mi, 4);
    // FINGERPRINT CRC (§14.7) covers the header with the FINAL length
    // (including the FP attribute) already written.
    header.writeUInt16BE(body.length + 24 + 8, 2);
    const beforeFp = Buffer.concat([header, body, mi]);
    const fp = Buffer.alloc(8);
    fp.writeUInt16BE(StunAttribute.FINGERPRINT, 0);
    fp.writeUInt16BE(4, 2);
    fp.writeUInt32BE((crc32(beforeFp) ^ 0x5354554e) >>> 0, 4);
    return Buffer.concat([beforeFp, fp]);
  }

  static decode(data) {
    if (data.length < 20 || data.readUInt32BE(4) !== MAGIC) return null;
    const len = data.readUInt16BE(2);
    if (20 + len > data.length) return null;
    const msg = new StunMessage(data.readUInt16BE(0));
    msg.transactionId = Buffer.from(data.subarray(8, 20));
    let pos = 20;
    const end = 20 + len;
    while (pos + 4 <= end) {
      const ty = data.readUInt16BE(pos);
      const alen = data.readUInt16BE(pos + 2);
      if (pos + 4 + alen > end) break;
      msg.attrs.push([ty, Buffer.from(data.subarray(pos + 4, pos + 4 + alen))]);
      pos += 4 + Math.ceil(alen / 4) * 4;
    }
    return msg;
  }

  checkIntegrity(raw, key) {
    let pos = 20;
    while (pos + 4 <= raw.length) {
      const ty = raw.readUInt16BE(pos);
      const alen = raw.readUInt16BE(pos + 2);
      if (ty === StunAttribute.MESSAGE_INTEGRITY) {
        const prefix = Buffer.from(raw.subarray(0, pos));
        prefix.writeUInt16BE(pos - 20 + 24, 2);
        const expected = crypto.createHmac("sha1", key).update(prefix).digest();
        return expected.equals(raw.subarray(pos + 4, pos + 4 + alen));
      }
      pos += 4 + Math.ceil(alen / 4) * 4;
    }
    return false;
  }
}

// Parse an IPv4/IPv6 literal into {family, bytes} (bytes is a
// 4- or 16-byte Buffer); null when not an IP literal. Handles
// "::" compression and an embedded IPv4 tail.
export function parseIp(address) {
  if (net.isIPv4(address)) {
    return { family: 1, bytes: Buffer.from(address.split(".").map(Number)) };
  }
  if (!net.isIPv6(address)) return null;
  let rest = address;
  let v4Tail = null;
  const v4Match = rest.match(/(\d+\.\d+\.\d+\.\d+)$/);
  if (v4Match) {
    v4Tail = v4Match[1].split(".").map(Number);
    rest = rest.slice(0, rest.length - v4Match[1].length);
    if (!rest.endsWith(":")) return null;
    rest = rest.slice(0, -1) + ":0:0";
  }
  const halves = rest.split("::");
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(":") : [];
  const right = halves.length === 2 ? (halves[1] ? halves[1].split(":") : []) : null;
  const groups = [];
  if (right === null) {
    if (left.length !== 8) return null;
    groups.push(...left);
  } else {
    const missing = 8 - left.length - right.length;
    if (missing < 1) return null;
    groups.push(...left, ...Array(missing).fill("0"), ...right);
  }
  const bytes = Buffer.alloc(16);
  groups.forEach((g, i) => bytes.writeUInt16BE(parseInt(g || "0", 16) & 0xffff, i * 2));
  if (v4Tail) Buffer.from(v4Tail).copy(bytes, 12);
  return { family: 2, bytes };
}

// Canonical text form (RFC 5952-ish): lowercase, longest zero
// run of 2+ groups compressed to "::", IPv4-mapped shown dotted.
export function formatIp(bytes) {
  if (bytes.length === 4) return [...bytes].join(".");
  const groups = [];
  for (let i = 0; i < 8; i++) groups.push(bytes.readUInt16BE(i * 2));
  if (groups.slice(0, 5).every((g) => g === 0) && groups[5] === 0xffff) {
    return "::ffff:" + [...bytes.subarray(12)].join(".");
  }
  let bestStart = -1;
  let bestLen = 0;
  for (let i = 0; i < 8; ) {
    if (groups[i] !== 0) {
      i++;
      continue;
    }
    let j = i;
    while (j < 8 && groups[j] === 0) j++;
    if (j - i > bestLen) {
      bestLen = j - i;
      bestStart = i;
    }
    i = j;
  }
  const hex = groups.map((g) => g.toString(16));
  if (bestLen < 2) return hex.join(":");
  const left = hex.slice(0, bestStart).join(":");
  const right = hex.slice(bestStart + bestLen).join(":");
  return `${left}::${right}`;
}

export function isIpv6(address) {
  return net.isIPv6(address);
}

// Strip an IPv4-mapped prefix ("::ffff:127.0.0.1" -> "127.0.0.1")
// as seen on dual-stack (udp6) sockets.
export function normalizeIp(address) {
  if (typeof address === "string" && address.toLowerCase().startsWith("::ffff:")) {
    const rest = address.slice(7);
    if (net.isIPv4(rest)) return rest;
  }
  return address;
}

// Parse "host:port", "[v6host]:port", or a bare host/IP into
// {address, port} (defaultPort when no port given); null when
// malformed.
export function parseHostPort(text, defaultPort = 0) {
  if (!text) return null;
  const trimmed = String(text).trim();
  if (trimmed.startsWith("[")) {
    const end = trimmed.indexOf("]");
    if (end < 0) return null;
    const address = trimmed.slice(1, end);
    const rest = trimmed.slice(end + 1);
    const port = rest.startsWith(":") ? Number(rest.slice(1)) : defaultPort;
    return address && port ? { address, port } : null;
  }
  if (net.isIPv6(trimmed)) return defaultPort ? { address: trimmed, port: defaultPort } : null;
  const idx = trimmed.lastIndexOf(":");
  if (idx < 0) return defaultPort ? { address: trimmed, port: defaultPort } : null;
  const address = trimmed.slice(0, idx);
  const port = Number(trimmed.slice(idx + 1));
  return address && port ? { address, port } : null;
}

function xorMask(transactionId, length) {
  const magic = Buffer.alloc(4);
  magic.writeUInt32BE(MAGIC, 0);
  if (length === 4) return magic;
  return Buffer.concat([magic, Buffer.from(transactionId)]);
}

export function xorMappedAddress(addr, transactionId) {
  const parsed = parseIp(normalizeIp(addr.address));
  if (!parsed) throw new Error(`stun: not an IP address: ${addr.address}`);
  const out = Buffer.alloc(4 + parsed.bytes.length);
  out[1] = parsed.family;
  out.writeUInt16BE(addr.port ^ (MAGIC >>> 16), 2);
  const mask = xorMask(transactionId, parsed.bytes.length);
  parsed.bytes.forEach((b, i) => {
    out[4 + i] = b ^ mask[i];
  });
  return out;
}

export function bindingSuccess(request, peerAddr, key) {
  const resp = new StunMessage(StunMessageType.BINDING_SUCCESS);
  resp.transactionId = Buffer.from(request.transactionId);
  resp.attrs.push([StunAttribute.XOR_MAPPED_ADDRESS, xorMappedAddress(peerAddr, request.transactionId)]);
  resp.attrs.push([StunAttribute.SOFTWARE, Buffer.from("dc-webrtc")]);
  return resp.encode(key);
}

export function bindingError(request, code, reason) {
  const resp = new StunMessage(StunMessageType.BINDING_ERROR);
  resp.transactionId = Buffer.from(request.transactionId);
  const value = Buffer.concat([
    Buffer.from([0, 0, Math.floor(code / 100), code % 100]),
    Buffer.from(reason),
  ]);
  resp.attrs.push([StunAttribute.ERROR_CODE, value]);
  return resp.encode(null);
}

// RFC 8445 priority: (2^24)*typePreference + (2^8)*localPreference
// + (256-component). Host uses type preference 126, srflx 100.
export const candidatePriority = (typePreference, component = 1) =>
  ((typePreference << 24) + (65535 << 8) + (256 - component)) >>> 0;
export const hostPriority = (component = 1) => candidatePriority(126, component);

// Decode an XOR-MAPPED-ADDRESS (or MAPPED-ADDRESS) attribute
// value into {address, port}; null when malformed. IPv4-mapped
// IPv6 results are normalized to dotted IPv4.
export function decodeMappedAddress(msg, xor) {
  const value = msg.attr(xor ? StunAttribute.XOR_MAPPED_ADDRESS : StunAttribute.MAPPED_ADDRESS);
  return decodeAddressValue(value, msg.transactionId, xor);
}

export function decodeAddressValue(value, transactionId, xor = true) {
  if (!value || value.length < 4) return null;
  const family = value[1];
  const ipLen = family === 1 ? 4 : family === 2 ? 16 : 0;
  if (!ipLen || value.length < 4 + ipLen) return null;
  let port = value.readUInt16BE(2);
  const ip = Buffer.from(value.subarray(4, 4 + ipLen));
  if (xor) {
    port ^= MAGIC >>> 16;
    const mask = xorMask(transactionId, ipLen);
    ip.forEach((b, i) => {
      ip[i] = b ^ mask[i];
    });
  }
  return { address: normalizeIp(formatIp(ip)), port };
}

export function pairPriority(localPrio, remotePrio, weControl) {
  const g = weControl ? localPrio : remotePrio;
  const d = weControl ? remotePrio : localPrio;
  const min = Math.min(g, d);
  const max = Math.max(g, d);
  return 4294967296 * min + 2 * max + (g > d ? 1 : 0);
}

const ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/";
const randomIceString = (n) =>
  [...crypto.randomBytes(n)].map((b) => ALPHABET[b % 64]).join("");
export const randomUfrag = () => randomIceString(6);
// RFC 8445: ice-pwd must be 22..=256 characters (browsers enforce).
export const randomPassword = () => randomIceString(24);
