// Phase 3 conformance vectors (fixtures/sctp_vectors.json,
// sack_scenarios): all three mirrored SCTP stacks run the same
// SACK/gap/retransmit scenarios against the generated tracker.
// Thin interpreter only — scenarios are generated data.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { SctpSackTracker } from "../sctp_sack_gen.js";

const file = JSON.parse(
  readFileSync(new URL("../../../fixtures/sctp_vectors.json", import.meta.url), "utf8"),
);

assert.ok(file.sack_scenarios?.length > 0, "no sack scenarios");

for (const sc of file.sack_scenarios) {
  test(`sctp sack vector: ${sc.name}`, () => {
    const tracker = new SctpSackTracker(sc.initial_cum);
    sc.steps.forEach((step, i) => {
      if (step.recv !== undefined) {
        tracker.noteReceived(step.recv);
        assert.deepEqual(tracker.gapBlocks(), step.gaps, `step ${i} gapBlocks`);
      }
      if (step.sack !== undefined) {
        const { acked, retransmit } = tracker.noteSack(
          step.sack.cum,
          step.sack.blocks,
          step.sack.unacked,
        );
        assert.deepEqual(acked, step.acked, `step ${i} acked`);
        assert.deepEqual(retransmit, step.retransmit, `step ${i} retransmit`);
      }
    });
  });
}
