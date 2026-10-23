// TURN relay (RFC 5766) ICE candidates: a fake TURN server on
// loopback runs the Allocate 401 dance; peers must learn relay
// candidates, advertise them with type preference 0, and connect
// through the relay (the host address advertised here is
// deliberately unreachable, so a working connection proves the
// relayed pair carried ICE + DTLS + data).

import assert from "node:assert/strict";
import crypto from "node:crypto";
import dgram from "node:dgram";
import test from "node:test";
import { Peer } from "../peer.js";
import { StunMessage } from "../stun.js";
import { StunAttribute, StunMessageType } from "../proto_gen.js";
import { fakeTurnServer, USER, PASS } from "./fake_turn.js";

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("allocate gathers a relay candidate", { timeout: 20000 }, async (t) => {
  const turn = await fakeTurnServer();
  t.after(() => turn.close());
  const peer = await Peer.create({
    localIps: ["127.0.0.1"],
    turnServers: [{ address: turn.server, username: USER, password: PASS }],
  });
  t.after(() => peer.close());
  const offer = peer.createOffer();
  const line = offer.split("\r\n").find((l) => l.includes("typ relay"));
  assert.ok(line, `no relay candidate in offer:\n${offer}`);
  assert.match(line, / typ relay raddr 127\.0\.0\.1 rport \d+ generation 0/);
  const priority = Number(line.split(" ")[3]);
  assert.equal(priority >>> 24, 0);
});

test("allocate with a bad password adds no relay candidate", { timeout: 20000 }, async (t) => {
  const turn = await fakeTurnServer();
  t.after(() => turn.close());
  const peer = await Peer.create({
    localIps: ["127.0.0.1"],
    turnServers: [{ address: turn.server, username: USER, password: "wrong" }],
  });
  t.after(() => peer.close());
  const offer = peer.createOffer();
  assert.ok(!offer.includes("typ relay"), `unexpected relay candidate:\n${offer}`);
});

test("peers connect over TURN relay only", { timeout: 30000 }, async (t) => {
  const turn = await fakeTurnServer();
  t.after(() => turn.close());
  const options = {
    localIps: ["10.11.12.13"],
    turnServers: [{ address: turn.server, username: USER, password: PASS }],
  };
  const offerer = await Peer.create(options);
  const answerer = await Peer.create(options);
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const offer = offerer.createOffer();
  assert.match(offer, /typ relay/);
  const answer = answerer.handleOffer(offer);
  assert.match(answer, /typ relay/);
  offerer.handleAnswer(answer);
  const [epA, epB] = await Promise.all([
    offerer.connect(),
    answerer.connect(),
  ]);
  const received = new Promise((resolve) => {
    epA.onchannel = (channel) => {
      channel.onmessage = (event) => resolve(Buffer.from(event.data).toString());
    };
  });
  const channel = epB.openChannel({ label: "echo" });
  channel.send(Buffer.from("via-relay"));
  assert.equal(await received, "via-relay");
  // Both peers bound channels at connect; traffic after the
  // bind rides ChannelData frames, not Send indications.
  assert.ok(turn.stats.bindCount >= 2, `binds=${turn.stats.bindCount}`);
  assert.ok(turn.stats.chanData > 0, "no ChannelData relayed");
});

// With a 3 s allocation/permission lifetime enforced by the fake,
// the relayed channel must still work after 5 s — only possible
// if both peers refresh their allocations and permissions.
test("refresh keeps the relay alive past the original expiry", { timeout: 30000 }, async (t) => {
  const turn = await fakeTurnServer({ lifetimeSeconds: 3, permissionSeconds: 3 });
  t.after(() => turn.close());
  const options = {
    localIps: ["10.11.12.13"],
    turnServers: [{ address: turn.server, username: USER, password: PASS }],
  };
  const offerer = await Peer.create(options);
  const answerer = await Peer.create(options);
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  assert.equal(offerer.turn.lifetimeSecs, 3);
  const offer = offerer.createOffer();
  const answer = answerer.handleOffer(offer);
  offerer.handleAnswer(answer);
  const [epA, epB] = await Promise.all([offerer.connect(), answerer.connect()]);

  const messages = [];
  let notify = null;
  epA.onchannel = (channel) => {
    channel.onmessage = (event) => {
      messages.push(Buffer.from(event.data).toString());
      notify?.();
    };
  };
  const nextMessage = () =>
    new Promise((resolve) => {
      if (messages.length) return resolve(messages.shift());
      notify = () => resolve(messages.shift());
    });
  const channel = epB.openChannel({ label: "echo" });
  channel.send(Buffer.from("before-expiry"));
  assert.equal(await nextMessage(), "before-expiry");

  // Both allocations and all permissions would have expired by
  // now without refresh.
  await new Promise((r) => setTimeout(r, 5000));
  channel.send(Buffer.from("after-expiry"));
  assert.equal(await nextMessage(), "after-expiry");
  assert.ok(turn.stats.refreshCount >= 2, `refreshes=${turn.stats.refreshCount}`);
  assert.ok(turn.stats.permReqCount >= 4, `permissions=${turn.stats.permReqCount}`);
});

