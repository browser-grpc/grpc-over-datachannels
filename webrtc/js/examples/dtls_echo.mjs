// DTLS echo harness: `node dtls_echo.mjs server|client <port>`.
// Mirrors webrtc/rust/examples/dtls_echo.rs so the two stacks can be
// driven against each other and against OpenSSL from tests.

import dgram from "node:dgram";
import { createInterface } from "node:readline";
import { DtlsConnection, udpPacketIo } from "../dtls.js";
import { Certificate } from "../x509.js";

const [mode, portArg] = process.argv.slice(2);
const port = Number(portArg ?? 4443);

function serverIo(socket) {
  let peer = null;
  const queue = [];
  const waiters = [];
  socket.on("message", (msg, rinfo) => {
    peer = { address: rinfo.address, port: rinfo.port };
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

const config = () => ({
  certificate: Certificate.generate(),
  expectedPeerFingerprint: null,
  requirePeerCertificate: false,
});

if (mode === "server") {
  const socket = dgram.createSocket("udp4");
  await new Promise((resolve) => socket.bind(port, "127.0.0.1", resolve));
  console.error(`LISTENING ${port}`);
  const conn = await DtlsConnection.accept(serverIo(socket), config());
  console.error(`HANDSHAKE_OK peer_fp=${conn.peerFingerprint() ?? ""}`);
  for (;;) {
    const data = await conn.recvApp();
    await conn.sendApp(Buffer.concat([Buffer.from("echo:"), data]));
  }
} else if (mode === "client") {
  const socket = dgram.createSocket("udp4");
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  const io = udpPacketIo(socket, { address: "127.0.0.1", port });
  const conn = await DtlsConnection.connect(io, config());
  console.error(`HANDSHAKE_OK peer_fp=${conn.peerFingerprint() ?? ""}`);
  const rl = createInterface({ input: process.stdin });
  for await (const line of rl) {
    if (!line) continue;
    await conn.sendApp(Buffer.from(line));
    const reply = await conn.recvApp();
    console.log(reply.toString());
  }
  process.exit(0);
} else {
  console.error("usage: dtls_echo.mjs <server|client> <port>");
  process.exit(2);
}
