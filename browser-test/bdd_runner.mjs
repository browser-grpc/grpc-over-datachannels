// Browser BDD interpreter: executes the generated BDD_SCENARIOS
// table (browser-test/bdd_scenarios.generated.mjs, stamped by
// racket/bdd-gen.rkt from racket/bdd-spec.rkt) against a live
// EchoClient/Channel pair and returns one result per scenario.
// The Node TestBdd suite (js/test/bdd.test.js) interprets the
// same table over loopback; this interpreter is the browser
// counterpart, shared by bdd_page.html so the documented
// scenarios are exactly what a real browser enforces.

function check(condition, message) {
  if (!condition) throw new Error(message);
}

async function* fromList(items) {
  yield* items;
}

async function collect(iterable) {
  const out = [];
  for await (const item of iterable) out.push(item);
  return out;
}

async function expectStatus(run, code, name) {
  try {
    await run();
  } catch (err) {
    check(err && err.code === code,
      `${name}: expected status ${code}, got ${err && err.code} (${err && err.message})`);
    return;
  }
  throw new Error(`${name}: expected status ${code}, call succeeded`);
}

export async function runBddScenarios({ client, channel, EchoRequest, EchoResponse, scenarios }) {
  const req = (message, count = 0, delayMs = 0) => new EchoRequest({ message, count, delayMs });
  const results = [];

  for (const c of scenarios) {
    try {
      if (c.kind === "unary") {
        const options = c.metadata ? { metadata: { "x-echo": c.metadata } } : undefined;
        if (c.expectStatus >= 0) {
          await expectStatus(() => client.unary(req(c.messages[0]), options), c.expectStatus, c.name);
        } else {
          const resp = await client.unary(req(c.messages[0]), options);
          check(resp.message === c.expectMessage, `${c.name}: message ${resp.message}`);
          check(resp.index === c.expectNum, `${c.name}: index ${resp.index}`);
        }
      } else if (c.kind === "server-stream") {
        const got = await collect(await client.serverStream(req(c.messages[0], c.count)));
        check(got.length === c.expectNum, `${c.name}: got ${got.length} responses`);
        got.forEach((resp, i) => {
          check(resp.message === c.expectMessage, `${c.name}: message ${resp.message} at ${i}`);
          check(resp.index === i, `${c.name}: index ${resp.index} at ${i}`);
        });
      } else if (c.kind === "client-stream") {
        const resp = await client.clientStream(fromList(c.messages.map((m) => req(m))));
        check(resp.message === c.expectMessage, `${c.name}: message ${resp.message}`);
        check(resp.index === c.expectNum, `${c.name}: index ${resp.index}`);
      } else if (c.kind === "bidi") {
        const got = await collect(await client.bidi(fromList(c.messages.map((m) => req(m)))));
        check(got.length === c.expectNum, `${c.name}: got ${got.length} responses`);
        got.forEach((resp, i) => {
          check(resp.message === c.messages[i], `${c.name}: message ${resp.message} at ${i}`);
          check(resp.index === i, `${c.name}: index ${resp.index} at ${i}`);
        });
      } else if (c.kind === "server-stream-fail") {
        await expectStatus(
          async () => collect(await client.serverStream(req(c.messages[0], c.count))),
          c.expectStatus, c.name);
      } else if (c.kind === "bidi-fail") {
        await expectStatus(
          async () => collect(await client.bidi(fromList(c.messages.map((m) => req(m))))),
          c.expectStatus, c.name);
      } else if (c.kind === "deadline") {
        await expectStatus(
          () => client.unary(req(c.messages[0], 0, c.count), { timeout: 100 }),
          c.expectStatus, c.name);
      } else if (c.kind === "cancel") {
        const responses = await client.serverStream(req(c.messages[0], c.count));
        let got = 0;
        // Breaking the iteration tears the call down (the
        // responses generator's finally aborts the stream);
        // completing the loop at all proves it terminated.
        for await (const resp of responses) {
          check(resp.message === c.messages[0], `${c.name}: message ${resp.message}`);
          got++;
          if (got === 1) break;
        }
        check(got === 1, `${c.name}: got ${got} responses before cancel`);
      } else if (c.kind === "raw-unary") {
        await expectStatus(
          () => channel.unary(c.path, req(c.messages[0]), EchoRequest, EchoResponse),
          c.expectStatus, c.name);
      } else {
        throw new Error(`unknown bdd kind: ${c.kind}`);
      }
      results.push({ name: c.name, ok: true });
    } catch (err) {
      results.push({ name: c.name, ok: false, detail: String(err && err.stack ? err.stack : err) });
    }
  }
  return results;
}
