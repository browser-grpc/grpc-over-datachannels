// WebAuthn issuer for rendezvous auth (Node, stdlib only).
//
// The split this example demonstrates:
//
//   browser --WebAuthn (HTTPS)--> issuer (this module)
//   issuer  --mints--> rendezvous bearer token (HMAC claims)
//   browser --token over DataChannel--> rendezvous server
//
// The rendezvous server never sees WebAuthn data: it only
// verifies the HMAC token (see js/src/rendezvous.js). WebAuthn
// verification here uses only node:crypto + WebCrypto:
// challenge/origin/rpId checks, attestation "none" with a
// COSE ES256 credential key at registration, and the assertion
// signature (ECDSA P-256/SHA-256 over
// authenticatorData || SHA-256(clientDataJSON)) at login.
//
// In-memory user store and single-process challenges: a real
// deployment persists credentials and shares challenges
// across replicas, but the verification steps are the same.

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

import { issueRendezvousToken } from "../../js/src/rendezvous.js";

const enc = new TextEncoder();
const b64u = (bytes) =>
  Buffer.from(bytes).toString("base64url");
const unb64u = (text) => new Uint8Array(Buffer.from(text, "base64url"));
const sha256 = (bytes) => new Uint8Array(createHash("sha256").update(bytes).digest());

// --- minimal CBOR (the subset attestation objects use) ------

export function decodeCbor(bytes, offset = 0) {
  const head = bytes[offset];
  const major = head >> 5;
  let arg = head & 0x1f;
  let pos = offset + 1;
  if (arg === 24) arg = bytes[pos++];
  else if (arg === 25) { arg = (bytes[pos] << 8) | bytes[pos + 1]; pos += 2; }
  else if (arg === 26) { arg = Number(new DataView(bytes.buffer, bytes.byteOffset + pos, 4).getUint32(0)); pos += 4; }
  else if (arg === 27) { arg = Number(new DataView(bytes.buffer, bytes.byteOffset + pos, 8).getBigUint64(0)); pos += 8; }
  switch (major) {
    case 0: return [arg, pos];
    case 1: return [-1 - arg, pos];
    case 2: return [bytes.slice(pos, pos + arg), pos + arg];
    case 3: return [new TextDecoder().decode(bytes.slice(pos, pos + arg)), pos + arg];
    case 4: {
      const arr = [];
      for (let i = 0; i < arg; i++) { const [v, p] = decodeCbor(bytes, pos); arr.push(v); pos = p; }
      return [arr, pos];
    }
    case 5: {
      const map = new Map();
      for (let i = 0; i < arg; i++) {
        const [k, p1] = decodeCbor(bytes, pos);
        const [v, p2] = decodeCbor(bytes, p1);
        map.set(k, v);
        pos = p2;
      }
      return [map, pos];
    }
    case 7: return [arg === 21 ? true : arg === 20 ? false : null, pos];
    default: throw new Error(`unsupported CBOR major ${major}`);
  }
}

export function encodeCbor(value) {
  const out = [];
  const head = (major, arg) => {
    if (arg < 24) out.push((major << 5) | arg);
    else if (arg < 256) out.push((major << 5) | 24, arg);
    else if (arg < 65536) out.push((major << 5) | 25, arg >> 8, arg & 0xff);
    else out.push((major << 5) | 26, (arg >>> 24) & 0xff, (arg >> 16) & 0xff, (arg >> 8) & 0xff, arg & 0xff);
  };
  const write = (v) => {
    if (typeof v === "number") {
      if (v >= 0) head(0, v); else head(1, -1 - v);
    } else if (typeof v === "string") {
      const b = enc.encode(v); head(3, b.length); out.push(...b);
    } else if (v instanceof Uint8Array) {
      head(2, v.length); out.push(...v);
    } else if (Array.isArray(v)) {
      head(4, v.length); for (const item of v) write(item);
    } else if (v instanceof Map) {
      head(5, v.size); for (const [k, item] of v) { write(k); write(item); }
    } else if (v === true) out.push(0xf5);
    else if (v === false) out.push(0xf4);
    else if (v === null) out.push(0xf6);
    else throw new Error("unencodable CBOR value");
  };
  write(value);
  return new Uint8Array(out);
}

// DER ECDSA signature -> raw r || s (WebCrypto's format).
function derToRaw(der, size = 32) {
  let pos = 0;
  if (der[pos++] !== 0x30) throw new Error("bad DER signature");
  let len = der[pos++];
  if (len & 0x80) pos += len & 0x7f;
  const readInt = () => {
    if (der[pos++] !== 0x02) throw new Error("bad DER integer");
    const n = der[pos++];
    const slice = der.slice(pos, pos + n);
    pos += n;
    const trimmed = slice.length > size ? slice.slice(slice.length - size) : slice;
    const out = new Uint8Array(size);
    out.set(trimmed, size - trimmed.length);
    return out;
  };
  const raw = new Uint8Array(2 * size);
  raw.set(readInt(), 0);
  raw.set(readInt(), size);
  return raw;
}

function parseAuthenticatorData(authData, { withAttestation }) {
  if (authData.length < 37) throw new Error("short authenticatorData");
  const rpIdHash = authData.slice(0, 32);
  const flags = authData[32];
  const signCount = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
  let pos = 37;
  let credential = null;
  if (withAttestation) {
    if (!(flags & 0x40)) throw new Error("no attested credential data");
    pos += 16; // AAGUID
    const credLen = (authData[pos] << 8) | authData[pos + 1];
    pos += 2;
    const credentialId = authData.slice(pos, pos + credLen);
    pos += credLen;
    const [coseKey, end] = decodeCbor(authData, pos);
    pos = end;
    credential = { credentialId, coseKey };
  }
  return { rpIdHash, flags, signCount, credential, consumed: pos };
}

