// Consent freshness (RFC 7675): while both peers answer, no
// failure fires; once the remote dies, consent expires and
// onConsentFailure surfaces it.

import assert from "node:assert/strict";
import test from "node:test";
import { Peer } from "../peer.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("consent freshness detects a dead peer", { timeout: 30000 }, async (t) => {
  const options = { localIps: ["127.0.0.1"], consentIntervalMs: 100, consentExpiryMs: 800 };
  const offerer = await Peer.create(options);
  const answerer = await Peer.create(options);
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  let failed = false;
  let notifyFailure;
  const failureSeen = new Promise((resolve) => (notifyFailure = resolve));
  offerer.onConsentFailure = () => {
    failed = true;
    notifyFailure();
  };

  const offer = offerer.createOffer();
  const answer = answerer.handleOffer(offer);
  offerer.handleAnswer(answer);
  await Promise.all([offerer.connect(), answerer.connect()]);

  // Healthy pair: consent responses keep flowing.
  await sleep(1800);
  assert.equal(failed, false, "consent failure fired on a healthy pair");
  assert.equal(offerer.consentExpired(), false);

  // Kill the remote: its socket stops answering checks.
  await answerer.close();
  await Promise.race([
    failureSeen,
    sleep(10000).then(() => {
      throw new Error("consent failure never fired after the peer died");
    }),
  ]);
  assert.equal(offerer.consentExpired(), true);
});
