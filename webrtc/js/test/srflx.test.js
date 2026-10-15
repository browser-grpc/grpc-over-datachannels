// Server-reflexive (srflx) ICE candidates: a fake STUN server on
// loopback answers Binding requests; peers must learn srflx
// candidates from XOR-MAPPED-ADDRESS, advertise them in SDP with
// the RFC 8445 srflx priority, and connect using them (the host
// address advertised here is deliberately unreachable, so a working
// connection proves the srflx pair carried it).

import assert from "node:assert/strict";
import dgram from "node:dgram";
import test from "node:test";
import { Peer } from "../peer.js";
import { StunMessage } from "../stun.js";
import { StunAttribute, StunMessageType } from "../proto_gen.js";
import { xorMappedAddress } from "../stun.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fakeStunServer(fixed) {
  const socket = dgram.createSocket("udp4");
  socket.on("message", (msg, rinfo) => {
    const request = StunMessage.decode(msg);
    if (!request || request.type !== StunMessageType.BINDING_REQUEST) return;
    const mapped = fixed ?? { address: rinfo.address, port: rinfo.port };
    const resp = new StunMessage(StunMessageType.BINDING_SUCCESS);
    resp.transactionId = Buffer.from(request.transactionId);
    resp.attrs.push([StunAttribute.XOR_MAPPED_ADDRESS, xorMappedAddress(mapped, request.transactionId)]);
    socket.send(resp.encode(null), rinfo.port, rinfo.address);
  });
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  return { server: `127.0.0.1:${socket.address().port}`, close: () => socket.close() };
}

test("gather srflx candidate with fixed mapped address", async (t) => {
  const stun = await fakeStunServer({ address: "203.0.113.9", port: 54321 });
  t.after(() => stun.close());
  const peer = await Peer.create({ localIps: ["127.0.0.1"], stunServers: [stun.server] });
  t.after(() => peer.close());
  const offer = peer.createOffer();
  const line = offer.split("\r\n").find((l) => l.includes("typ srflx"));
  assert.ok(line, `no srflx candidate in offer:\n${offer}`);
  assert.match(line, /203\.0\.113\.9 54321 typ srflx raddr 127\.0\.0\.1 rport \d+ generation 0/);
  const priority = Number(line.split(" ")[3]);
  assert.equal(priority >>> 24, 100);
});

test("peers connect over srflx candidates only", { timeout: 30000 }, async (t) => {
  const stun = await fakeStunServer(null);
  t.after(() => stun.close());
  const options = { localIps: ["10.11.12.13"], stunServers: [stun.server] };
  const offerer = await Peer.create(options);
  const answerer = await Peer.create(options);
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const offer = offerer.createOffer();
  assert.match(offer, /typ srflx/);
  const answer = answerer.handleOffer(offer);
  assert.match(answer, /typ srflx/);
  offerer.handleAnswer(answer);

  const [offererEp, answererEp] = await Promise.all([offerer.connect(), answerer.connect()]);
  let received = null;
  answererEp.onchannel = (ch) => {
    ch.onmessage = (event) => {
      received = Buffer.from(event.data).toString();
    };
  };
  const channel = offererEp.openChannel({ label: "echo" });
  channel.send(Buffer.from("via-srflx"));
  const deadline = Date.now() + 10000;
  while (received === null && Date.now() < deadline) await sleep(20);
  assert.equal(received, "via-srflx");
});
