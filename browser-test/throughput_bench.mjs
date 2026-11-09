// SCTP throughput benchmark: our hand-rolled JS WebRTC stack
// against itself and against the browser's native stack
// (Chromium via Playwright), same loopback path, same payload
// schedule. Baseline numbers, not a correctness gate — run via
// `make bench-throughput`. Phases per pairing:
//   blast    - BLAST_MSGS messages of BLAST_SIZE bytes sent
//              without waiting; peer echoes each; sender times
//              until the last echo lands. MiB/s + msgs/s.
//   pingpong - PINGPONGS sequential round trips of 1024 bytes;
//              mean RTT.

import { launchBrowser, startStaticServer } from "./harness.mjs";
import { Peer } from "../webrtc/js/peer.js";

const BLAST_MSGS = 256;
const BLAST_SIZE = 16384;
// In-flight cap for the blast: unpaced bursts overflow the
// loopback UDP receive buffer and delivery degenerates to
// RTO-rate retransmits (measured), which says nothing about
// stack throughput. Both pairings run the same schedule; if a
// pairing wedges anyway the wait below fails loudly instead
// of hanging the bench.
const BLAST_WINDOW = 8;
const PINGPONGS = 200;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 120000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = fn();
    if (value) return value;
    await sleep(10);
  }
  throw new Error("bench wait timed out");
}

async function benchChannel(dc, label) {
  let echoes = 0;
  let lastEchoAt = 0;
  dc.onmessage = () => {
    echoes += 1;
    lastEchoAt = Date.now();
  };
  const payload = new Uint8Array(BLAST_SIZE).fill(120);
  const blastStart = Date.now();
  let sent = 0;
  while (sent < BLAST_MSGS) {
    while (sent < BLAST_MSGS && sent - echoes < BLAST_WINDOW) {
      dc.send(payload);
      sent += 1;
    }
    if (echoes < BLAST_MSGS) await sleep(1);
  }
  await waitFor(() => echoes >= BLAST_MSGS);
  const blastMs = lastEchoAt - blastStart;
  const bytes = BLAST_MSGS * BLAST_SIZE;
  console.log(
    `${label} blast: ${(bytes / 1048576 / (blastMs / 1000)).toFixed(1)} MiB/s ` +
      `(${(BLAST_MSGS / (blastMs / 1000)).toFixed(0)} msgs/s, ${bytes} bytes in ${blastMs}ms)`,
  );

  echoes = 0;
  const small = new Uint8Array(1024).fill(121);
  const ppStart = Date.now();
  for (let i = 0; i < PINGPONGS; i++) {
    const before = echoes;
    dc.send(small);
    await waitFor(() => echoes > before, 30000);
  }
  const ppMs = Date.now() - ppStart;
  console.log(`${label} pingpong: ${(ppMs / PINGPONGS).toFixed(2)} ms mean RTT (${PINGPONGS} trips)`);
}

async function benchJsPair() {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"] });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"] });
  try {
    const offer = offerer.createOffer();
    offerer.handleAnswer(answerer.handleOffer(offer));
    const [oEp, aEp] = await Promise.all([offerer.connect(), answerer.connect()]);
    const channel = oEp.openChannel({ label: "bench" });
    aEp.onchannel = (ch) => {
      ch.onmessage = (e) => ch.send(e.data);
    };
    await benchChannel(channel, "js <-> js    ");
  } finally {
    await offerer.close();
    await answerer.close();
  }
}

async function benchBrowserPair() {
  const { server, pageUrl } = await startStaticServer("browser-test", { isolated: true });
  const browser = await launchBrowser("chromium", {
    extraArgs: ["--enable-features=SharedArrayBuffer"],
  });
  let peer;
  try {
    const pg = await browser.newPage();
    await pg.goto(`${pageUrl}/bench_page.html`);
    await pg.waitForFunction(() => window.__offer, null, { timeout: 30000 });
    peer = await Peer.create();
    const answer = peer.handleOffer(await pg.evaluate(() => window.__offer));
    await pg.evaluate((sdp) => window.__acceptAnswer(sdp), answer);
    const endpoint = await peer.connect();
    const dc = await new Promise((resolve) => { endpoint.onchannel = resolve; });
    if (dc.readyState !== "open") {
      await new Promise((r) => dc.addEventListener("open", r, { once: true }));
    }
    await benchChannel(dc, "js <-> chromium");
  } finally {
    await browser.close();
    if (peer) await peer.close();
    server.close();
  }
}

await benchJsPair();
await benchBrowserPair();
console.log("throughput bench done");