function coseToJwk(coseKey) {
  if (coseKey.get(1) !== 2 || coseKey.get(3) !== -7) {
    throw new Error("only COSE ES256 (P-256) credentials are supported");
  }
  return {
    kty: "EC",
    crv: "P-256",
    x: b64u(coseKey.get(-2)),
    y: b64u(coseKey.get(-3)),
  };
}

function checkClientData(clientDataBytes, { type, challenge, origin }) {
  const data = JSON.parse(new TextDecoder().decode(clientDataBytes));
  if (data.type !== type) throw new Error(`clientData type ${data.type}, want ${type}`);
  if (data.challenge !== challenge) throw new Error("challenge mismatch");
  if (data.origin !== origin) throw new Error(`origin ${data.origin}, want ${origin}`);
  return data;
}

function checkRp(authData, rpId) {
  const expected = sha256(enc.encode(rpId));
  if (!timingSafeEqual(Buffer.from(authData.rpIdHash), Buffer.from(expected))) {
    throw new Error("rpId hash mismatch");
  }
  if (!(authData.flags & 0x01)) throw new Error("user presence flag not set");
}

/**
 * Create an issuer. `secret` is the rendezvous HMAC secret the
 * rendezvous server is configured with; `rpId`/`origin` bind
 * WebAuthn to this site; `scopes` are granted on login;
 * `tokenTtlSeconds` bounds the minted token.
 */
export function createIssuer({ secret, rpId, origin, scopes = ["read"], tokenTtlSeconds = 3600 }) {
  const users = new Map(); // name -> { credentialId, jwk, signCount }
  const challenges = new Map(); // name -> challenge (base64url)

  const newChallenge = (name) => {
    const challenge = b64u(randomBytes(32));
    challenges.set(name, challenge);
    return challenge;
  };
  const takeChallenge = (name) => {
    const challenge = challenges.get(name);
    challenges.delete(name);
    if (!challenge) throw new Error("no pending challenge; restart the ceremony");
    return challenge;
  };

  return {
    registrationOptions(name) {
      return {
        challenge: newChallenge(name),
        rp: { id: rpId, name: "grpc-dc rendezvous" },
        user: { id: b64u(enc.encode(name)), name, displayName: name },
        pubKeyCredParams: [{ type: "public-key", alg: -7 }],
        attestation: "none",
        authenticatorSelection: { userVerification: "preferred" },
      };
    },

    async verifyRegistration(name, response) {
      const challenge = takeChallenge(name);
      checkClientData(unb64u(response.response.clientDataJSON), {
        type: "webauthn.create",
        challenge,
        origin,
      });
      const attestation = decodeCbor(unb64u(response.response.attestationObject))[0];
      if (attestation.get("fmt") !== "none") throw new Error("only attestation 'none' is accepted");
      const authData = parseAuthenticatorData(attestation.get("authData"), { withAttestation: true });
      checkRp(authData, rpId);
      users.set(name, {
        credentialId: b64u(authData.credential.credentialId),
        jwk: coseToJwk(authData.credential.coseKey),
        signCount: authData.signCount,
      });
      return { registered: true };
    },

    authenticationOptions(name) {
      if (!users.has(name)) throw new Error(`unknown user ${name}`);
      return {
        challenge: newChallenge(name),
        rpId,
        allowCredentials: [{ type: "public-key", id: users.get(name).credentialId }],
        userVerification: "preferred",
      };
    },

    async verifyAuthentication(name, response) {
      const user = users.get(name);
      if (!user) throw new Error(`unknown user ${name}`);
      if (response.id !== user.credentialId) throw new Error("credential mismatch");
      const challenge = takeChallenge(name);
      const clientData = unb64u(response.response.clientDataJSON);
      checkClientData(clientData, { type: "webauthn.get", challenge, origin });
      const authDataBytes = unb64u(response.response.authenticatorData);
      const authData = parseAuthenticatorData(authDataBytes, { withAttestation: false });
      checkRp(authData, rpId);
      if (authData.signCount !== 0 && authData.signCount <= user.signCount) {
        throw new Error("sign count did not increase (possible clone)");
      }
      user.signCount = authData.signCount;
      const key = await crypto.subtle.importKey(
        "jwk",
        user.jwk,
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["verify"],
      );
      const signed = new Uint8Array(authDataBytes.length + 32);
      signed.set(authDataBytes, 0);
      signed.set(sha256(clientData), authDataBytes.length);
      const ok = await crypto.subtle.verify(
        { name: "ECDSA", hash: "SHA-256" },
        key,
        derToRaw(unb64u(response.response.signature)),
        signed,
      );
      if (!ok) throw new Error("assertion signature did not verify");
      const now = Math.floor(Date.now() / 1000);
      const token = await issueRendezvousToken(secret, {
        sub: name,
        iss: rpId,
        aud: "rendezvous",
        iat: now,
        exp: now + tokenTtlSeconds,
        scopes,
        jti: b64u(randomBytes(9)),
      });
      return { token, expiresAt: now + tokenTtlSeconds };
    },
  };
}
