// mDNS A-record response parsing (browser ".local" ICE candidates).

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseARecord } from "../mdns.js";

function nameWire(name) {
  const parts = [];
  for (const label of name.split(".")) {
    parts.push(Buffer.from([label.length]), Buffer.from(label));
  }
  parts.push(Buffer.from([0]));
  return Buffer.concat(parts);
}

function response(name, ip) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(0x8400, 2); // response, authoritative
  header.writeUInt16BE(1, 4);
  header.writeUInt16BE(1, 6);
  const question = Buffer.concat([nameWire(name), Buffer.from([0, 1, 0, 1])]);
  const answerHead = Buffer.from([0xc0, 0x0c]); // compression pointer to the question
  const fixed = Buffer.alloc(10);
  fixed.writeUInt16BE(1, 0); // A
  fixed.writeUInt16BE(1, 2); // IN
  fixed.writeUInt32BE(120, 4); // TTL
  fixed.writeUInt16BE(4, 8);
  return Buffer.concat([header, question, answerHead, fixed, Buffer.from(ip)]);
}

test("parseARecord extracts the A record for the queried name", () => {
  const packet = response("abc-123.local", [192, 168, 1, 20]);
  assert.equal(parseARecord(packet, "abc-123.local"), "192.168.1.20");
  assert.equal(parseARecord(packet, "other.local"), null);
  assert.equal(parseARecord(Buffer.from([1, 2, 3]), "abc-123.local"), null);
});
