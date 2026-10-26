// Live STUN smoke test (opt-in): every other STUN test runs
// against an in-process fake on loopback, so nothing exercised
// a real public STUN server, real NAT mapping, or real UDP
// egress. This test gathers a server-reflexive candidate from
// Google's public STUN server. It is OUT of the default gate
// (CI stays hermetic): run via `make test-live-stun` or with
// GRPC_DC_LIVE_STUN=1 in the environment.

import assert from "node:assert/strict";
import test from "node:test";
import { Peer } from "../peer.js";

const LIVE = process.env.GRPC_DC_LIVE_STUN ? false : "GRPC_DC_LIVE_STUN not set; live STUN smoke test skipped";

test("gather srflx candidate from Google STUN (live)", { skip: LIVE, timeout: 30000 }, async (t) => {
  const peer = await Peer.create({ stunServers: ["stun.l.google.com:19302"] });
  t.after(() => peer.close());
  await peer.gatherSrflx("stun.l.google.com:19302", 5000);
  const offer = peer.createOffer();
  const line = offer.split("\r\n").find((l) => l.includes("typ srflx"));
  assert.ok(line, `no srflx candidate in offer:\n${offer}`);
  const address = line.split(" ")[4];
  assert.notEqual(address, "127.0.0.1", `srflx is loopback, want public egress mapping: ${line}`);
  console.log(`live srflx: ${line}`);
});
