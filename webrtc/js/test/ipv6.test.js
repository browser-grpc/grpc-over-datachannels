// IPv6 ICE candidates: XOR address helpers are family-aware
// (RFC 5389: the IPv6 mask is magic cookie + transaction ID),
// candidates round-trip through SDP in canonical compressed
// form, and two peers connect over ::1 host candidates only.

import assert from "node:assert/strict";
import test from "node:test";
import { Peer } from "../peer.js";
import { Candidate } from "../ice.js";
import {
  StunMessage,
  decodeMappedAddress,
  formatIp,
  parseHostPort,
  parseIp,
  xorMappedAddress,
} from "../stun.js";
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

test("IPv6 parse/format canonical forms", () => {
  const cases = [
    ["::1", "::1"],
    ["0:0:0:0:0:0:0:1", "::1"],
    ["2001:0db8:0000:0000:0000:ff00:0042:8329", "2001:db8::ff00:42:8329"],
    ["fe80:0:0:0:1:0:0:1", "fe80::1:0:0:1"],
    ["::ffff:192.0.2.1", "::ffff:192.0.2.1"],
  ];
  for (const [input, want] of cases) {
    const parsed = parseIp(input);
    assert.ok(parsed && parsed.family === 2, input);
    assert.equal(formatIp(parsed.bytes), want, input);
  }
  assert.equal(parseIp("example.local"), null);
  assert.deepEqual(parseHostPort("[::1]:3478"), { address: "::1", port: 3478 });
  assert.deepEqual(parseHostPort("127.0.0.1:9"), { address: "127.0.0.1", port: 9 });
});

test("XOR-MAPPED-ADDRESS round-trips IPv6", () => {
  const request = new StunMessage(StunMessageType.BINDING_REQUEST);
  const addr = { address: "2001:db8::42", port: 51234 };
  const value = xorMappedAddress(addr, request.transactionId);
  assert.equal(value[1], 2);
  const resp = new StunMessage(StunMessageType.BINDING_SUCCESS);
  resp.transactionId = Buffer.from(request.transactionId);
  resp.attrs.push([StunAttribute.XOR_MAPPED_ADDRESS, value]);
  assert.deepEqual(decodeMappedAddress(resp, true), addr);
  // A mapped result is normalized back to dotted IPv4.
  const v4 = xorMappedAddress({ address: "::ffff:203.0.113.9", port: 7 }, request.transactionId);
  const resp2 = new StunMessage(StunMessageType.BINDING_SUCCESS);
  resp2.transactionId = Buffer.from(request.transactionId);
  resp2.attrs.push([StunAttribute.XOR_MAPPED_ADDRESS, v4]);
  assert.deepEqual(decodeMappedAddress(resp2, true), { address: "203.0.113.9", port: 7 });
});

test("IPv6 candidate SDP round-trip", () => {
  const line =
    "a=candidate:1 1 udp 2130706431 2001:0db8:0000:0000:0000:0000:0000:0001 54321 typ host generation 0";
  const cand = Candidate.fromSdp(line);
  assert.equal(cand.address, "2001:db8::1");
  assert.equal(cand.port, 54321);
  assert.match(cand.toSdp(), /2001:db8::1 54321 typ host/);
});

test("peers connect over IPv6 loopback candidates only", { timeout: 30000 }, async (t) => {
  const options = { localIps: ["::1"] };
  const offerer = await Peer.create(options);
  const answerer = await Peer.create(options);
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const offer = offerer.createOffer();
  assert.match(offer, /a=candidate:1 1 udp \d+ ::1 \d+ typ host/);
  const answer = answerer.handleOffer(offer);
  offerer.handleAnswer(answer);
  const [epA, epB] = await Promise.all([offerer.connect(), answerer.connect()]);

  let reply = null;
  epB.onchannel = (channel) => {
    channel.onmessage = (event) => {
      const data = Buffer.isBuffer(event.data) ? event.data : Buffer.from(event.data);
      channel.send(Buffer.concat([Buffer.from("echo:"), data]));
    };
  };
  const channel = epA.openChannel({ label: "echo" });
  channel.onmessage = (event) => {
    reply = Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data);
  };
  channel.send(Buffer.from("over-v6"));
  assert.equal(await waitFor(() => reply), "echo:over-v6");
});

// A dual-stack peer (udp6 socket) advertises both families and
// still pairs with an IPv4-only peer: IPv4 packets arrive from
// ::ffff:127.0.0.1 and must be normalized to match candidates.
test("dual-stack peer connects to IPv4-only peer", { timeout: 30000 }, async (t) => {
  const offerer = await Peer.create({ localIps: ["127.0.0.1", "::1"] });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"] });
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const offer = offerer.createOffer();
  assert.match(offer, / 127\.0\.0\.1 \d+ typ host/);
  assert.match(offer, / ::1 \d+ typ host/);
  const answer = answerer.handleOffer(offer);
  offerer.handleAnswer(answer);
  const [epA, epB] = await Promise.all([offerer.connect(), answerer.connect()]);

  let reply = null;
  epB.onchannel = (channel) => {
    channel.onmessage = (event) => {
      const data = Buffer.isBuffer(event.data) ? event.data : Buffer.from(event.data);
      channel.send(Buffer.concat([Buffer.from("echo:"), data]));
    };
  };
  const channel = epA.openChannel({ label: "echo" });
  channel.onmessage = (event) => {
    reply = Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data);
  };
  channel.send(Buffer.from("dual-stack"));
  assert.equal(await waitFor(() => reply), "echo:dual-stack");
});
