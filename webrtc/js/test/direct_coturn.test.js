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

// Probe-close free port: coturn takes a numeric port
// argument, so bind(0), read the allocated port, close, and
// let coturn rebind it. The race is unavoidable there, so
// startCoturn verifies the child survived startup and
// retries on a fresh port when it did not.
async function freePort() {
  const socket = dgram.createSocket("udp4");
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  const { port } = socket.address();
  socket.close();
  return port;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Spawn coturn with args built from a probe-close port;
// retry up to 3 times if the child dies at startup (the
// probed port was taken before coturn bound it).
async function startCoturn(buildArgs) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const port = await freePort();
    const turn = spawn("turnserver", ["-n", ...buildArgs(port)], { stdio: "ignore" });
    await sleep(800);
    if (turn.exitCode === null) return { turn, port };
  }
  throw new Error("turnserver did not survive startup after 3 attempts");
}

test("direct over real TURN (coturn) echo", { skip: !hasCoturn, timeout: 60000 }, async () => {
  const { turn, port } = await startCoturn((p) => [
    "--listening-ip=127.0.0.1",
    `--listening-port=${p}`,
    "--relay-ip=127.0.0.1",
    "--realm=dc.test",
    `--user=${USER}:${PASS}`,
    "--lt-cred-mech",
    "--allow-loopback-peers",
    "--no-cli",
  ]);
  try {
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

async function echoViaCoturn({ turnArgs, turnAddress, listenerOpts, turnOpts }) {
  const { turn, port } = await startCoturn(turnArgs);
  try {
    const listener = await DirectListener.bind(listenerOpts);
    const accepted = listener.accept();
    let serverGot = null;
    accepted.then((endpoint) => {
      endpoint.onchannel = (channel) => {
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
          turn: { address: turnAddress(port), username: USER, password: PASS, ...turnOpts },
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
    channel.send(Buffer.from("via-coturn-leg"));
    const deadline = Date.now() + 15000;
    while (replies.length === 0 && Date.now() < deadline) await sleep(10);
    assert.equal(replies[0], "direct-reply");
    assert.equal(serverGot, "via-coturn-leg");
    await client.closeDirect();
    await (await accepted).close();
    listener.close();
  } finally {
    turn.kill();
  }
}

test("direct over TURNS (coturn TLS) echo", { skip: !hasCoturn, timeout: 60000 }, async () => {
  const { execFileSync } = await import("node:child_process");
  const fs = await import("node:fs");
  const os = await import("node:os");
  const path = await import("node:path");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dc-turns-"));
  const cert = path.join(dir, "cert.pem");
  const key = path.join(dir, "key.pem");
  try {
    execFileSync("openssl", [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost",
    ], { stdio: "ignore" });
  } catch {
    return; // openssl unavailable: skip
  }
  await echoViaCoturn({
    turnArgs: (tlsPort) => [
      "--listening-ip=127.0.0.1",
      "--relay-ip=127.0.0.1",
      `--tls-listening-port=${tlsPort}`,
      `--cert=${cert}`,
      `--pkey=${key}`,
      "--realm=dc.test",
      `--user=${USER}:${PASS}`,
      "--lt-cred-mech",
      "--allow-loopback-peers",
      "--no-cli",
    ],
    turnAddress: (port) => `127.0.0.1:${port}`,
    listenerOpts: {},
    turnOpts: { transport: "tls", insecureSkipVerify: true },
  });
});

test("direct over IPv6 TURN (coturn) echo", { skip: !hasCoturn, timeout: 60000 }, async () => {
  await echoViaCoturn({
    turnArgs: (port) => [
      "--listening-ip=::1",
      `--listening-port=${port}`,
      "--relay-ip=::1",
      "--realm=dc.test",
      `--user=${USER}:${PASS}`,
      "--lt-cred-mech",
      "--allow-loopback-peers",
      "--no-cli",
    ],
    turnAddress: (port) => `[::1]:${port}`,
    listenerOpts: { address: "::1" },
    turnOpts: { requestIpv6Relay: true },
  });
});
