// Full-peer echo harness with SDP exchanged through files:
//   node peer_echo.mjs offerer  <offer-file> <answer-file>
//   node peer_echo.mjs answerer <offer-file> <answer-file>
// Mirrors webrtc/rust/examples/peer_echo.rs (used by Go cross tests).

import fs from "node:fs";
import { createInterface } from "node:readline";
import { Peer } from "../peer.js";

const [mode, offerPath, answerPath] = process.argv.slice(2);

async function waitForFile(path) {
  for (;;) {
    try {
      const content = fs.readFileSync(path, "utf8");
      if (content.trim()) return content;
    } catch {
      /* not yet */
    }
    await new Promise((r) => setTimeout(r, 25));
  }
}

if (mode === "answerer") {
  const offer = await waitForFile(offerPath);
  const peer = await Peer.create({ localIps: ["127.0.0.1"] });
  const answer = peer.handleOffer(offer);
  fs.writeFileSync(answerPath, answer);
  console.error("ANSWER_WRITTEN");
  const endpoint = await peer.connect();
  console.error("CONNECTED");
  endpoint.onchannel = (channel) => {
    console.error(`CHANNEL_OPEN stream=${channel.id}`);
    channel.onclose = () => console.error(`CHANNEL_CLOSED stream=${channel.id}`);
    channel.onmessage = (event) => {
      const data = Buffer.isBuffer(event.data) ? event.data : Buffer.from(event.data);
      channel.send(Buffer.concat([Buffer.from("re:"), data]));
    };
  };
  setInterval(() => {}, 1000);
} else if (mode === "offerer") {
  const peer = await Peer.create({ localIps: ["127.0.0.1"] });
  const offer = peer.createOffer();
  fs.writeFileSync(offerPath, offer);
  const answer = await waitForFile(answerPath);
  peer.handleAnswer(answer);
  const endpoint = await peer.connect();
  console.error("CONNECTED");
  const channel = endpoint.openChannel({ label: "echo" });
  const replies = [];
  channel.onmessage = (event) => {
    replies.push(Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data));
  };
  const rl = createInterface({ input: process.stdin });
  for await (const line of rl) {
    if (!line) continue;
    if (line === "__close__") {
      // Cross-stack close check: reset the stream and report
      // once both directions complete locally.
      const closed = new Promise((resolve) => { channel.onclose = resolve; });
      channel.close();
      await closed;
      console.error("CHANNEL_CLOSED_LOCAL");
      console.log("closed");
      continue;
    }
    const before = replies.length;
    channel.send(Buffer.from(line));
    const deadline = Date.now() + 15000;
    while (replies.length === before && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 10));
    }
    if (replies.length === before) {
      console.error("no reply");
      process.exit(1);
    }
    console.log(replies[replies.length - 1]);
  }
  process.exit(0);
} else {
  console.error("usage: peer_echo.mjs <offerer|answerer> <offer-file> <answer-file>");
  process.exit(2);
}
