// Peer-level consumption of the shared Rust SCTP core:
// full ICE/DTLS peers whose SCTP association is the Wasm
// core (sctp_wasm.js) instead of the mirrored JS stack,
// including mixed pairs (one side Wasm core, one side JS
// stack) for wire interop. Mirrors chunking.test.js.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Peer } from "../peer.js";
import { loadSctpWasm } from "../sctp_wasm.js";

const { Association: WasmAssociation } = await loadSctpWasm(
  readFileSync(
    new URL("../../../browser-test/dc_sctp_gen/dc_sctp_wasm_bg.wasm", import.meta.url)
  )
);

const wasmFactory = (role, localPort) =>
  role === "client"
    ? WasmAssociation.newClient(localPort)
    : WasmAssociation.newServer(localPort);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function echoPair(offererOpts, answererOpts, chunkMessages, size) {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"], chunkMessages, ...offererOpts });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"], chunkMessages, ...answererOpts });
  try {
    const offer = offerer.createOffer();
    offerer.handleAnswer(answerer.handleOffer(offer));
    const [oEp, aEp] = await Promise.all([offerer.connect(), answerer.connect()]);
    const channel = oEp.openChannel({ label: "echo" });
    aEp.onchannel = (ch) => {
      ch.onmessage = (e) => ch.send(e.data);
    };
    let reply = null;
    channel.onmessage = (e) => {
      reply = Buffer.isBuffer(e.data) ? e.data : Buffer.from(e.data);
    };
    const big = Buffer.alloc(size, 65);
    channel.send(big);
    const deadline = Date.now() + 30000;
    while (!reply && Date.now() < deadline) await sleep(25);
    assert.ok(reply, "no echo");
    assert.ok(reply.equals(big), `echo mismatch at ${size} bytes`);
  } finally {
    await offerer.close();
    await answerer.close();
  }
}

test("wasm-core peers echo small + 1 MiB chunked", { timeout: 90000 }, async () => {
  await echoPair({ assocFactory: wasmFactory }, { assocFactory: wasmFactory }, false, 100);
  await echoPair({ assocFactory: wasmFactory }, { assocFactory: wasmFactory }, true, 1024 * 1024);
});

test("mixed wasm/js SCTP peers interop", { timeout: 90000 }, async () => {
  await echoPair({ assocFactory: wasmFactory }, {}, false, 4096);
  await echoPair({}, { assocFactory: wasmFactory }, false, 4096);
});
