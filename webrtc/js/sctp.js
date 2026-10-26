// SCTP (RFC 9260) subset for WebRTC datachannels — a pure
// packet-in/packet-out state machine mirroring webrtc/rust/src/sctp.rs:
// INIT/COOKIE handshake (HMAC state cookie), DATA/SACK with gap reports
// and fast retransmit, fragmentation/reassembly, ordered + unordered
// delivery, PR-SCTP FORWARD-TSN, RE-CONFIG stream reset (RFC 6525, for
// datachannel close), HEARTBEAT, SHUTDOWN, CRC-32C checksum.

import crypto from "node:crypto";
import { CRC32C_TABLE, SctpChunk, SctpParam, SctpReconfig } from "./proto_gen.js";

// Env-gated packet tracing for wedge hunts (node only).
const SCTP_TRACE =
  typeof process !== "undefined" && process.env && process.env.GRPC_DC_SCTP_TRACE;
function strace(...args) {
  if (SCTP_TRACE) console.error("[sctp-trace]", ...args);
}

export const SCTP_PORT = 5000;
const MAX_DATA_PAYLOAD = 1000;
const INITIAL_RWND = 262144;
const INITIAL_RTO_MS = 1000;
// RFC 9260 §6.1: initial cwnd is 4 MTU here (fragment payload
// is 1000B, so ~4 fragments in flight before SACK clocking).
const INITIAL_CWND = 4 * MAX_DATA_PAYLOAD;

