// Dynamic (descriptor-driven) runtime: schemas consumed as data at
// runtime, no generated stubs. Loopback plus the official grpc-java
// oracle in both directions (the oracle is the runtime test bed).

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import test from "node:test";

import {
  Channel,
  DynamicClient,
  Endpoint,
  GenericMessage,
  Server,
  createDynamicService,
  memoryDataChannelPair,
  parseDescriptorSet,
} from "../index.js";
import { StatusError } from "../src/codec.js";
import { dynamicEchoHandlers } from "../examples/dynamic_echo.js";
import { ORACLE_SCENARIOS } from "./oracle_driver.generated.js";
import { StdioChannel, serveDcToHttp2, serveHttp2ToDc } from "../../oracle/bridge.mjs";

const ROOT = new URL("../..", import.meta.url).pathname;
const JAVA_DIR = `${ROOT}oracle/java`;
const SCENARIOS_FILE = `${ROOT}fixtures/oracle_scenarios.txt`;
const SERVICE = "echo.Echo";

function loadModel(t) {
  const path = `${ROOT}fixtures/echo_descriptor_set.bin`;
  if (!existsSync(path)) {
    t.skip("descriptor fixture missing (make generate)");
    return null;
  }
  return parseDescriptorSet(new Uint8Array(readFileSync(path)));
}

function req(model, message, count = 0) {
  return new GenericMessage(model.messages.get(".echo.EchoRequest"))
    .set(1, message)
    .set(2, count);
}

const unmsg = (token) => (token === "-" ? "" : token);

async function runDynamicScenarios(client, model) {
  for (const c of ORACLE_SCENARIOS) {
    const line = `${c.kind} ${c.messages.join(" ")}`;
    const messages = c.messages.map(unmsg);
    if (c.kind === "UNARY") {
      let resp;
      try {
        resp = await client.unary(SERVICE, "Unary", req(model, messages[0]));
      } catch (e) {
        if (c.expectStatus !== undefined) {
          assert.ok(e instanceof StatusError && e.code === c.expectStatus, `${line}: ${e}`);
          continue;
        }
        throw e;
      }
      assert.equal(resp.getString(1), `echo: ${messages[0]}`, line);
      assert.equal(resp.getInt(2), 0, line);
    } else if (c.kind === "SERVER_STREAM") {
      const responses = [];
      for await (const resp of await client.serverStream(
        SERVICE, "ServerStream", req(model, messages[0], c.count))) {
        responses.push(resp);
      }
      assert.equal(responses.length, c.count, line);
      responses.forEach((resp, i) => {
        assert.equal(resp.getString(1), messages[0], line);
        assert.equal(resp.getInt(2), i, line);
      });
    } else if (c.kind === "CLIENT_STREAM") {
      const resp = await client.clientStream(
        SERVICE, "ClientStream", messages.map((m) => req(model, m)));
      assert.equal(resp.getString(1), messages.join("+"), line);
      assert.equal(resp.getInt(2), messages.length, line);
    } else if (c.kind === "BIDI") {
      const responses = [];
      for await (const resp of await client.bidi(
        SERVICE, "Bidi", messages.map((m) => req(model, m)))) {
        responses.push(resp);
      }
      assert.equal(responses.length, messages.length, line);
      responses.forEach((resp, i) => {
        assert.equal(resp.getString(1), messages[i], line);
        assert.equal(resp.getInt(2), i, line);
      });
    }
  }
}

function javaClasspath(t) {
  const cpFile = `${JAVA_DIR}/target/cp.txt`;
  if (!existsSync(`${JAVA_DIR}/target/classes`) || !existsSync(cpFile)) {
    t.skip("java oracle not built (cd oracle/java && mvn package)");
    return null;
  }
  return `${JAVA_DIR}/target/classes:${readFileSync(cpFile, "utf8").trim()}`;
}

async function freePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function runJava(args, t) {
  return new Promise((resolve, reject) => {
    const proc = spawn("java", args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d));
    proc.stderr.on("data", (d) => (stderr += d));
    proc.on("error", reject);
    proc.on("exit", (code) => resolve({ code, stdout, stderr }));
    t.after(() => proc.kill());
  });
}

async function startJavaServer(t, port) {
  const cp = javaClasspath(t);
  if (!cp) return null;
  const proc = spawn("java", ["-cp", cp, "dc.oracle.OracleServer", String(port)], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => proc.kill());
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("java server did not start")), 30000);
    proc.stderr.on("data", (d) => {
      if (String(d).includes("READY")) {
        clearTimeout(timer);
        resolve();
      }
    });
    proc.on("exit", (code) => reject(new Error(`java server exited ${code}`)));
  });
  return proc;
}

test("dynamic: unknown fields retained", { timeout: 60000 }, async (t) => {
  const model = loadModel(t);
  if (!model) return;
  const { encodeGeneric, decodeGeneric } = await import("../src/dynamic.js");
  const requestType = model.messages.get(".echo.EchoRequest");
  const payload = Buffer.concat([
    Buffer.from("0a0268691002", "hex"),
    Buffer.from([0x98, 0x06, 0x2a]),
    Buffer.from([0xa2, 0x06, 0x01]),
    Buffer.from("x"),
  ]);
  const decoded = decodeGeneric(requestType, new Uint8Array(payload), model);
  assert.equal(decoded.unknown.length, 2);
  assert.deepEqual(Buffer.from(encodeGeneric(requestType, decoded, model)), payload);
});

test("dynamic: loopback all shapes", { timeout: 60000 }, async (t) => {
  const model = loadModel(t);
  if (!model) return;
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createDynamicService(model, SERVICE, dynamicEchoHandlers));
  server.serve(b);
  const client = new DynamicClient(new Channel(a), model);
  await runDynamicScenarios(client, model);
});

test("dynamic oracle: dynamic JS client -> official Java server", { timeout: 180000 }, async (t) => {
  const model = loadModel(t);
  if (!model) return;
  const javaPort = await freePort();
  if (!(await startJavaServer(t, javaPort))) return;
  const [a, b] = memoryDataChannelPair();
  const bridgeEndpoint = new Endpoint(a, { parity: "even" });
  const session = serveDcToHttp2({ grpcAuthority: `127.0.0.1:${javaPort}`, endpoint: bridgeEndpoint });
  t.after(() => session.close());
  const client = new DynamicClient(new Channel(b), model);
  await runDynamicScenarios(client, model);
});

test("dynamic oracle: official Java client -> dynamic JS server", { timeout: 180000 }, async (t) => {
  if (!javaClasspath(t)) return;
  const proc = spawn("node", [`${ROOT}js/examples/dynamic_echo_server_stdio.mjs`], {
    stdio: ["pipe", "pipe", "inherit"],
  });
  t.after(() => proc.kill());
  const endpoint = new Endpoint(new StdioChannel(proc.stdout, proc.stdin));
  const port = await freePort();
  const http2Server = await serveHttp2ToDc({ port, endpoint });
  t.after(() => http2Server.close());
  const cp = javaClasspath(t);
  const { code, stdout, stderr } = await runJava(
    ["-cp", cp, "dc.oracle.OracleClient", String(port), SCENARIOS_FILE], t);
  assert.equal(code, 0, `oracle client failed:\n${stdout}\n${stderr}`);
  assert.match(stdout, /ORACLE CLIENT: ALL OK/);
});
