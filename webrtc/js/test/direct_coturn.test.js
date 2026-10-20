// WebRTC-Direct over a real TURN server (coturn): the
// symmetric-NAT shape against a production TURN implementation,
// not the repo fake. Skipped when `turnserver` is not on PATH;
// Dockerfile.ci installs coturn, so CI always runs this leg.

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import dgram from "node:dgram";
import test from "node:test";
import {
  DirectListener,
  directDialTurnMultiaddr,
} from "../direct.js";
import { PASS, USER } from "./fake_turn.js";

const hasCoturn = spawnSync("turnserver", ["-h"], { encoding: "utf8" }).error == null;

async function freePort() {
  const socket = dgram.createSocket("udp4");
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  const { port } = socket.address();
  socket.close();
  return port;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("direct over real TURN (coturn) echo", { skip: !hasCoturn, timeout: 60000 }, async () => {
  const port = await freePort();
  const turn = spawn(
    "turnserver",
    [
      "-n",
      "--listening-ip=127.0.0.1",
      `--listening-port=${port}`,
      "--relay-ip=127.0.0.1",
      "--realm=dc.test",
      `--user=${USER}:${PASS}`,
      "--lt-cred-mech",
      "--allow-loopback-peers",
      "--no-cli",
    ],
    { stdio: "ignore" },
  );
  try {
    await sleep(800);
    const listener = await DirectListener.bind({});
    const accepted = listener.accept();
    let serverChannel = null;
    let serverGot = null;
    accepted.then((endpoint) => {
      endpoint.onchannel = (channel) => {
        serverChannel = channel;
        channel.onmessage = (event) => {
          serverGot = Buffer.from(event.data).toString();
          channel.send(Buffer.from("direct-reply"));
        };
      };
    });

    let client = null;
    let lastErr = null;
    for (let i = 0; i < 10 && !client; i++) {
      try {
        client = await directDialTurnMultiaddr(listener.multiaddr(), {
          turn: { address: `127.0.0.1:${port}`, username: USER, password: PASS },
        });
      } catch (err) {
        lastErr = err;
        await sleep(500);
      }
    }
    assert.ok(client, `direct dial over coturn failed: ${lastErr}`);

    const channel = client.openChannel({ label: "echo" });
    const replies = [];
    channel.onmessage = (e) => replies.push(Buffer.from(e.data).toString());
    channel.send(Buffer.from("via-coturn"));
    const deadline = Date.now() + 15000;
    while (replies.length === 0 && Date.now() < deadline) await sleep(10);
    assert.equal(replies[0], "direct-reply");
    assert.equal(serverGot, "via-coturn");
    assert.ok(serverChannel);
    await client.closeDirect();
    await (await accepted).close();
    listener.close();
  } finally {
    turn.kill();
  }
});
