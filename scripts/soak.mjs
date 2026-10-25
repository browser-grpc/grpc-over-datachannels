#!/usr/bin/env node
// Soak driver: sustained large-unary RPCs with per-iteration
// latency budgets, mirroring upstream's rpc_soak / channel_soak
// semantics (interop client defaults, scaled up).
//
// Phases:
//   A. our JS client (generated HTTP/2 transport) -> official
//      grpc-java TestServiceServer (the oracle).
//   B. official grpc-go interop client (rpc_soak + channel_soak)
//      -> the same Java oracle, as a control.
//   C. official grpc-go interop client (rpc_soak + channel_soak)
//      -> our JS TestService through the ingress proxy ->
//      WebRTC-Direct product path.
//
// Usage: node scripts/soak.mjs [iterations]
//   SOAK_ITERATIONS (default 1000), SOAK_LATENCY_MS per-RPC cap
//   (default 1000, upstream's default). Exits nonzero on the
//   first phase that misses its budget (0 failures allowed).
import { execFile, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import { promisify } from "node:util";

const run = promisify(execFile);
const ROOT = new URL("..", import.meta.url).pathname;
const ITERATIONS = Number(process.argv[2] ?? process.env.SOAK_ITERATIONS ?? 1000);
const LATENCY_MS = Number(process.env.SOAK_LATENCY_MS ?? 1000);
const GO_CLIENT = `${ROOT}oracle/go-interop/interop-client`;
const JAVA_DIR = `${ROOT}oracle/java`;

function freePort() {
  return new Promise((resolve) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function percentile(sorted, p) {
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
}

async function phaseA(javaPort) {
  const { http2Channel } = await import("../js/src/http2.js");
  const { TestServiceClient } = await import("../js/examples/interop/test_grpc_dc.js");
  const { Payload, SimpleRequest } = await import("../js/examples/interop/messages_pb.js");
  const channel = http2Channel(`127.0.0.1:${javaPort}`);
  const client = new TestServiceClient(channel);
  const latencies = [];
  let failures = 0;
  const started = performance.now();
  for (let i = 0; i < ITERATIONS; i++) {
    const t0 = performance.now();
    try {
      const resp = await client.unaryCall(new SimpleRequest({
        responseSize: 314159,
        payload: new Payload({ body: new Uint8Array(271828) }),
      }));
      if (resp.payload.body.length !== 314159) throw new Error("short payload");
    } catch {
      failures++;
    }
    latencies.push(performance.now() - t0);
  }
  channel.endpoint.dataChannel.close();
  latencies.sort((a, b) => a - b);
  const over = latencies.filter((x) => x > LATENCY_MS).length;
  const secs = ((performance.now() - started) / 1000).toFixed(1);
  console.log(
    `A js->java: ${ITERATIONS} iters, ${failures} failures, ${over} over ${LATENCY_MS}ms, ` +
    `p50 ${percentile(latencies, 50).toFixed(1)}ms p99 ${percentile(latencies, 99).toFixed(1)}ms ` +
    `max ${latencies[latencies.length - 1].toFixed(1)}ms, ${secs}s`);
  if (failures > 0 || over > 0) throw new Error(`phase A budget missed`);
}

async function soakGoClient(port, label) {
  for (const testCase of ["rpc_soak", "channel_soak"]) {
    await run(GO_CLIENT, [
      "-server_host", "127.0.0.1", "-server_port", String(port),
      "-test_case", testCase,
      "-soak_iterations", String(ITERATIONS),
      "-soak_max_failures", "0",
      "-soak_per_iteration_max_acceptable_latency_ms", String(LATENCY_MS),
      // Overall budget sized to the slowest path observed
      // (~55ms/iter through proxy -> WebRTC-Direct), with slack.
      "-soak_overall_timeout_seconds", String(Math.max(120, ITERATIONS / 5)),
    ], { timeout: 900000 });
    console.log(`${label} ${testCase}: ${ITERATIONS} iters ok`);
  }
}

async function main() {
  const cpFile = `${JAVA_DIR}/target/cp.txt`;
  if (!existsSync(`${JAVA_DIR}/target/classes`) || !existsSync(cpFile)) {
    console.error("java oracle not built (cd oracle/java && mvn package)");
    process.exit(2);
  }
  if (!existsSync(GO_CLIENT)) {
    console.error("go interop client not built (oracle/go-interop)");
    process.exit(2);
  }
  const cp = `${JAVA_DIR}/target/classes:${readFileSync(cpFile, "utf8").trim()}`;

  // Phase A/B target: the official Java TestServiceServer.
  const javaPort = await freePort();
  const javaServer = spawn("java", [
    "-cp", cp, "io.grpc.testing.integration.TestServiceServer",
    `--port=${javaPort}`, "--use_tls=false",
  ], { stdio: ["ignore", "pipe", "pipe"] });
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("java oracle did not start")), 60000);
      const onData = (d) => {
        if (String(d).includes("Server started")) { clearTimeout(timer); resolve(); }
      };
      javaServer.stdout.on("data", onData);
      javaServer.stderr.on("data", onData);
      javaServer.on("exit", (code) => reject(new Error(`java oracle exited ${code}`)));
    });
    await phaseA(javaPort);
    await soakGoClient(javaPort, "B go-client->java:");
  } finally {
    javaServer.kill();
  }

  // Phase C target: our JS TestService behind proxy -> agent.
  const { startAgent } = await import("../proxy/grpc-dc-agent.mjs");
  const { dialDc, startIngressProxy } = await import("../proxy/grpc-dc-proxy.mjs");
  const { createTestServiceService } = await import("../js/examples/interop/test_grpc_dc.js");
  const { testServiceHandlers } = await import("../js/test/interop_service.js");
  const agent = await startAgent({ handlers: testServiceHandlers, createService: createTestServiceService });
  const dc = await dialDc(agent.multiaddr);
  const http2Port = await freePort();
  const proxy = await startIngressProxy({ dcStackEndpoint: dc.endpoint, dc, http2Port });
  try {
    await soakGoClient(http2Port, "C go-client->proxy->js:");
  } finally {
    await proxy.close();
    await dc.close();
    await agent.close();
  }
  console.log(`soak PASS (${ITERATIONS} iterations per phase)`);
}

await main();
