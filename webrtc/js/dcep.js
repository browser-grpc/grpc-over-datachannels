// DCEP (RFC 8832): DATA_CHANNEL_OPEN/ACK over SCTP PPID 50, and the
// channel-type byte mapping to SCTP partial-reliability policies.

export const PPID_DCEP = 50;
export const PPID_STRING = 51;
export const PPID_BINARY = 53;
export const PPID_STRING_EMPTY = 56;
export const PPID_BINARY_EMPTY = 57;

export const MSG_OPEN = 0x03;
export const MSG_ACK = 0x02;

/** reliability: {kind:'reliable'} | {kind:'retransmits', count} | {kind:'lifetime', ms} */
export function channelTypeOf(params) {
  const base =
    params.reliability.kind === "retransmits" ? 0x01 : params.reliability.kind === "lifetime" ? 0x02 : 0x00;
  return params.ordered ? base : base | 0x80;
}

export function reliabilityParamOf(params) {
  if (params.reliability.kind === "retransmits") return params.reliability.count;
  if (params.reliability.kind === "lifetime") return params.reliability.ms;
  return 0;
}

export function paramsFromType(channelType, reliabilityParam) {
  const ordered = (channelType & 0x80) === 0;
  const kind = channelType & 0x7f;
  const reliability =
    kind === 0x01
      ? { kind: "retransmits", count: reliabilityParam }
      : kind === 0x02
        ? { kind: "lifetime", ms: reliabilityParam }
        : { kind: "reliable" };
  return { ordered, reliability };
}

export function sendOptionsOf(params) {
  return {
    unordered: !params.ordered,
    maxRetransmits: params.reliability.kind === "retransmits" ? params.reliability.count : null,
    maxLifetimeMs: params.reliability.kind === "lifetime" ? params.reliability.ms : null,
  };
}

export function encodeOpen(params) {
  const label = Buffer.from(params.label ?? "", "utf8");
  const protocol = Buffer.from(params.protocol ?? "", "utf8");
  const out = Buffer.alloc(12 + label.length + protocol.length);
  out[0] = MSG_OPEN;
  out[1] = channelTypeOf(params);
  out.writeUInt16BE(params.priority ?? 0, 2);
  out.writeUInt32BE(reliabilityParamOf(params), 4);
  out.writeUInt16BE(label.length, 8);
  out.writeUInt16BE(protocol.length, 10);
  label.copy(out, 12);
  protocol.copy(out, 12 + label.length);
  return out;
}

export function decodeOpen(data) {
  if (data.length < 12 || data[0] !== MSG_OPEN) return null;
  const labelLen = data.readUInt16BE(8);
  const protoLen = data.readUInt16BE(10);
  if (data.length < 12 + labelLen + protoLen) return null;
  const { ordered, reliability } = paramsFromType(data[1], data.readUInt32BE(4));
  return {
    ordered,
    reliability,
    priority: data.readUInt16BE(2),
    label: data.subarray(12, 12 + labelLen).toString("utf8"),
    protocol: data.subarray(12 + labelLen, 12 + labelLen + protoLen).toString("utf8"),
  };
}

export const encodeAck = () => Buffer.from([MSG_ACK]);
export const isAck = (data) => data.length > 0 && data[0] === MSG_ACK;

export const defaultParams = () => ({
  ordered: true,
  reliability: { kind: "reliable" },
  priority: 0,
  label: "",
  protocol: "",
});
