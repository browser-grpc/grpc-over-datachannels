// TURN over TCP/TLS (RFC 5766 section 4): the allocation runs
// over a dedicated stream connection while relayed traffic
// still reaches peers over UDP. Both peers advertise an
// unreachable host address, so a working echo proves the relay
// (permissions, channel binds, padded ChannelData) carried it.

import assert from "node:assert/strict";
import test from "node:test";
import { Peer } from "../peer.js";
import { fakeTurnTcp, fakeTurnTls, USER, PASS } from "./fake_turn_stream.js";

async function streamRelayConnect(t, fake, cfgExtra) {
  const options = {
    localIps: ["10.11.12.13"],
    turnServers: [{ address: fake.server, username: USER, password: PASS, ...cfgExtra }],
  };
  const offerer = await Peer.create(options);
  const answerer = await Peer.create(options);
  t.after(async () => {
    await offerer.close();
    await answerer.close();
    fake.close();
  });
  const offer = offerer.createOffer();
  assert.match(offer, /typ relay/, `no relay candidate in offer:\n${offer}`);
  const answer = answerer.handleOffer(offer);
  assert.match(answer, /typ relay/, `no relay candidate in answer:\n${answer}`);
  offerer.handleAnswer(answer);
  const [epA, epB] = await Promise.all([offerer.connect(), answerer.connect()]);
  const received = new Promise((resolve) => {
    epA.onchannel = (channel) => {
      channel.onmessage = (event) => resolve(Buffer.from(event.data).toString());
    };
  });
  epB.openChannel({ label: "echo" }).send(Buffer.from("via-stream-relay"));
  assert.equal(await received, "via-stream-relay");
  assert.ok(fake.stats.permReqCount >= 2, `permissions=${fake.stats.permReqCount}`);
  assert.ok(fake.stats.bindCount >= 2, `binds=${fake.stats.bindCount}`);
  assert.ok(fake.stats.chanData > 0, "no ChannelData relayed over the stream");
}

test("peers connect over TURN/TCP relay only", { timeout: 30000 }, async (t) => {
  await streamRelayConnect(t, await fakeTurnTcp(), { transport: "tcp" });
});

test("peers connect over TURN/TLS relay only", { timeout: 30000 }, async (t) => {
  await streamRelayConnect(t, await fakeTurnTls(), {
    transport: "tls",
    insecureSkipVerify: true,
  });
});

test("TURN/TCP allocate with a bad password adds no relay candidate", { timeout: 20000 }, async (t) => {
  const fake = await fakeTurnTcp();
  t.after(() => fake.close());
  const peer = await Peer.create({
    localIps: ["127.0.0.1"],
    turnServers: [{ address: fake.server, username: USER, password: "wrong", transport: "tcp" }],
  });
  t.after(() => peer.close());
  const offer = peer.createOffer();
  assert.ok(!offer.includes("typ relay"), `unexpected relay candidate:\n${offer}`);
  assert.equal(peer.turn, null);
});
