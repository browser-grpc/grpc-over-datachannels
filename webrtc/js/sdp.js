// SDP (RFC 8866) offer/answer subset for one datachannel m-section —
// mirroring webrtc/rust/src/sdp.rs.

import { Candidate } from "./ice.js";

export function generate(desc, isOffer) {
  const lines = [
    "v=0",
    "o=- 4611733050420606744 2 IN IP4 127.0.0.1",
    "s=-",
    "t=0 0",
    "a=group:BUNDLE 0",
    "a=extmap-allow-mixed",
    "a=msid-semantic: WMS",
    "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
    "c=IN IP4 0.0.0.0",
  ];
  for (const cand of desc.candidates) lines.push(cand.toSdp());
  lines.push("a=end-of-candidates");
  lines.push(`a=ice-ufrag:${desc.ufrag}`);
  lines.push(`a=ice-pwd:${desc.pwd}`);
  lines.push("a=ice-options:trickle");
  lines.push(`a=fingerprint:sha-256 ${desc.fingerprint}`);
  lines.push(`a=setup:${isOffer ? "actpass" : desc.setup}`);
  lines.push("a=mid:0");
  lines.push(`a=sctp-port:${desc.sctpPort}`);
  lines.push("a=max-message-size:262144");
  return lines.join("\r\n") + "\r\n";
}

export function parse(text) {
  const desc = { ufrag: "", pwd: "", fingerprint: "", setup: "", candidates: [], sctpPort: 5000 };
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.startsWith("a=ice-ufrag:")) desc.ufrag = line.slice("a=ice-ufrag:".length);
    else if (line.startsWith("a=ice-pwd:")) desc.pwd = line.slice("a=ice-pwd:".length);
    else if (line.startsWith("a=fingerprint:")) {
      desc.fingerprint = line.slice("a=fingerprint:".length).replace(/^sha-256[ \t]/, "");
    } else if (line.startsWith("a=setup:")) desc.setup = line.slice("a=setup:".length);
    else if (line.startsWith("a=candidate:")) {
      const cand = Candidate.fromSdp(line.slice(2));
      if (cand) desc.candidates.push(cand);
    } else if (line.startsWith("a=sctp-port:")) {
      desc.sctpPort = Number(line.slice("a=sctp-port:".length));
    }
  }
  if (!desc.ufrag || !desc.pwd || !desc.fingerprint) {
    throw new Error("incomplete SDP: missing ice credentials or fingerprint");
  }
  return desc;
}
