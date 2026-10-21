// WebRTC-Direct: signaling-free client->server connections.
// The dialer needs only the listener's address + certhash (its
// libp2p multiaddr); a wrong certhash must fail the handshake.
// The TURN case is the symmetric-NAT shape: DTLS rides a TURN
// allocation, never a direct packet to the listener.

import assert from "node:assert/strict";
import test from "node:test";
import {
  DirectListener,
  certhashOfCert,
  directDial,
  directDialMultiaddr,
  directDialTurnMultiaddr,
  fingerprintOfDigest,
  parseCerthash,
  parseDirectMultiaddr,
} from "../direct.js";
import { Certificate } from "../x509.js";
import { PASS, USER, fakeTurnServer } from "./fake_turn.js";

async function echoServer(listener) {
  const endpointPromise = listener.accept();
  const state = { got: null };
  state.done = (async () => {
    const endpoint = await endpointPromise;
    const channel = await new Promise((resolve) => (endpoint.onchannel = resolve));
    channel.onmessage = (event) => {
      state.got = Buffer.from(event.data).toString();
      channel.send(Buffer.from("direct-reply"));
    };
    endpoint._state = state;
    return endpoint;
  })();
  return state;
}

async function waitFor(fn, ms = 10000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const v = fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 10));
  }
  return null;
}

test("certhash and multiaddr round trip", () => {
  const cert = Certificate.generate("listener");
  const hash = certhashOfCert(cert);
  assert.ok(hash.startsWith("fEi"), hash);
  const digest = parseCerthash(hash);
  assert.equal(fingerprintOfDigest(digest), cert.fingerprint());
  const parsed = parseDirectMultiaddr(
    `/ip4/203.0.113.7/udp/4001/webrtc-direct/certhash/${hash}`,
  );
  assert.deepEqual(parsed.remote, { address: "203.0.113.7", port: 4001 });
  assert.ok(digest.equals(parsed.digest));
  assert.equal(parseCerthash("fAAA"), null);
  assert.equal(parseDirectMultiaddr("/ip4/1.2.3.4/tcp/4001/webrtc-direct"), null);
});

test("direct client-server echo", { timeout: 30000 }, async () => {
  const listener = await DirectListener.bind({});
  const server = await echoServer(listener);
  const client = await directDialMultiaddr(listener.multiaddr());
  const channel = client.openChannel({ label: "echo" });
  const replies = [];
  channel.onmessage = (e) => replies.push(Buffer.from(e.data).toString());
  channel.send(Buffer.from("direct-hello"));
  assert.equal(await waitFor(() => replies[0]), "direct-reply");
  assert.equal(server.got, "direct-hello");
  await client.closeDirect();
  await (await server.done).close();
  listener.close();
});

test("direct over TURN echo (symmetric-NAT shape)", { timeout: 30000 }, async () => {
  const turn = await fakeTurnServer();
  try {
    const listener = await DirectListener.bind({});
    const server = await echoServer(listener);
    const client = await directDialTurnMultiaddr(listener.multiaddr(), {
      turn: { address: turn.server, username: USER, password: PASS },
    });
    const channel = client.openChannel({ label: "echo" });
    const replies = [];
    channel.onmessage = (e) => replies.push(Buffer.from(e.data).toString());
    channel.send(Buffer.from("via-turn-direct"));
    assert.equal(await waitFor(() => replies[0]), "direct-reply");
    assert.equal(server.got, "via-turn-direct");
    await client.closeDirect();
    await (await server.done).close();
    listener.close();
  } finally {
    turn.close();
  }
});


test("direct concurrent dialers", { timeout: 60000 }, async () => {
  const listener = await DirectListener.bind({});
  try {
    const servers = await Promise.all(
      Array.from({ length: 4 }, () => echoServer(listener)),
    );
    const clients = await Promise.all(
      Array.from({ length: 4 }, async (_, i) => {
        const client = await directDialMultiaddr(listener.multiaddr());
        const channel = client.openChannel({ label: "echo" });
        const replies = [];
        channel.onmessage = (e) => replies.push(Buffer.from(e.data).toString());
        channel.send(Buffer.from(`hello-${i}`));
        assert.equal(await waitFor(() => replies[0], 20000), "direct-reply");
        return client;
      }),
    );
    const got = servers.map((s) => s.got).sort();
    assert.deepEqual(got, ["hello-0", "hello-1", "hello-2", "hello-3"]);
    for (const client of clients) await client.closeDirect();
    for (const server of servers) await (await server.done).close();
  } finally {
    listener.close();
  }
});

test("direct over TURN refresh past lifetime", { timeout: 60000 }, async () => {
  const turn = await fakeTurnServer({ lifetimeSeconds: 3, permissionSeconds: 3 });
  try {
    const listener = await DirectListener.bind({});
    const server = await echoServer(listener);
    const client = await directDialTurnMultiaddr(listener.multiaddr(), {
      turn: { address: turn.server, username: USER, password: PASS },
    });
    const channel = client.openChannel({ label: "echo" });
    const replies = [];
    channel.onmessage = (e) => replies.push(Buffer.from(e.data).toString());
    channel.send(Buffer.from("via-turn-direct"));
    assert.equal(await waitFor(() => replies[0]), "direct-reply");
    // Past the 3 s allocation lifetime: the fake drops relayed
    // traffic for expired allocations, so this second echo only
    // works if the dialer refreshed in the background.
    await new Promise((r) => setTimeout(r, 5000));
    channel.send(Buffer.from("after-expiry"));
    assert.equal(await waitFor(() => replies[1]), "direct-reply");
    assert.equal(server.got, "after-expiry");
    assert.ok(turn.stats.refreshCount >= 1, `refreshes=${turn.stats.refreshCount}`);
    await client.closeDirect();
    await (await server.done).close();
    listener.close();
  } finally {
    turn.close();
  }
});

test("direct dial rejects wrong certhash", { timeout: 30000 }, async () => {
  const listener = await DirectListener.bind({});
  const accepting = listener.accept().catch(() => null);
  const other = Certificate.generate("other");
  await assert.rejects(
    directDial(
      { address: "127.0.0.1", port: listener.address.port },
      certhashOfCert(other),
    ),
  );
  await accepting;
  listener.close();
});
