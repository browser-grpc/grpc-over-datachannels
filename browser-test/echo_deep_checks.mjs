// Shared deep-behavior checks for the dedicated Wasm Echo
// server tests (browser-test/wasm_*_server.test.mjs and
// dart_wasm_server.test.mjs): the JS client drives canonical
// failure, metadata, and unknown-method scenarios against
// the server under test, so each server is pinned standalone
// (wasm_matrix.test.mjs pins the same codes across client x
// server pairs). Canonical semantics: the BDD specification —
// "fail" is rejected with INVALID_ARGUMENT in every method,
// x-echo metadata is reflected as " [meta]", unknown methods
// return UNIMPLEMENTED. Deadline behavior stays asserted by
// the tests themselves.

import assert from "node:assert/strict";
import { EchoRequest, EchoResponse } from "../js/examples/echo_pb.js";

async function collect(stream) {
  const out = [];
  for await (const resp of stream) out.push(resp);
  return out;
}

async function codeOf(fn) {
  try {
    await fn();
    return 0;
  } catch (err) {
    return err?.code ?? -1;
  }
}

// mode "full" (default): all four methods registered.
// mode "stream": incremental stream servers register only
// ClientStream/Bidi, so only those two are driven (unary
// shapes would correctly return UNIMPLEMENTED there).
export async function assertEchoDeepBehavior(client, channel, mode = "full") {
  const req = (message, count = 0) =>
    new EchoRequest({ message, count, delayMs: 0 });
  async function* fromList(messages) {
    for (const m of messages) yield req(m);
  }

  if (mode === "full") {
    assert.equal(await codeOf(() => client.unary(req("fail"))), 3);
    const metadata = await client.unary(req("hello"), {
      metadata: { "x-echo": "meta" },
    });
    assert.equal(metadata.message, "echo: hello [meta]");
    assert.equal(
      await codeOf(async () => collect(await client.serverStream(req("fail", 3)))),
      3,
    );
  }
  assert.equal(
    await codeOf(() => client.clientStream(fromList(["a", "fail"]))),
    3,
  );
  assert.equal(
    await codeOf(async () => collect(await client.bidi(fromList(["fail"])))),
    3,
  );
  assert.equal(
    await codeOf(() =>
      channel.unary("/echo.Echo/Nope", req("hello"), EchoRequest, EchoResponse),
    ),
    12,
  );
}
