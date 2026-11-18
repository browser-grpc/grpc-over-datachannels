// Peer-level consumption of the shared Rust DTLS and ICE
// cores: full peers whose handshake and ICE agent are the
// Wasm cores (dtls_wasm.js / ice_wasm.js) instead of the
// mirrored JS stacks, including mixed pairs against the
// mirrors for wire interop.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Peer } from "../peer.js";
import { loadDtlsWasm } from "../dtls_wasm.js";
import { loadIceWasm } from "../ice_wasm.js";

const { DtlsConnection: WasmDtls } = await loadDtlsWasm(
  readFileSync(
    new URL("../../../browser-test/dc_dtls_gen/dc_dtls_wasm_bg.wasm", import.meta.url)
  )
);
const { IceAgent: WasmIceAgent } = await loadIceWasm(
  readFileSync(
    new URL("../../../browser-test/dc_ice_gen/dc_ice_wasm_bg.wasm", import.meta.url)
  )
);

const dtlsFactory = (io, config, role) =>
  role === "client" ? WasmDtls.connect(io, config) : WasmDtls.accept(io, config);
const iceAgentFactory = (controlling) => new WasmIceAgent(controlling);
const rustOpts = { dtlsFactory, iceAgentFactory };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function echoPair(offererOpts, answererOpts, size) {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"], ...offererOpts });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"], ...answererOpts });
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
    const payload = Buffer.alloc(size, 66);
    channel.send(payload);
    const deadline = Date.now() + 30000;
    while (!reply && Date.now() < deadline) await sleep(25);
    assert.ok(reply, "no echo");
    assert.ok(reply.equals(payload), `echo mismatch at ${size} bytes`);
  } finally {
    await offerer.close();
    await answerer.close();
  }
}

test("rust DTLS+ICE core peers echo", { timeout: 90000 }, async () => {
  await echoPair(rustOpts, rustOpts, 4096);
});

test("mixed rust/mirrored DTLS+ICE peers interop", { timeout: 90000 }, async () => {
  await echoPair(rustOpts, {}, 4096);
  await echoPair({}, rustOpts, 4096);
});
