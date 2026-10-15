// Trickle ICE (RFC 8445 section 4.1.1): candidates are removed
// from the SDP and delivered incrementally through
// addRemoteCandidate / setOnLocalCandidate instead. The peers
// here can only connect because the trickled candidates arrive.

import assert from "node:assert/strict";
import dgram from "node:dgram";
import test from "node:test";
import { Peer } from "../peer.js";
import { StunMessage, xorMappedAddress } from "../stun.js";
import { StunAttribute, StunMessageType } from "../proto_gen.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = fn();
    if (value) return value;
    await sleep(20);
  }
  return null;
}

const stripCandidates = (sdp) =>
  sdp
    .split("\r\n")
    .filter((line) => !line.startsWith("a=candidate:"))
    .join("\r\n");

const candidateLinesOf = (sdp) => sdp.split("\r\n").filter((line) => line.startsWith("a=candidate:"));

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

test("addRemoteCandidate parsing, dedup, end-of-candidates", async (t) => {
  const a = await Peer.create({ localIps: ["127.0.0.1"] });
  const b = await Peer.create({ localIps: ["127.0.0.1"] });
  t.after(async () => {
    await a.close();
    await b.close();
  });
  const offer = a.createOffer();
  const lines = candidateLinesOf(offer);
  assert.ok(lines.length > 0, "offer has no candidates to trickle");
  b.handleOffer(stripCandidates(offer));
  // End-of-candidates, empty, null, and malformed lines are no-ops.
  assert.equal(b.addRemoteCandidate(""), false);
  assert.equal(b.addRemoteCandidate(null), false);
  assert.equal(b.addRemoteCandidate("a=end-of-candidates"), false);
  assert.equal(b.addRemoteCandidate("not a candidate"), false);
  for (const line of lines) assert.equal(b.addRemoteCandidate(line), true, line);
  // Duplicates (either spelling) are no-ops.
  assert.equal(b.addRemoteCandidate(lines[0]), false);
  assert.equal(b.addRemoteCandidate(lines[0].replace(/^a=/, "")), false);
});

test("local candidate callback replay and later gather", async (t) => {
  const stun = await fakeStunServer({ address: "203.0.113.9", port: 54321 });
  t.after(() => stun.close());
  const peer = await Peer.create({ localIps: ["127.0.0.1"] });
  t.after(() => peer.close());
  const fired = [];
  peer.setOnLocalCandidate((line) => fired.push(line));
  // Registration replays the host candidate.
  assert.equal(fired.length, 1);
  assert.match(fired[0], /typ host/);
  // A later srflx gathering fires as the candidate is added.
  assert.equal(await peer.gatherSrflx(stun.server), true);
  assert.equal(fired.length, 2);
  assert.match(fired[1], /typ srflx/);
  assert.equal(peer.localCandidateLines().length, 2);
});

async function trickleEcho(t, duringConnect) {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"] });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"] });
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const offer = offerer.createOffer();
  const answer = answerer.handleOffer(stripCandidates(offer));
  offerer.handleAnswer(stripCandidates(answer));
  const trickleAll = () => {
    for (const line of candidateLinesOf(offer)) answerer.addRemoteCandidate(line);
    answerer.addRemoteCandidate("a=end-of-candidates");
    for (const line of candidateLinesOf(answer)) offerer.addRemoteCandidate(line);
    offerer.addRemoteCandidate("a=end-of-candidates");
  };
  let offererEpPromise;
  let answererEpPromise;
  if (duringConnect) {
    offererEpPromise = offerer.connect();
    answererEpPromise = answerer.connect();
    // Let the connect loops start with zero candidates, then
    // trickle in while ICE is running.
    await sleep(200);
    trickleAll();
  } else {
    trickleAll();
    offererEpPromise = offerer.connect();
    answererEpPromise = answerer.connect();
  }
  const [offererEp, answererEp] = await Promise.all([offererEpPromise, answererEpPromise]);

  let answererChannel = null;
  answererEp.onchannel = (ch) => {
    answererChannel = ch;
    ch.onmessage = (event) => {
      const data = Buffer.isBuffer(event.data) ? event.data : Buffer.from(event.data);
      ch.send(Buffer.concat([Buffer.from("echo:"), data]));
    };
  };
  const channel = offererEp.openChannel({ label: "echo" });
  let reply = null;
  channel.onmessage = (event) => {
    reply = Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data);
  };
  channel.send(Buffer.from("via-trickle"));
  const got = await waitFor(() => reply, 15000);
  assert.ok(answererChannel, "answerer never saw the channel");
  assert.equal(got, "echo:via-trickle");
}

test("peers connect over trickled candidates only", { timeout: 60000 }, async (t) => {
  await trickleEcho(t, false);
});

test("candidates trickled during connect still connect", { timeout: 60000 }, async (t) => {
  await trickleEcho(t, true);
});
