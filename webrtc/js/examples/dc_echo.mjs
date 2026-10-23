// DataChannel echo harness over direct DTLS (no ICE):
// `node dc_echo.mjs server|client <port>` — mirrors the Rust dc_echo.

import dgram from "node:dgram";
import { createInterface } from "node:readline";
import { DtlsConnection, udpPacketIo } from "../dtls.js";
import { DcEndpoint } from "../endpoint.js";
import { Certificate } from "../x509.js";

const [mode, portArg] = process.argv.slice(2);
const port = Number(portArg ?? 4444);

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
  const dtls = await DtlsConnection.accept(serverIo(socket), config());
  console.error("HANDSHAKE_OK");
  const endpoint = new DcEndpoint(dtls, "server");
  endpoint.onchannel = (channel) => {
    console.error(`CHANNEL_OPEN stream=${channel.id} label=${channel.label}`);
    channel.onmessage = (event) => {
      const data = Buffer.isBuffer(event.data) ? event.data : Buffer.from(event.data);
      channel.send(Buffer.concat([Buffer.from("re:"), data]));
    };
  };
  // stay alive
  setInterval(() => {}, 1000);
} else if (mode === "client") {
  const socket = dgram.createSocket("udp4");
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  const dtls = await DtlsConnection.connect(
    udpPacketIo(socket, { address: "127.0.0.1", port }),
    config(),
  );
  console.error("HANDSHAKE_OK");
  const endpoint = new DcEndpoint(dtls, "client");
  const channel = endpoint.openChannel({ label: "echo" });
  const replies = [];
  channel.onmessage = (event) => {
    replies.push(Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data));
  };
  const rl = createInterface({ input: process.stdin });
  for await (const line of rl) {
    if (!line) continue;
    const before = replies.length;
    channel.send(Buffer.from(line));
    const deadline = Date.now() + 10000;
    while (replies.length === before && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 10));
    }
    if (replies.length === before) {
      console.error("no reply");
      process.exit(1);
    }
    console.log(replies[replies.length - 1]);
  }
  process.exit(0);
} else {
  console.error("usage: dc_echo.mjs <server|client> <port>");
  process.exit(2);
}
