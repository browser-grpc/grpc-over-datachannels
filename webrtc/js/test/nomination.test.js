// The nominating check is a STUN transaction, not a one-shot:
// it must be retransmitted (paced) until its Binding success
// arrives, and stop once the pair is nominated.

import assert from "node:assert/strict";
import test from "node:test";
import { Candidate, IceAgent } from "../ice.js";
import { StunMessage } from "../stun.js";

test("nomination check retransmits until answered", () => {
  const a = new IceAgent(true); // controlling
  const b = new IceAgent(false);
  const srcA = { address: "127.0.0.1", port: 4000 };
  const srcB = { address: "127.0.0.1", port: 5000 };
  a.localCandidates = [Candidate.host("127.0.0.1", 4000, "a")];
  b.localCandidates = [Candidate.host("127.0.0.1", 5000, "b")];
  a.setRemote(b.localUfrag, b.localPwd, b.localCandidates);
  b.setRemote(a.localUfrag, a.localPwd, a.localCandidates);

  const nominating = () =>
    [...a.outstanding.values()].filter((entry) => entry.nominate).length;

  // B's regular check validates the pair at A.
  a.handleStun(b.dueChecks()[0].bytes, srcB);

  let checks = a.dueChecks();
  assert.equal(nominating(), 1, "first dueChecks sends one nominating check");
  a.dueChecks();
  assert.equal(nominating(), 1, "immediate dueChecks must be paced");

  // Age the stamp past the retransmit interval: a fresh
  // nominating transaction is due.
  a.nominatingSentAt.set(b.localCandidates[0].key, Date.now() - 1000);
  checks = a.dueChecks();
  assert.equal(nominating(), 2, "retransmit after the interval");

  // Deliver the newest nominating check to B and return its
  // success to A: the pair nominates and checks stop.
  const nominatingCheck = checks.find((check) => {
    const msg = StunMessage.decode(check.bytes);
    return a.outstanding.get(msg.transactionId.toString("hex"))?.nominate;
  });
  assert.ok(nominatingCheck, "nominating check present in dueChecks output");
  const { responses } = b.handleStun(nominatingCheck.bytes, srcA);
  assert.equal(responses.length, 1);
  a.handleStun(responses[0].bytes, srcB);
  assert.ok(a.nominated, "pair nominated after the success response");
  assert.equal(a.dueChecks().length, 0, "checks stop after nomination");
});
