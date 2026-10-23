// DTLS 1.2 (RFC 6347) client and server — Node builtins only.
// ECDHE-ECDSA with AES-128-GCM-SHA256, extended master secret,
// use_srtp negotiation, certificates pinned by SDP fingerprint.
// Mirrors the Rust implementation (webrtc/rust/src/dtls.rs) flight for
// flight; cross-tested against it and against OpenSSL.

import crypto from "node:crypto";
import { DtlsContentType, DtlsExtension, DtlsHandshakeType } from "./proto_gen.js";
import { Certificate, fingerprintOfDer, parsePublicKey, pointToPublicKey, publicKeyPoint } from "./x509.js";

const DTLS_1_2 = Buffer.from([0xfe, 0xfd]);
const SUITE = 0xc02b;
const GROUP_SECP256R1 = 23;

export function sha256(data) {
  return crypto.createHash("sha256").update(data).digest();
}

function hmacSha256(key, ...parts) {
  const h = crypto.createHmac("sha256", key);
  for (const p of parts) h.update(p);
  return h.digest();
}

export function prf(secret, label, seed, outLen) {
  const fullSeed = Buffer.concat([Buffer.from(label, "ascii"), seed]);
  const out = [];
  let a = hmacSha256(secret, fullSeed);
  let produced = 0;
  while (produced < outLen) {
    const chunk = hmacSha256(secret, a, fullSeed);
    out.push(chunk);
    produced += chunk.length;
    a = hmacSha256(secret, a);
  }
  return Buffer.concat(out).subarray(0, outLen);
}

/** Packet IO over a connected dgram socket. */
export function udpPacketIo(socket, peer) {
  const queue = [];
  const waiters = [];
  socket.on("message", (msg) => {
    const waiter = waiters.shift();
    if (waiter) waiter(msg);
    else queue.push(msg);
  });
  return {
    send(buf) {
      return new Promise((resolve, reject) => {
        socket.send(buf, peer.port, peer.address, (e) => (e ? reject(e) : resolve()));
      });
    },
    recv(timeoutMs) {
      if (queue.length) return Promise.resolve(queue.shift());
      return new Promise((resolve) => {
        const waiter = (msg) => {
          clearTimeout(timer);
          resolve(msg);
        };
        const timer = setTimeout(() => {
          const i = waiters.indexOf(waiter);
          if (i >= 0) waiters.splice(i, 1);
          resolve(null);
        }, timeoutMs);
        waiters.push(waiter);
      });
    },
  };
}

export class Reader {
  constructor(buf) {
    this.buf = buf;
    this.pos = 0;
  }
  u8() {
    if (this.pos >= this.buf.length) throw new Error("short read");
    return this.buf[this.pos++];
  }
  u16() {
    return (this.u8() << 8) | this.u8();
  }
  u24() {
    return (this.u8() << 16) | (this.u8() << 8) | this.u8();
  }
  take(n) {
    if (this.pos + n > this.buf.length) throw new Error("short read");
    const out = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }
  vec8() {
    return this.take(this.u8());
  }
  vec16() {
    return this.take(this.u16());
  }
  vec24() {
    return this.take(this.u24());
  }
  done() {
    return this.pos >= this.buf.length;
  }
}

