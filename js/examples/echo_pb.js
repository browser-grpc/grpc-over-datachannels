// Hand-written protobuf messages for proto/echo.proto.
//
// Deliberately minimal (two messages) so the example needs no protobuf
// codegen dependency — real projects import classes from protobuf-es /
// protobufjs and adapt them to the {encode, decode} shape, or generate
// this file with protoc's JS generator. The wire bytes are genuine
// protobuf: EchoRequest{message:"hi", count:2} encodes to 0a0268691002.

function varintBytes(value) {
  let n = BigInt.asUintN(64, BigInt(value));
  const out = [];
  while (n > 0x7fn) {
    out.push(Number((n & 0x7fn) | 0x80n));
    n >>= 7n;
  }
  out.push(Number(n));
  return out;
}

class Reader {
  constructor(bytes) {
    this.bytes = bytes;
    this.pos = 0;
  }
  varint() {
    let result = 0n;
    let shift = 0n;
    for (;;) {
      if (this.pos >= this.bytes.length) throw new Error("truncated varint");
      const byte = this.bytes[this.pos++];
      result |= BigInt(byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) return result;
      shift += 7n;
      if (shift >= 64n) throw new Error("varint too long");
    }
  }
  field() {
    if (this.pos >= this.bytes.length) return null;
    const tag = this.varint();
    const field = Number(tag >> 3n);
    const wire = Number(tag & 7n);
    switch (wire) {
      case 0:
        return [field, wire, this.varint()];
      case 2: {
        const len = Number(this.varint());
        const value = this.bytes.slice(this.pos, this.pos + len);
        if (value.length !== len) throw new Error("truncated bytes field");
        this.pos += len;
        return [field, wire, value];
      }
      case 1: {
        const value = this.bytes.slice(this.pos, this.pos + 8);
        this.pos += 8;
        return [field, wire, value];
      }
      case 5: {
        const value = this.bytes.slice(this.pos, this.pos + 4);
        this.pos += 4;
        return [field, wire, value];
      }
      default:
        throw new Error(`bad wire type ${wire}`);
    }
  }
}

function putStringField(out, field, value) {
  if (!value) return;
  const bytes = new TextEncoder().encode(value);
  out.push(...varintBytes((field << 3) | 2), ...varintBytes(bytes.length), ...bytes);
}

function putInt32Field(out, field, value) {
  if (!value) return;
  out.push(...varintBytes((field << 3) | 0), ...varintBytes(value));
}

export class EchoRequest {
  constructor({ message = "", count = 0, delayMs = 0 } = {}) {
    this.message = message;
    this.count = count;
    this.delayMs = delayMs;
  }
  static encode(msg) {
    const out = [];
    putStringField(out, 1, msg.message);
    putInt32Field(out, 2, msg.count);
    putInt32Field(out, 3, msg.delayMs);
    return new Uint8Array(out);
  }
  static decode(bytes) {
    const msg = new EchoRequest();
    const reader = new Reader(bytes);
    let f;
    while ((f = reader.field()) !== null) {
      const [field, , value] = f;
      if (field === 1) msg.message = new TextDecoder().decode(value);
      else if (field === 2) msg.count = Number(BigInt.asIntN(32, value));
      else if (field === 3) msg.delayMs = Number(BigInt.asIntN(32, value));
    }
    return msg;
  }
}

export class EchoResponse {
  constructor({ message = "", index = 0 } = {}) {
    this.message = message;
    this.index = index;
  }
  static encode(msg) {
    const out = [];
    putStringField(out, 1, msg.message);
    putInt32Field(out, 2, msg.index);
    return new Uint8Array(out);
  }
  static decode(bytes) {
    const msg = new EchoResponse();
    const reader = new Reader(bytes);
    let f;
    while ((f = reader.field()) !== null) {
      const [field, , value] = f;
      if (field === 1) msg.message = new TextDecoder().decode(value);
      else if (field === 2) msg.index = Number(BigInt.asIntN(32, value));
    }
    return msg;
  }
}
