// mDNS A/AAAA response parsing (browser ".local" ICE candidates).

import { test } from "node:test";
import assert from "node:assert/strict";
import { buildQuery, parseAAAARecord, parseARecord } from "../mdns.js";

function nameWire(name) {
  const parts = [];
  for (const label of name.split(".")) {
    parts.push(Buffer.from([label.length]), Buffer.from(label));
  }
  parts.push(Buffer.from([0]));
  return Buffer.concat(parts);
}

function response(name, ip, type = 1) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(0x8400, 2); // response, authoritative
  header.writeUInt16BE(1, 4);
  header.writeUInt16BE(1, 6);
  const question = Buffer.concat([nameWire(name), Buffer.from([0, 1, 0, 1])]);
  const answerHead = Buffer.from([0xc0, 0x0c]); // compression pointer to the question
  const fixed = Buffer.alloc(10);
  fixed.writeUInt16BE(type, 0);
  fixed.writeUInt16BE(1, 2); // IN
  fixed.writeUInt32BE(120, 4); // TTL
  fixed.writeUInt16BE(ip.length, 8);
  return Buffer.concat([header, question, answerHead, fixed, Buffer.from(ip)]);
}

test("parseARecord extracts the A record for the queried name", () => {
  const packet = response("abc-123.local", [192, 168, 1, 20]);
  assert.equal(parseARecord(packet, "abc-123.local"), "192.168.1.20");
  assert.equal(parseARecord(packet, "other.local"), null);
  assert.equal(parseARecord(Buffer.from([1, 2, 3]), "abc-123.local"), null);
});

test("parseAAAARecord extracts the AAAA record for the queried name", () => {
  const fd00_1234 = [0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12, 0x34];
  const packet = response("abc-123.local", fd00_1234, 28);
  assert.equal(parseAAAARecord(packet, "abc-123.local"), "fd00::1234");
  assert.equal(parseAAAARecord(packet, "other.local"), null);
  assert.equal(parseARecord(packet, "abc-123.local"), null);
  const loopback = response("abc-123.local", [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1], 28);
  assert.equal(parseAAAARecord(loopback, "abc-123.local"), "::1");
});

test("buildQuery asks for both families with the QU bit", () => {
  const query = buildQuery(0, "abc-123.local");
  assert.equal(query.readUInt16BE(4), 2); // QDCOUNT
  const nameLen = nameWire("abc-123.local").length;
  const first = 12 + nameLen;
  assert.deepEqual([...query.subarray(first, first + 4)], [0, 1, 0x80, 1]);
  const second = first + 4 + nameLen;
  assert.deepEqual([...query.subarray(second, second + 4)], [0, 28, 0x80, 1]);
});
