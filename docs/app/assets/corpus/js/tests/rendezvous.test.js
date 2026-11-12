import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchRendezvousDescriptor,
  synthesizeRendezvousOffer,
} from "../src/rendezvous.js";

test("rendezvous offer synthesis: ICE-lite at session level, descriptor values verbatim", () => {
  const descriptor = {
    host: "203.0.113.10",
    port: 8443,
    iceUfrag: "abcd1234",
    icePwd: "0123456789abcdefghijkl",
    fingerprint:
      "AB:CD:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00",
    setup: "passive",
  };
  const sdp = synthesizeRendezvousOffer(descriptor);
  const lines = sdp.split("\r\n");
  const iceLiteAt = lines.indexOf("a=ice-lite");
  const mediaAt = lines.findIndex((line) => line.startsWith("m=application"));
  assert.ok(iceLiteAt > 0, "ice-lite present");
  assert.ok(iceLiteAt < mediaAt, "ice-lite is session-level (before the m= line)");
  assert.ok(lines.includes("a=ice-ufrag:abcd1234"));
  assert.ok(lines.includes("a=ice-pwd:0123456789abcdefghijkl"));
  assert.ok(lines.includes(`a=fingerprint:sha-256 ${descriptor.fingerprint}`));
  assert.ok(lines.includes("a=setup:passive"));
  assert.ok(
    lines.some((line) =>
      line.startsWith("a=candidate:1 1 udp 2130706431 203.0.113.10 8443 typ host"),
    ),
  );
  assert.ok(lines.includes("a=end-of-candidates"));
  assert.equal(synthesizeRendezvousOffer({ ...descriptor, setup: undefined }).includes("a=setup:passive"), true);
});

test("fetchRendezvousDescriptor: parses and validates descriptor JSON", async () => {
  const good = {
    host: "203.0.113.10",
    port: 8443,
    iceUfrag: "abcd1234",
    icePwd: "0123456789abcdefghijkl",
    fingerprint: "AB:CD",
    setup: "passive",
  };
  const fetchOk = async () => ({ ok: true, status: 200, json: async () => good });
  assert.deepEqual(
    await fetchRendezvousDescriptor("https://x/.well-known/grpc-dc-rendezvous.json", { fetchImpl: fetchOk }),
    good,
  );
  const fetch404 = async () => ({ ok: false, status: 404, json: async () => ({}) });
  await assert.rejects(
    fetchRendezvousDescriptor("https://x/d.json", { fetchImpl: fetch404 }),
    /404/,
  );
  const fetchBad = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ host: "203.0.113.10" }),
  });
  await assert.rejects(
    fetchRendezvousDescriptor("https://x/d.json", { fetchImpl: fetchBad }),
    /missing port/,
  );
});
