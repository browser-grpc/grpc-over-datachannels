// Minimal WebSocket framing (RFC 6455 server subset): enough for
// SDP text exchange, no dependencies. Not a general WebSocket lib.
import { createHash } from "node:crypto";

export class WebSocketServer {
  constructor({ server }) {
    this.clients = new Set();
    server.on("upgrade", (req, socket) => {
      const key = req.headers["sec-websocket-key"];
      if (!key) { socket.destroy(); return; }
      const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
      const client = new Client(socket, this);
      this.clients.add(client);
      this.emit("connection", client);
    });
    this.handlers = {};
  }
  on(event, fn) { this.handlers[event] = fn; }
  emit(event, client) { this.handlers[event]?.(client); }
}

class Client {
  constructor(socket, server) {
    this.socket = socket; this.server = server; this.buf = Buffer.alloc(0); this.handlers = {};
    socket.on("data", (chunk) => {
      this.buf = Buffer.concat([this.buf, chunk]);
      for (;;) {
        const frame = this.readFrame();
        if (!frame) break;
        if (frame.opcode === 8) { this.socket.end(); this.emit("close"); }
        else if (frame.opcode === 1) this.emit("message", frame.payload);
      }
    });
    socket.on("close", () => { this.server.clients.delete(this); this.emit("close"); });
    socket.on("error", () => {});
  }
  on(event, fn) { this.handlers[event] = fn; }
  emit(event, arg) { this.handlers[event]?.(arg); }
  readFrame() {
    const b = this.buf;
    if (b.length < 2) return null;
    const fin = (b[0] & 0x80) !== 0, opcode = b[0] & 0x0f, masked = (b[1] & 0x80) !== 0;
    let len = b[1] & 0x7f, off = 2;
    if (len === 126) { if (b.length < 4) return null; len = b.readUInt16BE(2); off = 4; }
    else if (len === 127) { if (b.length < 10) return null; len = Number(b.readBigUInt64BE(2)); off = 10; }
    const maskOff = off; if (masked) off += 4;
    if (b.length < off + len) return null;
    let payload = b.subarray(off, off + len);
    if (masked) { const m = b.subarray(maskOff, maskOff + 4); payload = Buffer.from(payload.map((x, i) => x ^ m[i % 4])); }
    this.buf = b.subarray(off + len);
    if (!fin) throw new Error("fragmented frames not supported");
    return { opcode, payload };
  }
  send(text) {
    const payload = Buffer.from(text);
    const header = payload.length < 126 ? Buffer.from([0x81, payload.length])
      : payload.length < 65536 ? Buffer.concat([Buffer.from([0x81, 126]), (() => { const n = Buffer.alloc(2); n.writeUInt16BE(payload.length); return n; })()])
      : (() => { const n = Buffer.alloc(9); n[0] = 0x81; n[1] = 127; n.writeBigUInt64BE(BigInt(payload.length), 1); return n; })();
    this.socket.write(Buffer.concat([header, payload]));
  }
}