// Regression: browsers advertise mDNS ".local" host candidates.
// TURN CreatePermission/ChannelBind name peer IPs, so non-IP
// candidates must be skipped at connect instead of crashing the
// XOR-PEER-ADDRESS encoder.
test("TURN connect skips mDNS remote candidates", { timeout: 30000 }, async (t) => {
  const turn = await fakeTurnServer();
  t.after(() => turn.close());
  const options = {
    localIps: ["10.11.12.13"],
    turnServers: [{ address: turn.server, username: USER, password: PASS }],
  };
  const offerer = await Peer.create(options);
  const answerer = await Peer.create(options);
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const mdnsLine =
    "a=candidate:9 1 udp 2130706431 cf6eac9e-a60c-49cc-ad95-206afc4dc605.local 9 typ host generation 0";
  const offer = offerer
    .createOffer()
    .replace("a=end-of-candidates", `${mdnsLine}\r\na=end-of-candidates`);
  const answer = answerer
    .handleOffer(offer)
    .replace("a=end-of-candidates", `${mdnsLine}\r\na=end-of-candidates`);
  offerer.handleAnswer(answer);
  const [epA, epB] = await Promise.all([offerer.connect(), answerer.connect()]);
  const received = new Promise((resolve) => {
    epA.onchannel = (channel) => {
      channel.onmessage = (event) => resolve(Buffer.from(event.data).toString());
    };
  });
  epB.openChannel({ label: "echo" }).send(Buffer.from("mdns-safe"));
  assert.equal(await received, "mdns-safe");
});

// Candidates trickled in after the connect-time snapshot must
// still get TURN permissions and channel bindings. Here the
// only reachable candidate on each side is the relay candidate,
// deliberately withheld from the SDP and trickled in while
// connect() is running; the fake server enforces permissions,
// so the echo only flows if trickle created them.
test("relay connection with trickled relay candidates", { timeout: 30000 }, async (t) => {
  const turn = await fakeTurnServer();
  t.after(() => turn.close());
  const options = {
    localIps: ["10.11.12.13"], // unreachable host candidate
    turnServers: [{ address: turn.server, username: USER, password: PASS }],
  };
  const offerer = await Peer.create(options);
  const answerer = await Peer.create(options);
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const relayLine = (sdp) => sdp.split("\r\n").find((l) => l.includes("typ relay"));
  const stripRelay = (sdp) =>
    sdp.split("\r\n").filter((l) => !l.includes("typ relay")).join("\r\n");

  const offer = offerer.createOffer();
  const offerRelay = relayLine(offer);
  assert.ok(offerRelay, `no relay candidate in offer:\n${offer}`);
  const answer = answerer.handleOffer(stripRelay(offer));
  const answerRelay = relayLine(answer);
  assert.ok(answerRelay, `no relay candidate in answer:\n${answer}`);
  offerer.handleAnswer(stripRelay(answer));

  const connecting = Promise.all([offerer.connect(), answerer.connect()]);
  // Trickle the relay candidates in only after connect() has
  // snapshotted the SDP-carried candidates.
  await new Promise((r) => setTimeout(r, 250));
  assert.equal(answerer.addRemoteCandidate(offerRelay), true);
  assert.equal(offerer.addRemoteCandidate(answerRelay), true);
  const [epA, epB] = await connecting;

  const received = new Promise((resolve) => {
    epA.onchannel = (channel) => {
      channel.onmessage = (event) => resolve(Buffer.from(event.data).toString());
    };
  });
  epB.openChannel({ label: "echo" }).send(Buffer.from("trickled-relay"));
  assert.equal(await received, "trickled-relay");
  assert.ok(turn.stats.permReqCount >= 2, `permissions=${turn.stats.permReqCount}`);
  assert.ok(turn.stats.bindCount >= 2, `binds=${turn.stats.bindCount}`);
});
