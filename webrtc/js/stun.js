// STUN (RFC 8489) Binding messages with short-term credentials:
// MESSAGE-INTEGRITY (HMAC-SHA1) and FINGERPRINT (CRC-32), plus
// XOR-MAPPED-ADDRESS — mirroring webrtc/rust/src/stun.rs.

import crypto from "node:crypto";
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

export function xorMappedAddress(addr, transactionId) {
  void transactionId;
  const out = Buffer.alloc(8);
  out[1] = 1;
  out.writeUInt16BE(addr.port ^ (MAGIC >>> 16), 2);
  const ipNum = addr.address.split(".").reduce((acc, octet) => acc * 256 + Number(octet), 0);
  out.writeUInt32BE((ipNum ^ MAGIC) >>> 0, 4);
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

// Decode an XOR-MAPPED-ADDRESS (or MAPPED-ADDRESS) attribute value
// into {address, port}; null when malformed or not IPv4.
export function decodeMappedAddress(msg, xor) {
  const value = msg.attr(xor ? StunAttribute.XOR_MAPPED_ADDRESS : StunAttribute.MAPPED_ADDRESS);
  if (!value || value.length < 8 || value[1] !== 1) return null;
  let port = value.readUInt16BE(2);
  let ipNum = value.readUInt32BE(4);
  if (xor) {
    port ^= MAGIC >>> 16;
    ipNum = (ipNum ^ MAGIC) >>> 0;
  }
  const address = [ipNum >>> 24, (ipNum >>> 16) & 0xff, (ipNum >>> 8) & 0xff, ipNum & 0xff].join(".");
  return { address, port };
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
