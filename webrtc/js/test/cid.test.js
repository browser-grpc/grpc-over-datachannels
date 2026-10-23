// Direct DTLS connection-id check: two endpoints negotiate
// RFC 9146 cids (different lengths per direction) and move
// data over the resulting channel. Mirrors rust/tests/
// cid_test.rs and go/cid_test.go; the raw taps assert the
// epoch-1 records really carry the negotiated cid at offset
// 11 (after type/version/epoch/sequence), not the plain
// layout the parser also accepts.

import assert from "node:assert/strict";
import dgram from "node:dgram";
import test from "node:test";
import { DtlsConnection, udpPacketIo } from "../dtls.js";
import { Certificate } from "../x509.js";

function bind() {
  const socket = dgram.createSocket("udp4");
  return new Promise((resolve) => {
    socket.bind(0, "127.0.0.1", () => resolve(socket));
  });
}

function carriesCid(packets, cid) {
  return packets.some(
    (p) =>
      p.length > 11 + cid.length &&
      p[0] === 23 && // application data
      p[3] === 0 &&
      p[4] === 1 && // epoch 1
      p.subarray(11, 11 + cid.length).equals(cid),
  );
}

test("dtls with connection ids", { timeout: 30000 }, async (t) => {
  const serverCid = Buffer.alloc(6, 9);
  const clientCid = Buffer.alloc(4, 7);
  const serverSocket = await bind();
  const clientSocket = await bind();
  t.after(() => {
    serverSocket.close();
    clientSocket.close();
  });
  const atServer = [];
  const atClient = [];
  serverSocket.on("message", (msg) => atServer.push(Buffer.from(msg)));
  clientSocket.on("message", (msg) => atClient.push(Buffer.from(msg)));

  const serverAddr = { address: "127.0.0.1", port: serverSocket.address().port };
  const clientAddr = { address: "127.0.0.1", port: clientSocket.address().port };
  const cert = () => ({ certificate: Certificate.generate() });

  const serverDone = (async () => {
    const conn = await DtlsConnection.accept(udpPacketIo(serverSocket, clientAddr), {
      ...cert(),
      connectionId: serverCid,
    });
    const data = await conn.recvApp();
    await conn.sendApp(Buffer.concat([Buffer.from("echo:"), data]));
  })();
  const client = await DtlsConnection.connect(udpPacketIo(clientSocket, serverAddr), {
    ...cert(),
    connectionId: clientCid,
  });
  await client.sendApp(Buffer.from("ping"));
  const reply = await client.recvApp();
  assert.equal(reply.toString(), "echo:ping");
  await serverDone;

  // Records the client sent carry the server's cid; records
  // the server sent carry the client's (shorter) cid.
  assert.ok(carriesCid(atServer, serverCid), "client records must carry the server cid");
  assert.ok(carriesCid(atClient, clientCid), "server records must carry the client cid");
});
