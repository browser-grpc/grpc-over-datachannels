// Issuer test with a synthetic WebAuthn credential: no
// browser, no authenticator. A WebCrypto P-256 keypair stands
// in for the authenticator; the test builds the registration
// attestation and the login assertion byte-for-byte the way a
// real authenticator would, then checks that the minted token
// verifies as a rendezvous token.
//
//   node --test examples/rendezvous-auth/issuer.test.mjs

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import { createIssuer, encodeCbor } from "./issuer.mjs";
import { verifyRendezvousToken } from "../../js/src/rendezvous.js";

const SECRET = "rendezvous-auth-test-secret";
const RP = "localhost";
const ORIGIN = "http://localhost:8080";
const enc = new TextEncoder();
const sha256 = (b) => new Uint8Array(createHash("sha256").update(b).digest());
const b64u = (b) => Buffer.from(b).toString("base64url");

function rawToDer(raw) {
  const ints = [raw.slice(0, 32), raw.slice(32, 64)].map((part) => {
    let p = part;
    while (p.length > 1 && p[0] === 0 && !(p[1] & 0x80)) p = p.slice(1);
    if (p[0] & 0x80) p = Uint8Array.from([0, ...p]);
    return Uint8Array.from([0x02, p.length, ...p]);
  });
  const body = Uint8Array.from([...ints[0], ...ints[1]]);
  return Uint8Array.from([0x30, body.length, ...body]);
}

function authData({ credentialId, coseKey, signCount, attested }) {
  const parts = [sha256(enc.encode(RP)), new Uint8Array([attested ? 0x41 : 0x01])];
  const count = new Uint8Array(4);
  new DataView(count.buffer).setUint32(0, signCount);
  parts.push(count);
  if (attested) {
    const credHead = new Uint8Array(18);
    new DataView(credHead.buffer).setUint16(16, credentialId.length);
    parts.push(credHead, credentialId, encodeCbor(coseKey));
  }
  return Uint8Array.from(parts.flatMap((p) => [...p]));
}

const clientData = (type, challenge) =>
  b64u(enc.encode(JSON.stringify({ type, challenge, origin: ORIGIN, crossOrigin: false })));

test("webauthn register + login mints a verifiable rendezvous token", async () => {
  const issuer = createIssuer({ secret: SECRET, rpId: RP, origin: ORIGIN, scopes: ["read"] });
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", keyPair.publicKey);
  const credentialId = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
  const coseKey = new Map([
    [1, 2],
    [3, -7],
    [-1, 1],
    [-2, new Uint8Array(Buffer.from(jwk.x, "base64url"))],
    [-3, new Uint8Array(Buffer.from(jwk.y, "base64url"))],
  ]);

  // Registration (attestation "none").
  const reg = issuer.registrationOptions("alice");
  const regAuth = authData({ credentialId, coseKey, signCount: 1, attested: true });
  await issuer.verifyRegistration("alice", {
    id: b64u(credentialId),
    response: {
      clientDataJSON: clientData("webauthn.create", reg.challenge),
      attestationObject: b64u(
        encodeCbor(new Map([["fmt", "none"], ["authData", regAuth], ["attStmt", new Map()]])),
      ),
    },
  });

  // Login (assertion), then token verification.
  const login = issuer.authenticationOptions("alice");
  const loginAuth = authData({ credentialId, coseKey, signCount: 2, attested: false });
  const clientJson = clientData("webauthn.get", login.challenge);
  const signed = Uint8Array.from([...loginAuth, ...sha256(new Uint8Array(Buffer.from(clientJson, "base64url")))]);
  const rawSig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keyPair.privateKey, signed),
  );
  const { token } = await issuer.verifyAuthentication("alice", {
    id: b64u(credentialId),
    response: {
      clientDataJSON: clientJson,
      authenticatorData: b64u(loginAuth),
      signature: b64u(rawToDer(rawSig)),
    },
  });
  const claims = await verifyRendezvousToken(SECRET, token, {
    issuer: RP,
    audience: "rendezvous",
  });
  assert.equal(claims.sub, "alice");
  assert.deepEqual(claims.scopes, ["read"]);

  // A replayed assertion (same challenge, consumed) rejects.
  await assert.rejects(
    issuer.verifyAuthentication("alice", {
      id: b64u(credentialId),
      response: {
        clientDataJSON: clientJson,
        authenticatorData: b64u(loginAuth),
        signature: b64u(rawToDer(rawSig)),
      },
    }),
    /challenge/,
  );
});
