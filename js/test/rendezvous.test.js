import assert from "node:assert/strict";
import test from "node:test";

import {
  fetchRendezvousDescriptor,
  synthesizeRendezvousOffer,
} from "../src/rendezvous.js";

test("rendezvous offer synthesis: ICE-lite at session level, descriptor values verbatim", () => {
  const descriptor = {
    host: "203.0.113.10",
    port: 8443,
    iceUfrag: "abcd1234",
    icePwd: "0123456789abcdefghijkl",
    fingerprint:
      "AB:CD:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00",
    setup: "passive",
  };
  const sdp = synthesizeRendezvousOffer(descriptor);
  const lines = sdp.split("\r\n");
  const iceLiteAt = lines.indexOf("a=ice-lite");
  const mediaAt = lines.findIndex((line) => line.startsWith("m=application"));
  assert.ok(iceLiteAt > 0, "ice-lite present");
  assert.ok(iceLiteAt < mediaAt, "ice-lite is session-level (before the m= line)");
  assert.ok(lines.includes("a=ice-ufrag:abcd1234"));
  assert.ok(lines.includes("a=ice-pwd:0123456789abcdefghijkl"));
  assert.ok(lines.includes(`a=fingerprint:sha-256 ${descriptor.fingerprint}`));
  assert.ok(lines.includes("a=setup:passive"));
  assert.ok(
    lines.some((line) =>
      line.startsWith("a=candidate:1 1 udp 2130706431 203.0.113.10 8443 typ host"),
    ),
  );
  assert.ok(lines.includes("a=end-of-candidates"));
  assert.equal(synthesizeRendezvousOffer({ ...descriptor, setup: undefined }).includes("a=setup:passive"), true);
});

test("fetchRendezvousDescriptor: parses and validates descriptor JSON", async () => {
  const good = {
    host: "203.0.113.10",
    port: 8443,
    iceUfrag: "abcd1234",
    icePwd: "0123456789abcdefghijkl",
    fingerprint: "AB:CD",
    setup: "passive",
  };
  const fetchOk = async () => ({ ok: true, status: 200, json: async () => good });
  assert.deepEqual(
    await fetchRendezvousDescriptor("https://x/.well-known/grpc-dc-rendezvous.json", { fetchImpl: fetchOk }),
    good,
  );
  const fetch404 = async () => ({ ok: false, status: 404, json: async () => ({}) });
  await assert.rejects(
    fetchRendezvousDescriptor("https://x/d.json", { fetchImpl: fetch404 }),
    /404/,
  );
  const fetchBad = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ host: "203.0.113.10" }),
  });
  await assert.rejects(
    fetchRendezvousDescriptor("https://x/d.json", { fetchImpl: fetchBad }),
    /missing port/,
  );
});

// ---------------------------------------------------------------------------
// Rendezvous auth: one fixed cross-stack token vector (the Go
// and Rust suites verify this exact token), plus accept /
// reject / expired / wrong-scope through a real Server
// dispatch over a loopback channel pair.

import { Channel, Server, StatusCode, memoryDataChannelPair } from "../index.js";
import {
  decodeRendezvousClaims,
  encodeRendezvousClaims,
  issueRendezvousToken,
  verifyRendezvousToken,
} from "../src/rendezvous.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";

const VECTOR_SECRET = "rendezvous-auth-test-secret";
const VECTOR_TOKEN =
  "CgVhbGljZRIGaXNzdWVyGgpyZW5kZXp2b3VzIICumaQPKIDiz6oGMIDiz6oGOgRyZWFkOgV3cml0ZUIFdmVjLTE.3KLgA4zxXSOPZn2jw1lNkYqm5Urijo37qwU0NVMkIWM";
const VECTOR_CLAIMS = {
  sub: "alice",
  iss: "issuer",
  aud: "rendezvous",
  exp: 4102444800,
  nbf: 1700000000,
  iat: 1700000000,
  scopes: ["read", "write"],
  jti: "vec-1",
};

test("rendezvous auth: fixed cross-stack token vector verifies", async () => {
  const claims = await verifyRendezvousToken(VECTOR_SECRET, VECTOR_TOKEN, {
    issuer: "issuer",
    audience: "rendezvous",
    nowSeconds: 1700000100,
  });
  assert.deepEqual(claims, VECTOR_CLAIMS);
  assert.equal(
    Buffer.from(encodeRendezvousClaims(VECTOR_CLAIMS)).toString("hex"),
    "0a05616c69636512066973737565721a0a72656e64657a766f75732080ae99a40f2880e2cfaa063080e2cfaa063a04726561643a05777269746542057665632d31",
  );
  assert.deepEqual(decodeRendezvousClaims(encodeRendezvousClaims(VECTOR_CLAIMS)), VECTOR_CLAIMS);
  assert.equal(await issueRendezvousToken(VECTOR_SECRET, VECTOR_CLAIMS), VECTOR_TOKEN);
});

test("rendezvous auth: expired, not-yet-valid and bad-signature tokens reject", async () => {
  await assert.rejects(
    verifyRendezvousToken(VECTOR_SECRET, VECTOR_TOKEN, { nowSeconds: 4102444800 }),
    /expired/,
  );
  await assert.rejects(
    verifyRendezvousToken(VECTOR_SECRET, VECTOR_TOKEN, { nowSeconds: 1699999999 }),
    /not yet valid/,
  );
  await assert.rejects(verifyRendezvousToken("wrong-secret", VECTOR_TOKEN, {}), /signature/);
  await assert.rejects(verifyRendezvousToken(VECTOR_SECRET, "not-a-token", {}), /malformed/);
});

function authSetup(scopes) {
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  let seenClaims = null;
  server.addService(
    createEchoService({
      async unary(req, ctx) {
        seenClaims = ctx.claims;
        return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
      },
      async *serverStream() {},
      async clientStream() {
        return new EchoResponse({ message: "", index: 0 });
      },
      async *bidi() {},
    }),
  );
  server.requireRendezvousAuth(
    (token) =>
      verifyRendezvousToken(VECTOR_SECRET, token, {
        issuer: "issuer",
        audience: "rendezvous",
        nowSeconds: 1700000100,
      }),
    scopes,
  );
  server.serve(b);
  return { channel: new Channel(a), seenClaims: () => seenClaims };
}

test("rendezvous auth: server accepts a scoped token and exposes ctx.claims", async () => {
  const { channel, seenClaims } = authSetup({ "/echo.Echo/Unary": ["read"] });
  const client = new EchoClient(
    channel.withMetadata({ authorization: `Bearer ${VECTOR_TOKEN}` }),
  );
  const resp = await client.unary(new EchoRequest({ message: "hi" }));
  assert.equal(resp.message, "echo: hi");
  assert.equal(seenClaims().sub, "alice");
});

test("rendezvous auth: missing token fails UNAUTHENTICATED (16)", async () => {
  const { channel } = authSetup({});
  const client = new EchoClient(channel);
  await assert.rejects(client.unary(new EchoRequest({ message: "hi" })), (e) => {
    assert.equal(e.code, StatusCode.UNAUTHENTICATED);
    return true;
  });
});

test("rendezvous auth: under-scoped token fails PERMISSION_DENIED (7)", async () => {
  const { channel } = authSetup({ "/echo.Echo/Unary": ["admin"] });
  const client = new EchoClient(
    channel.withMetadata({ authorization: `Bearer ${VECTOR_TOKEN}` }),
  );
  await assert.rejects(client.unary(new EchoRequest({ message: "hi" })), (e) => {
    assert.equal(e.code, StatusCode.PERMISSION_DENIED);
    return true;
  });
});
