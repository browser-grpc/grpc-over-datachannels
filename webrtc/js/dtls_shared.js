// Shared DTLS-adjacent helpers used across the stack
// (mux record parsing, direct transport, hashing). The
// DTLS implementation itself is the Rust core
// (crates/dc-dtls-wasm) behind dtls_wasm.js.
import crypto from "node:crypto";

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