function u24be(v) {
  return Buffer.from([(v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
}

function handshakeMessage(type, seq, body) {
  return Buffer.concat([
    Buffer.from([type]),
    u24be(body.length),
    Buffer.from([(seq >> 8) & 0xff, seq & 0xff]),
    u24be(0),
    u24be(body.length),
    body,
  ]);
}

function certListBody(der) {
  const entry = Buffer.concat([u24be(der.length), der]);
  return Buffer.concat([u24be(entry.length), entry]);
}

function parseFirstCert(body) {
  const r = new Reader(body);
  const list = r.vec24();
  return Buffer.from(new Reader(list).vec24());
}

class Hs {
  constructor() {
    this.sendSeq = 0;
    this.expectSeq = 0;
    this.fragments = new Map();
    this.ready = new Map();
    this.byteBuf = Buffer.alloc(0);
    this.transcript = [];
    this.ccsReceived = false;
    this.pending = [];
  }
  feed(bytes) {
    this.byteBuf = Buffer.concat([this.byteBuf, bytes]);
    for (;;) {
      if (this.byteBuf.length < 12) return;
      const type = this.byteBuf[0];
      const total = this.byteBuf.readUIntBE(1, 3);
      const seq = this.byteBuf.readUInt16BE(4);
      const offset = this.byteBuf.readUIntBE(6, 3);
      const fragLen = this.byteBuf.readUIntBE(9, 3);
      if (this.byteBuf.length < 12 + fragLen) return;
      const frag = this.byteBuf.subarray(12, 12 + fragLen);
      this.byteBuf = this.byteBuf.subarray(12 + fragLen);
      const key = `${type}:${seq}`;
      let entry = this.fragments.get(key);
      if (!entry) {
        entry = { total, buf: Buffer.alloc(total), have: new Uint8Array(total) };
        this.fragments.set(key, entry);
      }
      frag.copy(entry.buf, offset);
      entry.have.fill(1, offset, offset + frag.length);
      if (entry.have.every((h) => h === 1)) {
        this.fragments.delete(key);
        const raw = handshakeMessage(type, seq, entry.buf);
        this.ready.set(seq, { type, raw, body: Buffer.from(entry.buf) });
      }
    }
  }
  next() {
    const msg = this.ready.get(this.expectSeq);
    if (!msg) return null;
    this.ready.delete(this.expectSeq);
    this.expectSeq++;
    return msg;
  }
  hash() {
    return sha256(Buffer.concat(this.transcript));
  }
  bytes() {
    return Buffer.concat(this.transcript);
  }
}

export class DtlsConnection {
  #io;
  #role;
  // sendCid is the peer's announced connection id (RFC 9146),
  // stamped on every record we emit (and inside its AAD).
  #sendCid = null;
  // recvCid is our announced connection id; armed before the
  // first handshake pump so the parser recognizes cid-stamped
  // records from the peer's first flight onward. Peers that
  // ignore the extension keep the plain layout; accepted too.
  #recvCid = null;
  #writeKeys = null;
  #readKeys = null;
  #writeSeq = 0;
  #epoch0Seq = 0;
  #masterSecret = null;
  #clientRandom;
  #serverRandom;
  #peerCertificate = null;
  #srtpProfile = null;
  #readHighest = -1;
  #readWindow = 0n;

  constructor(io, role) {
    this.#io = io;
    this.#role = role;
  }

  peerFingerprint() {
    return this.#peerCertificate ? fingerprintOfDer(this.#peerCertificate) : null;
  }

  get srtpProfile() {
    return this.#srtpProfile;
  }

  exportKeyingMaterial(label, context, len) {
    return prf(
      this.#masterSecret,
      label,
      Buffer.concat([this.#clientRandom, this.#serverRandom, context]),
      len,
    );
  }

  #sendRecord(contentType, epoch, body) {
    const seq48 = (seq) => {
      const b = Buffer.alloc(6);
      b.writeUIntBE(seq, 0, 6);
      return b;
    };
    const cid = this.#sendCid ?? Buffer.alloc(0);
    let packet;
    if (epoch === 0) {
      const seq = this.#epoch0Seq++;
      packet = Buffer.concat([
        Buffer.from([contentType]),
        DTLS_1_2,
        Buffer.from([0, 0]),
        seq48(seq),
        cid,
        Buffer.from([(body.length >> 8) & 0xff, body.length & 0xff]),
        body,
      ]);
    } else {
      const keys = this.#writeKeys;
      const seq = this.#writeSeq++;
      const explicit = Buffer.alloc(8);
      explicit.writeUInt16BE(1, 0);
      explicit.writeUIntBE(seq, 2, 6);
      const nonce = Buffer.concat([keys.salt, explicit]);
      const aad = Buffer.concat([
        explicit,
        cid,
        Buffer.from([contentType]),
        DTLS_1_2,
        Buffer.from([(body.length >> 8) & 0xff, body.length & 0xff]),
      ]);
      const cipher = crypto.createCipheriv("aes-128-gcm", keys.key, nonce, {
        authTagLength: 16,
      });
      cipher.setAAD(aad);
      const ciphertext = Buffer.concat([cipher.update(body), cipher.final()]);
      const tag = cipher.getAuthTag();
      packet = Buffer.concat([
        Buffer.from([contentType]),
        DTLS_1_2,
        Buffer.from([0, 1]),
        seq48(seq),
        cid,
        (() => {
          const len = 8 + ciphertext.length + 16;
          return Buffer.from([(len >> 8) & 0xff, len & 0xff]);
        })(),
        explicit,
        ciphertext,
        tag,
      ]);
    }
    return this.#io.send(packet).then(() => packet);
  }

  #parseRecords(packet) {
    const records = [];
    let offset = 0;
    while (offset < packet.length) {
      const r = new Reader(packet.subarray(offset));
      const contentType = r.u8();
      r.u8();
      r.u8();
      const epoch = r.u16();
      const seqBytes = r.take(6);
      const sequence = seqBytes.readUIntBE(0, 6);
      // RFC 9146: when we announced a connection id, honoring
      // peers carry it between the sequence and the length
      // (and inside the AAD). Peers that ignore the extension
      // (browsers) keep the plain layout; accept both.
      let cid = Buffer.alloc(0);
      if (
        this.#recvCid?.length &&
        r.pos + this.#recvCid.length <= packet.length - offset &&
        packet.subarray(offset + r.pos, offset + r.pos + this.#recvCid.length).equals(this.#recvCid)
      ) {
        cid = this.#recvCid;
        r.take(cid.length);
      }
      const len = r.u16();
      const body = Buffer.from(r.take(len));
      offset += r.pos;
      if (epoch === 0) {
        records.push({ contentType, epoch, sequence, body });
        continue;
      }
      if (!this.#readKeys) {
        // A coalesced flight may place an epoch-1 record (the
        // Finished) in the same datagram as the epoch-0 records
        // that establish the keys. Carry what parsed so far on the
        // error and let the caller defer the rest of the datagram.
        const err = new Error("epoch-1 records await handshake keys");
        err.records = records;
        err.keysPending = true;
        throw err;
      }
      if (body.length < 24) throw new Error("short epoch-1 record");
      const explicit = body.subarray(0, 8);
      const ciphertext = body.subarray(8, body.length - 16);
      const tag = body.subarray(body.length - 16);
      const nonce = Buffer.concat([this.#readKeys.salt, explicit]);
      // AAD: record header epoch||sequence, not the explicit nonce.
      const headerSeq = Buffer.alloc(8);
      headerSeq.writeUInt16BE(epoch, 0);
      headerSeq.writeUIntBE(sequence, 2, 6);
      const aad = Buffer.concat([
        headerSeq,
        cid,
        Buffer.from([contentType]),
        DTLS_1_2,
        Buffer.from([(ciphertext.length >> 8) & 0xff, ciphertext.length & 0xff]),
      ]);
      const decipher = crypto.createDecipheriv("aes-128-gcm", this.#readKeys.key, nonce, {
        authTagLength: 16,
      });
      decipher.setAAD(aad);
      decipher.setAuthTag(tag);
      let plaintext;
      try {
        plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
      } catch {
        throw new Error("record authentication failed");
      }
      // replay window (64)
      if (this.#readHighest < 0) {
        this.#readHighest = sequence;
        this.#readWindow = 1n;
      } else if (sequence > this.#readHighest) {
        const shift = BigInt(Math.min(64, sequence - this.#readHighest));
        this.#readWindow = shift >= 64n ? 1n : (this.#readWindow << shift) | 1n;
        this.#readHighest = sequence;
      } else {
        const diff = this.#readHighest - sequence;
        if (diff >= 64 || ((this.#readWindow >> BigInt(diff)) & 1n) === 1n) {
          throw new Error("replayed record");
        }
        this.#readWindow |= 1n << BigInt(diff);
      }
      records.push({ contentType, epoch, sequence, body: plaintext });
    }
    return records;
  }

  async #sendHs(hs, type, body, epoch) {
    const raw = handshakeMessage(type, hs.sendSeq, body);
    hs.sendSeq++;
    const packet = await this.#sendRecord(DtlsContentType.HANDSHAKE, epoch, raw);
    hs.transcript.push(raw);
    return packet;
  }

  async #pumpUntilMessage(hs, flight) {
    let retries = 0;
    for (;;) {
      const msg = hs.next();
      if (msg) return msg;
      // retry deferred packets now that keys may exist
      let progressed = false;
      for (let i = 0; i < hs.pending.length; ) {
        let records = [];
        try {
          records = this.#parseRecords(hs.pending[i]);
          hs.pending.splice(i, 1);
          progressed = true;
        } catch (e) {
          // Deferred (or undecodable): keep the datagram for a
          // later pass; the reassembly layer dedupes records that
          // get fed twice.
          records = e.records ?? [];
          i++;
        }
        for (const record of records) {
          if (record.contentType === DtlsContentType.HANDSHAKE) hs.feed(record.body);
          else if (record.contentType === DtlsContentType.CHANGE_CIPHER_SPEC) {
            hs.ccsReceived = true;
          }
        }
      }
      if (progressed) continue;
      const packet = await this.#io.recv(1000);
      if (packet === null) {
        if (++retries > 6) throw new Error("handshake timed out");
        for (const p of flight) await this.#io.send(p);
        continue;
      }
      let records = [];
      let parseErr = null;
      try {
        records = this.#parseRecords(packet);
      } catch (e) {
        records = e.records ?? [];
        parseErr = e;
      }
      for (const record of records) {
        if (record.contentType === DtlsContentType.HANDSHAKE) hs.feed(record.body);
        else if (record.contentType === DtlsContentType.CHANGE_CIPHER_SPEC) {
          hs.ccsReceived = true;
        } else if (record.contentType === DtlsContentType.ALERT) {
          throw new Error("fatal alert from peer during handshake");
        }
      }
      if (parseErr) {
        if (parseErr.keysPending || !this.#readKeys) {
          hs.pending.push(packet);
          continue;
        }
        throw parseErr;
      }
    }
  }

  #deriveKeys(master) {
    const block = prf(master, "key expansion", Buffer.concat([this.#serverRandom, this.#clientRandom]), 40);
    const clientKeys = { key: block.subarray(0, 16), salt: block.subarray(32, 36) };
    const serverKeys = { key: block.subarray(16, 32), salt: block.subarray(36, 40) };
    if (this.#role === "client") {
      this.#writeKeys = clientKeys;
      this.#readKeys = serverKeys;
    } else {
      this.#writeKeys = serverKeys;
      this.#readKeys = clientKeys;
    }
  }

  #checkFingerprint(expected) {
    if (!expected) return;
    const actual = this.peerFingerprint();
    if (!actual || actual.toUpperCase() !== expected.toUpperCase()) {
      throw new Error("peer certificate fingerprint mismatch");
    }
  }

  async sendApp(data) {
    await this.#sendRecord(DtlsContentType.APPLICATION_DATA, 1, Buffer.from(data));
  }

  /** Returns null on timeout instead of throwing. */
  async recvAppTimeout(timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) return null;
      const packet = await this.#io.recv(remaining);
      if (packet === null) return null;
      for (const record of this.#parseRecords(packet)) {
        if (record.contentType === DtlsContentType.APPLICATION_DATA) return record.body;
        if (record.contentType === DtlsContentType.ALERT) throw new Error("alert from peer");
      }
    }
  }

  async recvApp(timeoutMs = 60000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error("timed out waiting for application data");
      const packet = await this.#io.recv(remaining);
      if (packet === null) throw new Error("timed out waiting for application data");
      for (const record of this.#parseRecords(packet)) {
        if (record.contentType === DtlsContentType.APPLICATION_DATA) return record.body;
        if (record.contentType === DtlsContentType.ALERT) throw new Error("alert from peer");
      }
    }
  }

  // -- handshakes -------------------------------------------------------------

  static async connect(io, config) {
    const conn = new DtlsConnection(io, "client");
    // Arm the receive cid before the first pump: a server
    // honoring our announced cid stamps it from its first
    // flight onward, so the record parser must recognize it
    // before ServerHello (mirrors accept()).
    conn.#recvCid = config.connectionId ? Buffer.from(config.connectionId) : null;
    const hs = new Hs();
    conn.#clientRandom = crypto.randomBytes(32);
    const cert = config.certificate;

    let cookie = Buffer.alloc(0);
    let flight = [];
    let serverHello = null;
    cookieLoop: for (;;) {
      hs.transcript = [];
      hs.sendSeq = 0;
      hs.expectSeq = 0;
      const body = clientHelloBody(
        conn.#clientRandom,
        cookie,
        config.connectionId ? Buffer.from(config.connectionId) : null,
        config.pairHint ? Buffer.from(config.pairHint) : null,
      );
      const packet = await conn.#sendHs(hs, DtlsHandshakeType.CLIENT_HELLO, body, 0);
      flight = [packet];
      for (;;) {
        const msg = await conn.#pumpUntilMessage(hs, flight);
        if (msg.type === DtlsHandshakeType.HELLO_VERIFY_REQUEST) {
          const r = new Reader(msg.body);
          r.u8();
          r.u8();
          cookie = Buffer.from(r.vec8());
          continue cookieLoop;
        }
        if (msg.type === DtlsHandshakeType.SERVER_HELLO) {
          serverHello = parseServerHello(msg.body);
          hs.transcript.push(msg.raw);
          break cookieLoop;
        }
        throw new Error("unexpected message before ServerHello");
      }
    }
    conn.#serverRandom = serverHello.serverRandom;
    conn.#srtpProfile = serverHello.srtpProfile;
    conn.#sendCid = serverHello.peerCid;

    let peerEphemeral = null;
    let skeParams = null;
    let skeSignature = null;
    let certRequested = false;
    for (;;) {
      const msg = await conn.#pumpUntilMessage(hs, flight);
      hs.transcript.push(msg.raw);
      if (msg.type === DtlsHandshakeType.CERTIFICATE) {
        conn.#peerCertificate = parseFirstCert(msg.body);
      } else if (msg.type === DtlsHandshakeType.SERVER_KEY_EXCHANGE) {
        const r = new Reader(msg.body);
        const start = r.pos;
        const curveType = r.u8();
        const group = r.u16();
        if (curveType !== 3 || group !== GROUP_SECP256R1) {
          throw new Error("server picked an unsupported ECDHE group");
        }
        const point = r.vec8();
        skeParams = Buffer.from(msg.body.subarray(start, r.pos));
        r.u16();
        skeSignature = Buffer.from(r.vec16());
        peerEphemeral = pointToPublicKey(Buffer.from(point));
      } else if (msg.type === DtlsHandshakeType.CERTIFICATE_REQUEST) {
        certRequested = true;
      } else if (msg.type === DtlsHandshakeType.SERVER_HELLO_DONE) {
        break;
      } else {
        throw new Error("unexpected message in server flight");
      }
    }
    if (!conn.#peerCertificate) throw new Error("server sent no certificate");
    const peerCertKey = parsePublicKey(conn.#peerCertificate);
    {
      // TLS signs the raw bytes with the negotiated hash (no pre-hashing:
      // Node's sign(null, digest) would hash the digest a second time).
      const signed = Buffer.concat([conn.#clientRandom, conn.#serverRandom, skeParams]);
      const ok = crypto.verify("sha256", signed, { key: peerCertKey, dsaEncoding: "der" }, skeSignature);
      if (!ok) throw new Error("ServerKeyExchange signature invalid");
    }
    conn.#checkFingerprint(config.expectedPeerFingerprint);

    const ecdh = crypto.createECDH("prime256v1");
    const ephPublicPoint = ecdh.generateKeys(null, "uncompressed");
    const peerPoint = publicKeyPoint(peerEphemeral);
    const premaster = ecdh.computeSecret(peerPoint);

    const outFlight = [];
    if (certRequested) {
      outFlight.push(await conn.#sendHs(hs, DtlsHandshakeType.CERTIFICATE, certListBody(cert.der), 0));
    }
    outFlight.push(
      await conn.#sendHs(
        hs,
        DtlsHandshakeType.CLIENT_KEY_EXCHANGE,
        Buffer.concat([Buffer.from([ephPublicPoint.length]), ephPublicPoint]),
        0,
      ),
    );
    const sessionHash = hs.hash();
    conn.#masterSecret = serverHello.ems
      ? prf(premaster, "extended master secret", sessionHash, 48)
      : prf(premaster, "master secret", Buffer.concat([conn.#clientRandom, conn.#serverRandom]), 48);
    conn.#deriveKeys(conn.#masterSecret);

    if (certRequested) {
      const der = crypto.sign("sha256", hs.bytes(), { key: cert.privateKey, dsaEncoding: "der" });
      const cvBody = Buffer.concat([
        Buffer.from([0x04, 0x03]),
        Buffer.from([(der.length >> 8) & 0xff, der.length & 0xff]),
        der,
      ]);
      outFlight.push(await conn.#sendHs(hs, DtlsHandshakeType.CERTIFICATE_VERIFY, cvBody, 0));
    }
    outFlight.push(await conn.#sendRecord(DtlsContentType.CHANGE_CIPHER_SPEC, 0, Buffer.from([1])));
    const verifyData = prf(conn.#masterSecret, "client finished", hs.hash(), 12);
    outFlight.push(await conn.#sendHs(hs, DtlsHandshakeType.FINISHED, verifyData, 1));
    flight = outFlight;

    for (;;) {
      const msg = await conn.#pumpUntilMessage(hs, flight);
      if (msg.type === DtlsHandshakeType.FINISHED) {
        const expected = prf(conn.#masterSecret, "server finished", hs.hash(), 12);
        if (!msg.body.equals(expected)) throw new Error("server Finished verification failed");
        hs.transcript.push(msg.raw);
        break;
      }
      hs.transcript.push(msg.raw);
    }
    return conn;
  }

  static async accept(io, config) {
    const conn = new DtlsConnection(io, "server");
    conn.#recvCid = config.connectionId ? Buffer.from(config.connectionId) : null;
    const hs = new Hs();
    const cert = config.certificate;

    const first = await conn.#pumpUntilMessage(hs, []);
    hs.transcript.push(first.raw);
    if (first.type !== DtlsHandshakeType.CLIENT_HELLO) {
      throw new Error("expected ClientHello");
    }
    let clientEms = false;
    let clientSrtp = [];
    {
      const r = new Reader(first.body);
      r.u8();
      r.u8();
      conn.#clientRandom = Buffer.from(r.take(32));
      r.vec8();
      r.vec8();
      const suites = r.vec16();
      let suiteOk = false;
      for (let i = 0; i + 1 < suites.length; i += 2) {
        if (suites.readUInt16BE(i) === SUITE) suiteOk = true;
      }
      if (!suiteOk) throw new Error("client does not offer the required cipher suite");
      r.vec8();
      if (!r.done()) {
        const exts = r.vec16();
        const er = new Reader(exts);
        while (!er.done()) {
          const ty = er.u16();
          const data = er.vec16();
          if (ty === 23) clientEms = true;
          else if (ty === DtlsExtension.CONNECTION_ID) {
            const cr = new Reader(data);
            try {
              conn.#sendCid = Buffer.from(cr.vec8());
            } catch {
              /* malformed cid ext: ignore */
            }
          } else if (ty === 14) {
            const sr = new Reader(data);
            const list = sr.vec16();
            for (let i = 0; i + 1 < list.length; i += 2) {
              clientSrtp.push(list.readUInt16BE(i));
            }
          }
        }
      }
    }
    const srtpProfile = [0x0007, 0x0001, 0x0002, 0x0008].find((p) => clientSrtp.includes(p)) ?? null;
    conn.#srtpProfile = srtpProfile;
    conn.#serverRandom = crypto.randomBytes(32);

    const flight = [];
    {
      const exts = [];
      if (srtpProfile !== null) {
        const data = Buffer.from([0, 2, (srtpProfile >> 8) & 0xff, srtpProfile & 0xff, 0]);
        exts.push(Buffer.from([0, 14, 0, data.length]), data);
      }
      if (clientEms) exts.push(Buffer.from([0, 23, 0, 0]));
      // Announce our connection id (RFC 9146) so the client
      // stamps it on records it sends us.
      if (config.connectionId) {
        const peerCid = Buffer.from(config.connectionId);
        const ty = Buffer.alloc(2);
        ty.writeUInt16BE(DtlsExtension.CONNECTION_ID, 0);
        const data = Buffer.concat([Buffer.from([peerCid.length]), peerCid]);
        const len = Buffer.alloc(2);
        len.writeUInt16BE(data.length, 0);
        exts.push(ty, len, data);
      }
      exts.push(Buffer.from([0xff, 0x01, 0, 1, 0]));
      const extBytes = Buffer.concat(exts);
      const sh = Buffer.concat([
        DTLS_1_2,
        conn.#serverRandom,
        Buffer.from([0]),
        Buffer.from([0xc0, 0x2b]),
        Buffer.from([0]),
        Buffer.from([(extBytes.length >> 8) & 0xff, extBytes.length & 0xff]),
        extBytes,
      ]);
      flight.push(await conn.#sendHs(hs, DtlsHandshakeType.SERVER_HELLO, sh, 0));
    }
    flight.push(await conn.#sendHs(hs, DtlsHandshakeType.CERTIFICATE, certListBody(cert.der), 0));
    const ecdh = crypto.createECDH("prime256v1");
    const ephPublicPoint = ecdh.generateKeys(null, "uncompressed");
    {
      const params = Buffer.concat([
        Buffer.from([3, 0, GROUP_SECP256R1]),
        Buffer.from([ephPublicPoint.length]),
        ephPublicPoint,
      ]);
      const signed = Buffer.concat([conn.#clientRandom, conn.#serverRandom, params]);
      const der = crypto.sign("sha256", signed, { key: cert.privateKey, dsaEncoding: "der" });
      const ske = Buffer.concat([
        params,
        Buffer.from([0x04, 0x03, (der.length >> 8) & 0xff, der.length & 0xff]),
        der,
      ]);
      flight.push(await conn.#sendHs(hs, DtlsHandshakeType.SERVER_KEY_EXCHANGE, ske, 0));
    }
    {
      const pairs = Buffer.from([0x04, 0x03, 0x05, 0x03, 0x06, 0x03, 0x04, 0x01, 0x05, 0x01, 0x06, 0x01]);
      const cr = Buffer.concat([
        Buffer.from([1, 64]),
        Buffer.from([(pairs.length >> 8) & 0xff, pairs.length & 0xff]),
        pairs,
        Buffer.from([0, 0]),
      ]);
      flight.push(await conn.#sendHs(hs, DtlsHandshakeType.CERTIFICATE_REQUEST, cr, 0));
    }
    flight.push(await conn.#sendHs(hs, DtlsHandshakeType.SERVER_HELLO_DONE, Buffer.alloc(0), 0));

    let sawClientCert = false;
    let ckeHash = null;
    let ckeTranscript = null;
    for (;;) {
      const msg = await conn.#pumpUntilMessage(hs, flight);
      if (msg.type === DtlsHandshakeType.CERTIFICATE) {
        hs.transcript.push(msg.raw);
        if (msg.body.length > 3) {
          try {
            conn.#peerCertificate = parseFirstCert(msg.body);
            sawClientCert = true;
          } catch {
            sawClientCert = false;
          }
        }
      } else if (msg.type === DtlsHandshakeType.CLIENT_KEY_EXCHANGE) {
        hs.transcript.push(msg.raw);
        const r = new Reader(msg.body);
        const point = Buffer.from(r.vec8());
        const premaster = ecdh.computeSecret(point);
        ckeHash = hs.hash();
        ckeTranscript = hs.bytes();
        conn.#masterSecret = clientEms
          ? prf(premaster, "extended master secret", ckeHash, 48)
          : prf(premaster, "master secret", Buffer.concat([conn.#clientRandom, conn.#serverRandom]), 48);
        conn.#deriveKeys(conn.#masterSecret);
      } else if (msg.type === DtlsHandshakeType.CERTIFICATE_VERIFY) {
        const peerKey = parsePublicKey(conn.#peerCertificate);
        const r = new Reader(msg.body);
        r.u16();
        const sig = Buffer.from(r.vec16());
        const ok = crypto.verify("sha256", ckeTranscript, { key: peerKey, dsaEncoding: "der" }, sig);
        if (!ok) throw new Error("CertificateVerify signature invalid");
        hs.transcript.push(msg.raw);
      } else if (msg.type === DtlsHandshakeType.FINISHED) {
        const expected = prf(conn.#masterSecret, "client finished", hs.hash(), 12);
        if (!msg.body.equals(expected)) throw new Error("client Finished verification failed");
        hs.transcript.push(msg.raw);
        break;
      } else {
        throw new Error("unexpected message in client flight");
      }
    }
    if (config.requirePeerCertificate && !sawClientCert) {
      throw new Error("peer presented no certificate");
    }
    conn.#checkFingerprint(config.expectedPeerFingerprint);

    await conn.#sendRecord(DtlsContentType.CHANGE_CIPHER_SPEC, 0, Buffer.from([1]));
    const verifyData = prf(conn.#masterSecret, "server finished", hs.hash(), 12);
    await conn.#sendHs(hs, DtlsHandshakeType.FINISHED, verifyData, 1);
    return conn;
  }
}

function clientHelloBody(random, cookie, connectionId, pairHint) {
  const exts = [];
  exts.push(Buffer.from([0, 10, 0, 4, 0, 2, 0, GROUP_SECP256R1]));
  exts.push(Buffer.from([0, 11, 0, 2, 1, 0]));
  exts.push(Buffer.from([0, 13, 0, 10, 0, 8, 0x04, 0x03, 0x05, 0x03, 0x04, 0x01, 0x08, 0x04]));
  const srtpData = Buffer.from([0, 6, 0, 7, 0, 1, 0, 2, 0]);
  exts.push(Buffer.from([0, 14, 0, srtpData.length]), srtpData);
  exts.push(Buffer.from([0, 23, 0, 0]));
  // connection_id (54, RFC 9146): the cid we ask the server
  // to put on records it sends us (length-prefixed).
  if (connectionId) {
    const ty = Buffer.alloc(2);
    ty.writeUInt16BE(DtlsExtension.CONNECTION_ID, 0);
    exts.push(ty, Buffer.from([0, connectionId.length + 1, connectionId.length]), connectionId);
  }
  // DcPairHint (private): the remote peer's ICE ufrag, so a
  // shared-socket mux can route this first flight.
  if (pairHint) {
    const ty = Buffer.alloc(2);
    ty.writeUInt16BE(DtlsExtension.DC_PAIR_HINT, 0);
    const len = Buffer.alloc(2);
    len.writeUInt16BE(pairHint.length, 0);
    exts.push(ty, len, pairHint);
  }
  const extBytes = Buffer.concat(exts);
  return Buffer.concat([
    DTLS_1_2,
    random,
    Buffer.from([0]),
    Buffer.from([cookie.length]),
    cookie,
    Buffer.from([0, 2, 0xc0, 0x2b]),
    Buffer.from([1, 0]),
    Buffer.from([(extBytes.length >> 8) & 0xff, extBytes.length & 0xff]),
    extBytes,
  ]);
}

function parseServerHello(body) {
  const r = new Reader(body);
  r.u8();
  r.u8();
  const serverRandom = Buffer.from(r.take(32));
  r.vec8();
  const suite = r.u16();
  if (suite !== SUITE) throw new Error("server picked an unsupported cipher suite");
  r.u8();
  const info = { serverRandom, ems: false, srtpProfile: null, peerCid: null };
  if (!r.done()) {
    const exts = r.vec16();
    const er = new Reader(exts);
    while (!er.done()) {
      const ty = er.u16();
      const data = er.vec16();
      if (ty === 23) info.ems = true;
      else if (ty === DtlsExtension.CONNECTION_ID) {
        const cr = new Reader(data);
        info.peerCid = Buffer.from(cr.vec8());
      } else if (ty === 14) {
        const sr = new Reader(data);
        const profiles = sr.vec16();
        if (profiles.length >= 2) info.srtpProfile = profiles.readUInt16BE(0);
      }
    }
  }
  return info;
}
