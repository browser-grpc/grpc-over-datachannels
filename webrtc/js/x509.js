// Minimal X.509: generate self-signed ECDSA P-256 certificates (DER)
// with Node's crypto, and extract a peer certificate's EC public key.
// Certificate signatures are not verified — WebRTC pins certificates
// by SHA-256 fingerprint in SDP (see fingerprint()).

import crypto from "node:crypto";

function lenBytes(len) {
  if (len < 128) return Buffer.from([len]);
  const bytes = [];
  for (let n = len; n > 0; n >>= 8) bytes.unshift(n & 0xff);
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}

export function tlv(tag, content) {
  return Buffer.concat([Buffer.from([tag]), lenBytes(content.length), content]);
}

const seq = (content) => tlv(0x30, content);

function derInt(bytes) {
  let start = 0;
  while (start < bytes.length - 1 && bytes[start] === 0) start++;
  let body = bytes.subarray(start);
  if (body[0] & 0x80) body = Buffer.concat([Buffer.from([0]), body]);
  return tlv(0x02, body);
}

function derOid(arcs) {
  const content = [arcs[0] * 40 + arcs[1]];
  for (const arc of arcs.slice(2)) {
    const groups = [arc & 0x7f];
    for (let rest = arc >> 7; rest > 0; rest >>= 7) {
      groups.unshift((rest & 0x7f) | 0x80);
    }
    content.push(...groups);
  }
  return tlv(0x06, Buffer.from(content));
}

const algEcdsaSha256 = () => seq(derOid([1, 2, 840, 10045, 4, 3, 2]));

function name(cn) {
  const rdn = seq(Buffer.concat([derOid([2, 5, 4, 3]), tlv(0x0c, Buffer.from(cn, "utf8"))]));
  return seq(tlv(0x31, rdn));
}

function utcTime(epochMs) {
  const d = new Date(epochMs);
  const p = (n) => String(n).padStart(2, "0");
  const text =
    p(d.getUTCFullYear() % 100) + p(d.getUTCMonth() + 1) + p(d.getUTCDate()) +
    p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds()) + "Z";
  return tlv(0x17, Buffer.from(text, "ascii"));
}

/** Point (0x04||X||Y) from a KeyObject, via JWK. */
export function publicKeyPoint(publicKey) {
  const jwk = publicKey.export({ format: "jwk" });
  return Buffer.concat([
    Buffer.from([0x04]),
    Buffer.from(jwk.x, "base64url"),
    Buffer.from(jwk.y, "base64url"),
  ]);
}

export function pointToPublicKey(point) {
  if (point.length !== 65 || point[0] !== 0x04) throw new Error("bad EC point");
  return crypto.createPublicKey({
    format: "jwk",
    key: {
      kty: "EC",
      crv: "P-256",
      x: point.subarray(1, 33).toString("base64url"),
      y: point.subarray(33, 65).toString("base64url"),
    },
  });
}

export class Certificate {
  constructor(der, privateKey, publicKey) {
    this.der = der;
    this.privateKey = privateKey;
    this.publicKey = publicKey;
  }

  static generate(cn = "dc-webrtc") {
    const { publicKey, privateKey } = crypto.generateKeyPairSync("ec", {
      namedCurve: "P-256",
    });
    const serial = crypto.randomBytes(16);
    const now = Date.now();
    const spki = seq(
      Buffer.concat([
        seq(Buffer.concat([derOid([1, 2, 840, 10045, 2, 1]), derOid([1, 2, 840, 10045, 3, 1, 7])])),
        tlv(0x03, Buffer.concat([Buffer.from([0]), publicKeyPoint(publicKey)])),
      ]),
    );
    const tbs = seq(
      Buffer.concat([
        tlv(0xa0, derInt(Buffer.from([2]))),
        derInt(serial),
        algEcdsaSha256(),
        name(cn),
        seq(Buffer.concat([utcTime(now - 86_400_000), utcTime(now + 30 * 86_400_000)])),
        name(cn),
        spki,
      ]),
    );
    const signature = crypto.sign("sha256", tbs, privateKey);
    const der = seq(Buffer.concat([tbs, algEcdsaSha256(), tlv(0x03, Buffer.concat([Buffer.from([0]), signature]))]));
    return new Certificate(der, privateKey, publicKey);
  }

  fingerprint() {
    return fingerprintOfDer(this.der);
  }
}

export function fingerprintOfDer(der) {
  const hash = crypto.createHash("sha256").update(der).digest();
  return [...hash].map((b) => b.toString(16).padStart(2, "0").toUpperCase()).join(":");
}

/** Extract the EC public key (KeyObject) from a DER certificate. */
export function parsePublicKey(der) {
  const cert = new crypto.X509Certificate(der);
  return cert.publicKey;
}
