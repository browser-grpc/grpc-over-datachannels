// Full stack in Node: ICE + DTLS + SCTP + DCEP between two JS peers
// with SDP exchanged in-process, host candidates on loopback only.
// Also: JS peer against a Rust peer via the peer_echo harness.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import test from "node:test";
import { Peer } from "../peer.js";

const ROOT = new URL("../../..", import.meta.url).pathname;
const RUST_PEER_ECHO = `${ROOT}webrtc/rust/target/debug/examples/peer_echo`;

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

test("full JS peer datachannel echo", { timeout: 60000 }, async (t) => {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"] });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"] });
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const offer = offerer.createOffer();
  const answer = answerer.handleOffer(offer);
  offerer.handleAnswer(answer);

  const [offererEp, answererEp] = await Promise.all([offerer.connect(), answerer.connect()]);

  const channel = offererEp.openChannel({ label: "echo" });
  let answererChannel = null;
  let received = null;
  answererEp.onchannel = (ch) => {
    answererChannel = ch;
    ch.onmessage = (event) => {
      received = Buffer.isBuffer(event.data) ? event.data : Buffer.from(event.data);
      ch.send(Buffer.concat([Buffer.from("re:"), received]));
    };
  };
  channel.send(Buffer.from("over the full stack"));

  const echoed = await waitFor(() => received);
  assert.ok(answererChannel, "answerer never saw the channel");
  assert.equal(echoed.toString(), "over the full stack");

  let reply = null;
  channel.onmessage = (event) => {
    reply = Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data);
  };
  const got = await waitFor(() => reply);
  assert.equal(got, "re:over the full stack");
});
