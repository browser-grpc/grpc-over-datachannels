// ICE restart (RFC 8445 section 5.1): fresh credentials and a
// new nomination underneath the live DTLS/SCTP association.
// Media keeps flowing on the same DataChannel, renomination
// fires on both peers, either side may initiate, and consent
// stays healthy on the new pair.

import assert from "node:assert/strict";
import test from "node:test";
import { Peer } from "../peer.js";
import { parse } from "../sdp.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fn()) return;
    await sleep(25);
  }
  throw new Error("waitFor timed out");
}

test("ICE restart renominates on a live peer", { timeout: 60000 }, async (t) => {
  const events = { a: 0, b: 0, consentFailures: 0 };
  const options = {
    localIps: ["127.0.0.1"],
    consentIntervalMs: 100,
    consentExpiryMs: 800,
  };
  const a = await Peer.create(options);
  const b = await Peer.create(options);
  a.onRenominated = () => { events.a += 1; };
  b.onRenominated = () => { events.b += 1; };
  a.onConsentFailure = () => { events.consentFailures += 1; };
  b.onConsentFailure = () => { events.consentFailures += 1; };
  t.after(async () => {
    await a.close();
    await b.close();
  });

  const offer = a.createOffer();
  const answer = b.handleOffer(offer);
  a.handleAnswer(answer);
  const [epA, epB] = await Promise.all([a.connect(), b.connect()]);

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
  const echo = async (msg) => {
    reply = null;
    channel.send(Buffer.from(msg));
    await waitFor(() => reply !== null);
    assert.equal(reply, `echo:${msg}`);
  };
  await echo("before-restart");

  // Runs one restart; asserts both ufrags rotate and both
  // peers fire onRenominated. Returns the new ufrags.
  const doRestart = async (initiator, responder, prevUfrags) => {
    const restartOffer = initiator.createRestartOffer();
    const offerUfrag = parse(restartOffer).ufrag;
    assert.notEqual(offerUfrag, prevUfrags.initiator, "initiator ufrag must rotate");
    const restartAnswer = responder.handleRestartOffer(restartOffer);
    const answerUfrag = parse(restartAnswer).ufrag;
    assert.notEqual(answerUfrag, prevUfrags.responder, "responder ufrag must rotate");
    initiator.handleRestartAnswer(restartAnswer);
    await echo("during-restart");
    const expected = { a: events.a + 1, b: events.b + 1 };
    await waitFor(() => events.a >= expected.a && events.b >= expected.b);
    await echo("after-restart");
    return { initiator: offerUfrag, responder: answerUfrag };
  };

  let ufrags = { initiator: parse(offer).ufrag, responder: parse(answer).ufrag };
  ufrags = await doRestart(a, b, ufrags);
  // The other side may initiate the next restart.
  await doRestart(b, a, { initiator: ufrags.responder, responder: ufrags.initiator });

  // Consent keeps passing on the new pairs, well past expiry.
  await sleep(1800);
  assert.equal(events.consentFailures, 0, "consent failure fired after restart");
  assert.equal(events.a, 2);
  assert.equal(events.b, 2);
});
