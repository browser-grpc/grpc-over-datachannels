// TURN on muxed peers: two PeerMuxes (one UDP port per side)
// whose peers also allocate on a fake TURN server. The
// advertised host addresses are deliberately unreachable, so
// a working echo proves the relayed pairs carried ICE + DTLS
// + data while the mux demuxed the non-relay traffic by
// connection id. The allocation's UDP leg rides a dedicated
// per-peer socket (an allocation pins a concrete 5-tuple);
// TURN traffic never touches the shared socket.

import assert from "node:assert/strict";
import test from "node:test";
import { PeerMux } from "../mux.js";
import { fakeTurnServer, USER, PASS } from "./fake_turn.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = fn();
    if (value) return value;
    await sleep(20);
  }
  return null;
}

test("two mux-to-mux pairs connect over TURN relay only", { timeout: 90000 }, async (t) => {
  const turn = await fakeTurnServer();
  t.after(() => turn.close());
  const turnServers = [{ address: turn.server, username: USER, password: PASS }];
  const options = { localIps: ["10.11.12.13"], turnServers };

  const muxA = await PeerMux.bind({ address: "127.0.0.1", port: 0 });
  t.after(() => muxA.close());
  const muxB = await PeerMux.bind({ address: "127.0.0.1", port: 0 });
  t.after(() => muxB.close());

  const pairs = [];
  for (let pair = 0; pair < 2; pair++) {
    const offerer = await muxA.createPeer(options);
    const answerer = await muxB.createPeer(options);
    t.after(async () => {
      await offerer.close();
      await answerer.close();
    });
    // The muxed peers must have learned relay candidates.
    assert.match(offerer.createOffer(), /typ relay/, "muxed offerer must advertise a relay candidate");
    pairs.push({ pair, offerer, answerer });
  }

  const runPair = async ({ pair, offerer, answerer }) => {
    const offer = offerer.createOffer();
    const answer = answerer.handleOffer(offer);
    offerer.handleAnswer(answer);
    const [offererEp, answererEp] = await Promise.all([offerer.connect(), answerer.connect()]);

    let heard = null;
    answererEp.onchannel = (ch) => {
      ch.onmessage = (event) => {
        heard = Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data);
        ch.send(Buffer.from(`re:${heard}`));
      };
    };
    const channel = offererEp.openChannel({ label: "echo" });
    let reply = null;
    channel.onmessage = (event) => {
      reply = Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data);
    };
    channel.send(Buffer.from(`hello-from-pair-${pair}`));
    assert.equal(await waitFor(() => heard), `hello-from-pair-${pair}`);
    assert.equal(await waitFor(() => reply), `re:hello-from-pair-${pair}`);
  };

  await Promise.all(pairs.map(runPair));
});