export function crc32c(buf) {
  let crc = 0xffffffff;
  for (const b of buf) {
    crc = CRC32C_TABLE[(crc ^ b) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

const u32 = (n) => n >>> 0;
const add32 = (a, b) => (a + b) >>> 0;
/** Signed difference a-b in TSN (serial number) arithmetic. */
const diff32 = (a, b) => {
  let d = (a - b) % 4294967296;
  if (d > 2147483647) d -= 4294967296;
  if (d < -2147483648) d += 4294967296;
  return d;
};

function chunk(type, flags, body) {
  const out = Buffer.alloc(4 + body.length);
  out[0] = type;
  out[1] = flags;
  out.writeUInt16BE(body.length + 4, 2);
  body.copy(out, 4);
  const padded = Buffer.alloc(Math.ceil(out.length / 4) * 4);
  out.copy(padded);
  return padded;
}

function param(type, value) {
  const body = Buffer.alloc(4 + value.length);
  body.writeUInt16BE(type, 0);
  body.writeUInt16BE(value.length + 4, 2);
  value.copy(body, 4);
  const padded = Buffer.alloc(Math.ceil(body.length / 4) * 4);
  body.copy(padded);
  return padded;
}

function parseParams(data) {
  const out = [];
  let pos = 0;
  while (pos + 4 <= data.length) {
    const ty = data.readUInt16BE(pos);
    const len = data.readUInt16BE(pos + 2);
    if (len < 4 || pos + len > data.length) break;
    out.push([ty, data.subarray(pos + 4, pos + len)]);
    pos += Math.ceil(len / 4) * 4;
  }
  return out;
}

function parseChunks(data) {
  const out = [];
  let pos = 0;
  while (pos + 4 <= data.length) {
    const len = data.readUInt16BE(pos + 2);
    if (len < 4 || pos + len > data.length) break;
    out.push({ type: data[pos], flags: data[pos + 1], body: data.subarray(pos + 4, pos + len) });
    pos += Math.ceil(len / 4) * 4;
  }
  return out;
}

function reconfigResponseParam(seq, result) {
  const value = Buffer.alloc(8);
  value.writeUInt32BE(seq, 0);
  value.writeUInt32BE(result, 4);
  return param(SctpReconfig.RECONFIGURATION_RESPONSE, value);
}

function dataChunkBytes(c) {
  const body = Buffer.alloc(12 + c.payload.length);
  body.writeUInt32BE(c.tsn, 0);
  body.writeUInt16BE(c.stream, 4);
  body.writeUInt16BE(c.ssn, 6);
  body.writeUInt32BE(c.ppid, 8);
  c.payload.copy(body, 12);
  return chunk(SctpChunk.DATA, c.flags, body);
}

export class Association {
  constructor(isClient, localPort, peerPort) {
    this.isClient = isClient;
    this.localPort = localPort;
    this.peerPort = peerPort;
    this.myTag = (crypto.randomBytes(4).readUInt32BE(0) | 1) >>> 0;
    this.peerTag = 0;
    this.state = "closed";
    this.nextTsn = crypto.randomBytes(4).readUInt32BE(0);
    this.outCumDone = u32(this.nextTsn - 1);
    this.peerCumTsn = 0;
    this.peerReceived = new Set();
    this.outSsn = new Map();
    this.unacked = new Map();
    this.queued = [];
    this.outQueue = []; // chunk records awaiting cwnd/rwnd room
    this.inflightBytes = 0;
    this.peerRwnd = INITIAL_RWND;
    // Congestion window (RFC 9260 §6): without it a large
    // message bursts its fragments into kernel UDP buffers
    // faster than the peer drains them; the dropped tail then
    // recovers only at RTO granularity (1s per round).
    this.cwnd = INITIAL_CWND;
    this.ssthresh = Infinity;
    this.streamsIn = new Map();
    this.cookieSecret = crypto.randomBytes(32);
    this.pendingCookie = Buffer.alloc(0);
    this.lastInitMs = 0;
    this.lastPacketOutMs = 0;
    this.rtoMs = INITIAL_RTO_MS;
    this.missCounts = new Map();
    this.abandonedOrdered = [];
    // Stream reset (RFC 6525) bookkeeping.
    this.reconfSeq = this.nextTsn;
    this.resets = new Map(); // stream -> {outDone, inDone, reported}
    this.pendingReconf = []; // deferred {seq, lastTsn, streams}
    this.localResetSeqs = new Map(); // seq -> {stream, outgoing}
    this.outResetDone = new Set();
    this.peerInitialTsn = 0;
    this.lastPeerReconfSeq = null;
  }

  static newClient(localPort = SCTP_PORT, peerPort = SCTP_PORT) {
    return new Association(true, localPort, peerPort);
  }

  static newServer(localPort = SCTP_PORT, peerPort = SCTP_PORT) {
    return new Association(false, localPort, peerPort);
  }

  get isEstablished() {
    return this.state === "established";
  }

  #packet(vtag, chunks) {
    const out = Buffer.alloc(12 + chunks.length);
    out.writeUInt16BE(this.localPort, 0);
    out.writeUInt16BE(this.peerPort, 2);
    out.writeUInt32BE(vtag, 4);
    chunks.copy(out, 12);
    out.writeUInt32LE(crc32c(out), 8);
    return out;
  }

  #initBody() {
    const body = Buffer.alloc(16);
    body.writeUInt32BE(this.myTag, 0);
    body.writeUInt32BE(INITIAL_RWND, 4);
    body.writeUInt16BE(1024, 8);
    body.writeUInt16BE(1024, 10);
    body.writeUInt32BE(this.nextTsn, 12);
    return Buffer.concat([
      body,
      param(12, Buffer.from([0, 5, 0, 6])),
      param(SctpParam.FORWARD_TSN_SUPPORTED, Buffer.alloc(0)),
      // Supported Extensions: RE-CONFIG (130) and FORWARD-TSN (192),
      // mirroring what browsers advertise (82 c0).
      param(
        SctpParam.SUPPORTED_EXTENSIONS,
        Buffer.from([SctpChunk.RE_CONFIG, SctpChunk.FORWARD_TSN]),
      ),
    ]);
  }

  connect(nowMs) {
    this.state = "cookie-wait";
    this.lastInitMs = nowMs;
    return this.#packet(0, chunk(SctpChunk.INIT, 0, this.#initBody()));
  }

  #makeCookie(peerTag, peerTsn, myTsn) {
    const data = Buffer.alloc(16);
    data.writeUInt32BE(peerTag, 0);
    data.writeUInt32BE(this.myTag, 4);
    data.writeUInt32BE(peerTsn, 8);
    data.writeUInt32BE(myTsn, 12);
    const mac = crypto.createHmac("sha256", this.cookieSecret).update(data).digest();
    return Buffer.concat([data, mac.subarray(0, 16)]);
  }

  #checkCookie(cookie) {
    if (cookie.length !== 32) return null;
    const mac = crypto.createHmac("sha256", this.cookieSecret).update(cookie.subarray(0, 16)).digest();
    if (!mac.subarray(0, 16).equals(cookie.subarray(16))) return null;
    return [cookie.readUInt32BE(0), cookie.readUInt32BE(4), cookie.readUInt32BE(8), cookie.readUInt32BE(12)];
  }

  // Close one stream (RFC 8831 §6.4): reset our outgoing side
  // with an Outgoing SSN Reset Request. The peer resets its
  // outgoing side in turn; "stream-reset" fires once both
  // directions are done.
  closeStream(stream) {
    const packet = this.#initiateOutgoingReset(stream);
    return packet ? [packet] : [];
  }

  #responseSeqForOutgoing() {
    // Next expected peer request sequence minus 1 (RFC 6525 §4.1):
    // the last request sequence we received, or peer initial TSN-1.
    if (this.lastPeerReconfSeq !== null) return this.lastPeerReconfSeq;
    return u32(this.peerInitialTsn - 1);
  }

  #initiateOutgoingReset(stream) {
    if (this.state !== "established" || this.outResetDone.has(stream)) return null;
    this.outResetDone.add(stream);
    this.queued = this.queued.filter(([s]) => s !== stream);
    const seq = this.reconfSeq;
    this.reconfSeq = add32(this.reconfSeq, 1);
    this.localResetSeqs.set(seq, { stream, outgoing: true });
    this.#resetStateOf(stream);
    const value = Buffer.alloc(14);
    value.writeUInt32BE(seq, 0);
    value.writeUInt32BE(this.#responseSeqForOutgoing(), 4);
    value.writeUInt32BE(u32(this.nextTsn - 1), 8);
    value.writeUInt16BE(stream, 12);
    const params = param(SctpReconfig.OUTGOING_SSN_RESET_REQUEST, value);
    return this.#packet(this.peerTag, chunk(SctpChunk.RE_CONFIG, 0, params));
  }

  #resetStateOf(stream) {
    let st = this.resets.get(stream);
    if (!st) {
      st = { outDone: false, inDone: false, reported: false };
      this.resets.set(stream, st);
    }
    return st;
  }

  #maybeReportReset(stream, events) {
    const st = this.#resetStateOf(stream);
    if (st.outDone && st.inDone && !st.reported) {
      st.reported = true;
      events.push({ type: "stream-reset", stream });
    }
  }

  #resetIncomingSide(stream, packets, events) {
    const entry = this.streamsIn.get(stream);
    if (entry) {
      this.#drainStream(stream, events);
      entry.partials.clear();
      entry.completed.clear();
      entry.nextSsn = 0;
    }
    this.#resetStateOf(stream).inDone = true;
    this.#maybeReportReset(stream, events);
    // RFC 8831 §6.4: seeing the peer reset its outgoing side,
    // reset our corresponding outgoing side too.
    if (packets) {
      const packet = this.#initiateOutgoingReset(stream);
      if (packet) packets.push(packet);
    }
  }

  #resetOutgoingSide(stream, events) {
    this.outSsn.set(stream, 0);
    this.outResetDone.add(stream);
    this.queued = this.queued.filter(([s]) => s !== stream);
    for (const [tsn, c] of [...this.unacked]) {
      if (c.stream === stream) {
        this.inflightBytes -= c.payload.length;
        this.unacked.delete(tsn);
      }
    }
    this.inflightBytes = Math.max(0, this.inflightBytes);
    this.#resetStateOf(stream).outDone = true;
    this.#maybeReportReset(stream, events);
  }

  #processPendingResets(packets, events) {
    const remaining = [];
    for (const pending of this.pendingReconf) {
      if (diff32(this.peerCumTsn, pending.lastTsn) < 0) {
        remaining.push(pending);
        continue;
      }
      for (const stream of pending.streams) this.#resetIncomingSide(stream, packets, events);
      packets.push(
        this.#packet(this.peerTag, chunk(SctpChunk.RE_CONFIG, 0, reconfigResponseParam(pending.seq, 1))),
      );
    }
    this.pendingReconf = remaining;
  }

  #handleReconfig(body, packets, events) {
    let responses = Buffer.alloc(0);
    for (const [ty, value] of parseParams(body)) {
      if (ty === SctpReconfig.OUTGOING_SSN_RESET_REQUEST) {
        // Value: request seq, response seq, sender last assigned
        // TSN, then stream numbers (RFC 6525 §4.1).
        if (value.length < 12) continue;
        const seq = value.readUInt32BE(0);
        const responseSeq = value.readUInt32BE(4);
        const lastTsn = value.readUInt32BE(8);
        this.lastPeerReconfSeq = seq;
        // An Outgoing request can implicitly answer our Incoming
        // request whose sequence it echoes (§4.1 Response Seq).
        const implied = this.localResetSeqs.get(responseSeq);
        if (implied && !implied.outgoing) {
          this.localResetSeqs.delete(responseSeq);
          this.#resetStateOf(implied.stream).inDone = true;
          this.#maybeReportReset(implied.stream, events);
        }
        const streams = [];
        for (let pos = 12; pos + 2 <= value.length; pos += 2) streams.push(value.readUInt16BE(pos));
        // No stream list means all streams; datachannels always
        // list one, but handle the general case for known ones.
        const targets = streams.length ? streams : [...this.streamsIn.keys()];
        if (diff32(this.peerCumTsn, lastTsn) < 0) {
          // Wait until everything sent has arrived (RFC 6525 §5.2).
          this.pendingReconf.push({ seq, lastTsn, streams: targets });
          continue;
        }
        for (const stream of targets) this.#resetIncomingSide(stream, packets, events);
        responses = Buffer.concat([responses, reconfigResponseParam(seq, 1)]);
      } else if (ty === SctpReconfig.INCOMING_SSN_RESET_REQUEST) {
        if (value.length < 4) continue;
        const seq = value.readUInt32BE(0);
        this.lastPeerReconfSeq = seq;
        for (let pos = 4; pos + 2 <= value.length; pos += 2) {
          this.#resetOutgoingSide(value.readUInt16BE(pos), events);
        }
        responses = Buffer.concat([responses, reconfigResponseParam(seq, 1)]);
      } else if (ty === SctpReconfig.RECONFIGURATION_RESPONSE) {
        if (value.length < 8) continue;
        const seq = value.readUInt32BE(0);
        const result = value.readUInt32BE(4);
        const dir = this.localResetSeqs.get(seq);
        if (!dir) continue;
        this.localResetSeqs.delete(seq);
        if (result === 0 || result === 1) {
          const st = this.#resetStateOf(dir.stream);
          if (dir.outgoing) st.outDone = true;
          else st.inDone = true;
          this.#maybeReportReset(dir.stream, events);
        }
      } else if (value.length >= 4) {
        // SSN/TSN reset and Add-Streams: deny politely.
        responses = Buffer.concat([responses, reconfigResponseParam(value.readUInt32BE(0), 2)]);
      }
    }
    if (responses.length) {
      packets.push(this.#packet(this.peerTag, chunk(SctpChunk.RE_CONFIG, 0, responses)));
    }
  }

  sendData(stream, ppid, payload, opts = {}, nowMs = 0) {
    if (this.outResetDone.has(stream)) return []; // stream reset/closing
    const full = { unordered: false, maxRetransmits: null, maxLifetimeMs: null, ...opts };
    if (this.state !== "established") {
      // Not established yet: queue whole payloads; the packet
      // flush after COOKIE-ACK moves them into the chunk queue.
      this.queued.push([stream, ppid, Buffer.from(payload), full]);
      return [];
    }
    this.#enqueueChunks(stream, ppid, Buffer.from(payload), full, nowMs);
    return this.#flushOut(nowMs);
  }

  // Split a payload into TSN-ordered chunk records on outQueue.
  #enqueueChunks(stream, ppid, payload, opts, nowMs) {
    let ssn = 0;
    if (!opts.unordered) {
      ssn = this.outSsn.get(stream) ?? 0;
      this.outSsn.set(stream, (ssn + 1) & 0xffff);
    }
    const fragments = [];
    if (payload.length === 0) fragments.push(Buffer.alloc(0));
    for (let off = 0; off < payload.length; off += MAX_DATA_PAYLOAD) {
      fragments.push(payload.subarray(off, off + MAX_DATA_PAYLOAD));
    }
    fragments.forEach((frag, i) => {
      let flags = 0;
      if (opts.unordered) flags |= 0x04;
      if (i === 0) flags |= 0x02;
      if (i === fragments.length - 1) flags |= 0x01;
      const c = {
        tsn: this.nextTsn,
        stream,
        ssn,
        ppid,
        flags,
        payload: Buffer.from(frag),
        opts,
        retransmits: 0,
        bornMs: nowMs,
        lastSentMs: nowMs,
      };
      this.nextTsn = add32(this.nextTsn, 1);
      this.outQueue.push(c);
    });
  }

  // Emit queued chunks while cwnd and the peer rwnd allow.
  #flushOut(nowMs) {
    const packets = [];
    const limit = Math.min(this.cwnd, this.peerRwnd);
    if (SCTP_TRACE && this.outQueue.length && this.inflightBytes >= limit) {
      strace(
        `flush blocked queue=${this.outQueue.length} inflight=${this.inflightBytes} limit=${limit}`,
      );
    }
    while (this.outQueue.length && this.inflightBytes < limit) {
      const c = this.outQueue.shift();
      this.inflightBytes += c.payload.length;
      c.lastSentMs = nowMs;
      this.unacked.set(c.tsn, c);
      strace(`data out tsn=${c.tsn} stream=${c.stream} len=${c.payload.length}`);
      packets.push(this.#packet(this.peerTag, dataChunkBytes(c)));
    }
    if (packets.length) this.lastPacketOutMs = nowMs;
    return packets;
  }

  #flushQueue(nowMs) {
    while (this.queued.length) {
      const [stream, ppid, payload, opts] = this.queued.shift();
      this.#enqueueChunks(stream, ppid, payload, opts, nowMs);
    }
    return this.#flushOut(nowMs);
  }

  #sackPacket() {
    const gaps = [];
    const sorted = [...this.peerReceived].filter((t) => diff32(t, this.peerCumTsn) > 0)
      .sort((a, b) => diff32(a, b));
    let i = 0;
    while (i < sorted.length) {
      const start = sorted[i];
      let end = start;
      while (i + 1 < sorted.length && sorted[i + 1] === add32(end, 1)) {
        end = sorted[++i];
      }
      gaps.push([diff32(start, this.peerCumTsn) & 0xffff, diff32(end, this.peerCumTsn) & 0xffff]);
      i++;
    }
    const body = Buffer.alloc(12 + gaps.length * 4);
    body.writeUInt32BE(this.peerCumTsn, 0);
    body.writeUInt32BE(INITIAL_RWND, 4);
    body.writeUInt16BE(gaps.length, 8);
    body.writeUInt16BE(0, 10);
    gaps.forEach(([s, e], idx) => {
      body.writeUInt16BE(s, 12 + idx * 4);
      body.writeUInt16BE(e, 14 + idx * 4);
    });
    return this.#packet(this.peerTag, chunk(SctpChunk.SACK, 0, body));
  }

  handlePacket(packet, nowMs) {
    const packets = [];
    const events = [];
    if (packet.length < 12) return { packets, events };
    const check = Buffer.from(packet);
    check.writeUInt32LE(0, 8);
    if (crc32c(check) !== packet.readUInt32LE(8)) return { packets, events };
    const vtag = packet.readUInt32BE(4);
    for (const view of parseChunks(packet.subarray(12))) {
      switch (view.type) {
        case SctpChunk.INIT: {
          if (this.isClient || view.body.length < 16) break;
          const peerTag = view.body.readUInt32BE(0);
          const peerTsn = view.body.readUInt32BE(12);
          this.peerInitialTsn = peerTsn;
          const cookie = this.#makeCookie(peerTag, peerTsn, this.nextTsn);
          const body = Buffer.concat([this.#initBody(), param(7, cookie)]);
          packets.push(this.#packet(peerTag, chunk(SctpChunk.INIT_ACK, 0, body)));
          break;
        }
        case SctpChunk.INIT_ACK: {
          if (!this.isClient || this.state !== "cookie-wait" || view.body.length < 16) break;
          this.peerTag = view.body.readUInt32BE(0);
          this.peerInitialTsn = view.body.readUInt32BE(12);
          this.peerCumTsn = u32(view.body.readUInt32BE(12) - 1);
          for (const [ty, value] of parseParams(view.body.subarray(16))) {
            if (ty === 7) this.pendingCookie = Buffer.from(value);
          }
          this.state = "cookie-echoed";
          this.lastInitMs = nowMs;
          packets.push(this.#packet(this.peerTag, chunk(SctpChunk.COOKIE_ECHO, 0, this.pendingCookie)));
          break;
        }
        case SctpChunk.COOKIE_ECHO: {
          if (this.isClient) break;
          const parsed = this.#checkCookie(view.body);
          if (!parsed) break;
          const [peerTag, myTag, peerTsn, myTsn] = parsed;
          this.peerInitialTsn = peerTsn;
          this.peerTag = peerTag;
          this.myTag = myTag;
          this.peerCumTsn = u32(peerTsn - 1);
          this.nextTsn = myTsn;
          this.outCumDone = u32(myTsn - 1);
          this.state = "established";
          packets.push(this.#packet(this.peerTag, chunk(SctpChunk.COOKIE_ACK, 0, Buffer.alloc(0))));
          events.push({ type: "connected" });
          packets.push(...this.#flushQueue(nowMs));
          break;
        }
        case SctpChunk.COOKIE_ACK: {
          if (this.isClient && this.state === "cookie-echoed") {
            this.state = "established";
            events.push({ type: "connected" });
            packets.push(...this.#flushQueue(nowMs));
          }
          break;
        }
        case SctpChunk.DATA: {
          if (vtag !== this.myTag && this.state === "established") break;
          this.#handleData(view.flags, view.body, events);
          packets.push(this.#sackPacket());
          break;
        }
        case SctpChunk.SACK:
          packets.push(...this.#handleSack(view.body, nowMs));
          break;
        case SctpChunk.HEARTBEAT:
          packets.push(this.#packet(this.peerTag, chunk(SctpChunk.HEARTBEAT_ACK, 0, view.body)));
          break;
        case SctpChunk.RE_CONFIG:
          this.#handleReconfig(view.body, packets, events);
          break;
        case SctpChunk.FORWARD_TSN:
          this.#handleForwardTsn(view.body, events);
          packets.push(this.#sackPacket());
          break;
        case SctpChunk.SHUTDOWN:
          packets.push(this.#packet(this.peerTag, chunk(SctpChunk.SHUTDOWN_ACK, 0, Buffer.alloc(0))));
          this.state = "closed";
          events.push({ type: "closed" });
          break;
        case SctpChunk.SHUTDOWN_ACK:
          packets.push(this.#packet(this.peerTag, chunk(SctpChunk.SHUTDOWN_COMPLETE, 0, Buffer.alloc(0))));
          this.state = "closed";
          events.push({ type: "closed" });
          break;
        case SctpChunk.SHUTDOWN_COMPLETE:
        case SctpChunk.ABORT:
          this.state = "closed";
          events.push({ type: "closed" });
          break;
        default:
          break;
      }
    }
    // Cumulative TSN may have advanced: apply deferred resets.
    this.#processPendingResets(packets, events);
    return { packets, events };
  }

  #handleData(flags, body, events) {
    if (body.length < 12) return;
    const tsn = body.readUInt32BE(0);
    const stream = body.readUInt16BE(4);
    const ssn = body.readUInt16BE(6);
    const ppid = body.readUInt32BE(8);
    const payload = Buffer.from(body.subarray(12));
    const unordered = (flags & 0x04) !== 0;
    const isBegin = (flags & 0x02) !== 0;
    const isEnd = (flags & 0x01) !== 0;

    if (diff32(tsn, this.peerCumTsn) > 0) {
      this.peerReceived.add(tsn);
      while (this.peerReceived.has(add32(this.peerCumTsn, 1))) {
        this.peerCumTsn = add32(this.peerCumTsn, 1);
        this.peerReceived.delete(this.peerCumTsn);
      }
    }

    let entry = this.streamsIn.get(stream);
    if (!entry) {
      entry = { nextSsn: 0, partials: new Map(), completed: new Map() };
      this.streamsIn.set(stream, entry);
    }
    let key = tsn;
    if (!isBegin) {
      for (const [k, p] of entry.partials) {
        if (p.lastTsn !== null) continue; // already ended: new partial
        const maxTsn = Math.max(...p.parts.keys());
        if (add32(maxTsn, 1) === tsn) {
          key = k;
          break;
        }
      }
    }
    let partial = entry.partials.get(key);
    if (!partial) {
      partial = { ssn: 0, ppid: 0, unordered: false, parts: new Map(), firstTsn: null, lastTsn: null };
      entry.partials.set(key, partial);
    }
    if (isBegin) {
      partial.ssn = ssn;
      partial.ppid = ppid;
      partial.unordered = unordered;
      partial.firstTsn = tsn;
    }
    if (isEnd) partial.lastTsn = tsn;
    partial.parts.set(tsn, payload);

    // Fragments can arrive out of order (reordering on the
    // wire, or SACK-clocked sends interleaving with a burst):
    // a fragment that lands before its predecessor starts a
    // dangling partial. Merge any partials that have become
    // TSN-contiguous, or such messages can never complete.
    let merged = true;
    while (merged) {
      merged = false;
      for (const [k2, p2] of [...entry.partials]) {
        if (p2 === partial) continue;
        const maxOf = (p) => Math.max(...p.parts.keys());
        const minOf = (p) => Math.min(...p.parts.keys());
        // Never merge across a message boundary: a partial holding a
        // BEGIN fragment starts a new message, and one holding an END
        // fragment is already a whole message.
        if (add32(maxOf(partial), 1) === minOf(p2)) {
          if (p2.firstTsn !== null || partial.lastTsn !== null) continue;
          for (const [t, b] of p2.parts) partial.parts.set(t, b);
          if (p2.lastTsn !== null) partial.lastTsn = p2.lastTsn;
          entry.partials.delete(k2);
          merged = true;
        } else if (add32(maxOf(p2), 1) === minOf(partial)) {
          if (partial.firstTsn !== null || p2.lastTsn !== null) continue;
          for (const [t, b] of partial.parts) p2.parts.set(t, b);
          if (partial.lastTsn !== null) p2.lastTsn = partial.lastTsn;
          entry.partials.delete(key);
          partial = p2;
          key = k2;
          merged = true;
        }
      }
    }

    if (partial.firstTsn === null || partial.lastTsn === null) return;
    const count = diff32(partial.lastTsn, partial.firstTsn) + 1;
    if (partial.parts.size !== count) return;
    for (let i2 = 0; i2 < count; i2++) {
      if (!partial.parts.has(add32(partial.firstTsn, i2))) return;
    }
    entry.partials.delete(key);
    const parts = [];
    for (let i2 = 0; i2 < count; i2++) parts.push(partial.parts.get(add32(partial.firstTsn, i2)));
    const full = Buffer.concat(parts);
    if (partial.unordered) {
      events.push({ type: "data", stream, ppid: partial.ppid, payload: full });
    } else {
      entry.completed.set(partial.ssn, [partial.ppid, full]);
      this.#drainStream(stream, events);
    }
  }

  #drainStream(stream, events) {
    const entry = this.streamsIn.get(stream);
    while (entry.completed.has(entry.nextSsn)) {
      const [ppid, payload] = entry.completed.get(entry.nextSsn);
      entry.completed.delete(entry.nextSsn);
      entry.nextSsn = (entry.nextSsn + 1) & 0xffff;
      events.push({ type: "data", stream, ppid, payload });
    }
  }

  #handleForwardTsn(body, events) {
    if (body.length < 4) return;
    const newCum = body.readUInt32BE(0);
    if (diff32(newCum, this.peerCumTsn) > 0) {
      this.peerReceived = new Set([...this.peerReceived].filter((t) => diff32(t, newCum) > 0));
      this.peerCumTsn = newCum;
    }
    for (let pos = 4; pos + 4 <= body.length; pos += 4) {
      const stream = body.readUInt16BE(pos);
      const ssn = body.readUInt16BE(pos + 2);
      let entry = this.streamsIn.get(stream);
      if (!entry) {
        entry = { nextSsn: 0, partials: new Map(), completed: new Map() };
        this.streamsIn.set(stream, entry);
      }
      for (const s of [...entry.completed.keys()]) {
        if (s <= ssn) entry.completed.delete(s);
      }
      if (entry.nextSsn <= ssn) entry.nextSsn = (ssn + 1) & 0xffff;
      for (const [k, p] of [...entry.partials]) {
        if (!p.unordered && p.ssn === ssn) entry.partials.delete(k);
      }
      this.#drainStream(stream, events);
    }
  }

  #handleSack(body, nowMs) {
    const packets = [];
    if (body.length < 12) return packets;
    const cum = body.readUInt32BE(0);
    this.peerRwnd = body.readUInt32BE(4);
    const numGaps = body.readUInt16BE(8);
    const gapRanges = [];
    for (let i2 = 0, pos = 12; i2 < numGaps && pos + 4 <= body.length; i2++, pos += 4) {
      const s = body.readUInt16BE(pos);
      const e = body.readUInt16BE(pos + 2);
      gapRanges.push([add32(cum, s), add32(cum, e)]);
    }
    strace(
      `sack cum=${cum} gaps=${JSON.stringify(gapRanges)} unacked=${this.unacked.size} queue=${this.outQueue.length}`,
    );
    let freed = 0;
    for (const tsn of [...this.unacked.keys()]) {
      const inGap = gapRanges.some(([s, e]) => diff32(tsn, s) >= 0 && diff32(tsn, e) <= 0);
      if (diff32(tsn, cum) <= 0 || inGap) {
        freed += this.unacked.get(tsn).payload.length;
        this.unacked.delete(tsn);
        this.missCounts.delete(tsn);
      }
    }
    this.inflightBytes = Math.max(0, this.inflightBytes - freed);
    if (freed > 0) {
      // RFC 9260 §6.2: slow start grows cwnd by up to one MTU
      // per SACK; congestion avoidance by ~MTU per RTT.
      if (this.cwnd < this.ssthresh) {
        this.cwnd += Math.min(freed, MAX_DATA_PAYLOAD);
      } else {
        this.cwnd += Math.max(1, Math.floor((MAX_DATA_PAYLOAD * MAX_DATA_PAYLOAD) / this.cwnd));
      }
    }
    this.#advanceOutCum();
    if (gapRanges.length) {
      const firstStart = gapRanges[0][0];
      for (const tsn of [...this.unacked.keys()]) {
        if (diff32(tsn, cum) > 0 && diff32(tsn, firstStart) < 0) {
          const count = (this.missCounts.get(tsn) ?? 0) + 1;
          this.missCounts.set(tsn, count);
          if (count >= 3) {
            const c = this.unacked.get(tsn);
            this.missCounts.delete(tsn);
            packets.push(this.#packet(this.peerTag, dataChunkBytes(c)));
            c.retransmits += 1;
            c.lastSentMs = nowMs;
          }
        }
      }
    }
    packets.push(...this.#flushQueue(nowMs));
    return packets;
  }

  #advanceOutCum() {
    for (;;) {
      const next = add32(this.outCumDone, 1);
      if (next === this.nextTsn || this.unacked.has(next)) break;
      this.outCumDone = next;
    }
  }

  tick(nowMs) {
    const packets = [];
    const events = [];
    if (
      (this.state === "cookie-wait" || this.state === "cookie-echoed") &&
      nowMs - this.lastInitMs >= this.rtoMs
    ) {
      this.lastInitMs = nowMs;
      if (this.state === "cookie-wait") {
        packets.push(this.#packet(0, chunk(SctpChunk.INIT, 0, this.#initBody())));
      } else {
        packets.push(this.#packet(this.peerTag, chunk(SctpChunk.COOKIE_ECHO, 0, this.pendingCookie)));
      }
    }
    if (this.state === "established") {
      let abandonedAny = false;
      const toRetransmit = [];
      for (const c of [...this.unacked.values()]) {
        const expired = nowMs - c.lastSentMs >= this.rtoMs;
        const lifetimeOut = c.opts.maxLifetimeMs !== null && nowMs - c.bornMs > c.opts.maxLifetimeMs;
        const budgetOut = expired && c.opts.maxRetransmits !== null && c.retransmits >= c.opts.maxRetransmits;
        if (lifetimeOut || budgetOut) {
          this.unacked.delete(c.tsn);
          this.inflightBytes = Math.max(0, this.inflightBytes - c.payload.length);
          if (!c.opts.unordered) this.abandonedOrdered.push([c.stream, c.ssn]);
          abandonedAny = true;
        } else if (expired) {
          toRetransmit.push(c);
        }
      }
      if (abandonedAny) {
        this.#advanceOutCum();
        const parts = [Buffer.from([(this.outCumDone >>> 24) & 0xff, (this.outCumDone >>> 16) & 0xff, (this.outCumDone >>> 8) & 0xff, this.outCumDone & 0xff])];
        for (const [stream, ssn] of this.abandonedOrdered.splice(0)) {
          const b = Buffer.alloc(4);
          b.writeUInt16BE(stream, 0);
          b.writeUInt16BE(ssn, 2);
          parts.push(b);
        }
        packets.push(this.#packet(this.peerTag, chunk(SctpChunk.FORWARD_TSN, 0, Buffer.concat(parts))));
      }
      if (toRetransmit.length) {
        // RFC 9260 §6.2: a retransmit timeout collapses cwnd.
        this.ssthresh = Math.max(this.cwnd / 2, 4 * MAX_DATA_PAYLOAD);
        this.cwnd = MAX_DATA_PAYLOAD;
      }
      for (const c of toRetransmit) {
        strace(`rexmit tsn=${c.tsn} stream=${c.stream} len=${c.payload.length}`);
        packets.push(this.#packet(this.peerTag, dataChunkBytes(c)));
        c.retransmits += 1;
        c.lastSentMs = nowMs;
      }
      packets.push(...this.#flushOut(nowMs));
      if (nowMs - this.lastPacketOutMs >= 30000) {
        this.lastPacketOutMs = nowMs;
        const info = Buffer.alloc(8);
        info.writeBigUInt64BE(BigInt(nowMs), 0);
        packets.push(this.#packet(this.peerTag, chunk(SctpChunk.HEARTBEAT, 0, param(1, info))));
      }
    }
    return { packets, events };
  }

  close(nowMs) {
    void nowMs;
    if (this.state !== "established") return [];
    this.state = "shutdown-sent";
    const body = Buffer.alloc(4);
    body.writeUInt32BE(this.peerCumTsn, 0);
    return [this.#packet(this.peerTag, chunk(SctpChunk.SHUTDOWN, 0, body))];
  }
}
