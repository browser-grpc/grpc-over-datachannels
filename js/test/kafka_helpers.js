// Shared helpers for the kafka e2e suites (proxy + streams):
// one length-prefixed TCP connection presented as a
// DataChannel-like object, plus the text encoders every
// suite needs. Env gating stays in each test file.

import { connect } from "node:net";

export const enc = (s) => new TextEncoder().encode(s);
export const dec = (b) => new TextDecoder().decode(b);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** One length-prefixed TCP connection as a DataChannel-like object. */
export function tcpDataChannel(host, port) {
  const socket = connect(port, host);
  let buffer = Buffer.alloc(0);
  const dc = {
    readyState: "open",
    onmessage: null,
    send(data) {
      const payload = Buffer.from(data instanceof Uint8Array ? data : new Uint8Array(data));
      const frame = Buffer.alloc(4 + payload.length);
      frame.writeUInt32BE(payload.length, 0);
      payload.copy(frame, 4);
      socket.write(frame);
    },
    close() {
      socket.destroy();
    },
  };
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const len = buffer.readUInt32BE(0);
      if (buffer.length < 4 + len) break;
      const msg = new Uint8Array(buffer.subarray(4, 4 + len));
      buffer = buffer.subarray(4 + len);
      dc.onmessage?.({ data: msg.buffer.slice(msg.byteOffset, msg.byteOffset + msg.byteLength) });
    }
  });
  return dc;
}

/** tcpDataChannel for a "host:port" proxy address. */
export function tcpChannelForAddr(addr) {
  const sep = addr.lastIndexOf(":");
  return tcpDataChannel(addr.slice(0, sep), Number(addr.slice(sep + 1)));
}
