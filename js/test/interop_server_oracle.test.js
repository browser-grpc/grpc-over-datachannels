// Interop oracle, Direction B: the OFFICIAL interop clients
// (grpc-java TestServiceClient, grpc-go interop-client) run
// the canonical cases against our generated JS TestService
// server (js/test/interop_service.js), reached over HTTP/2
// through the ingress proxy -> WebRTC-Direct -> agent path
// (the product proxy shape, in-process). Skips when an oracle
// binary is not built (Dockerfile.ci builds both).
//
// Excluded (oracle/interop/README.md): auth, compression,
// orca, soak — and custom_metadata, whose trailing-bin echo
// the grpc-dc frame layer cannot carry. cacheable_unary runs
// only under the Java client (the Go client does not
// implement that case upstream).

import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import { promisify } from "node:util";
import test from "node:test";

import { startAgent } from "../../proxy/grpc-dc-agent.mjs";
import { dialDc, startIngressProxy } from "../../proxy/grpc-dc-proxy.mjs";
import { createTestServiceService } from "../examples/interop/test_grpc_dc.js";
import { testServiceHandlers } from "./interop_service.js";

const run = promisify(execFile);
const ROOT = new URL("../..", import.meta.url).pathname;
const JAVA_DIR = `${ROOT}oracle/java`;
const GO_CLIENT = `${ROOT}oracle/go-interop/interop-client`;

const CASES = [
  "empty_unary",
  "large_unary",
  "client_streaming",
  "server_streaming",
  "ping_pong",
  "empty_stream",
  "status_code_and_message",
  "special_status_message",
  "unimplemented_method",
  "unimplemented_service",
  "cancel_after_begin",
  "cancel_after_first_response",
  "timeout_on_sleeping_server",
];

async function freePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function startServerSide(t) {
  const agent = await startAgent({
    handlers: testServiceHandlers,
    createService: createTestServiceService,
  });
  t.after(() => agent.close());
  const dc = await dialDc(agent.multiaddr);
  const http2Port = await freePort();
  const proxy = await startIngressProxy({ dcStackEndpoint: dc.endpoint, dc, http2Port });
  t.after(() => proxy.close());
  return proxy.http2Port;
}

function javaClasspath(t) {
  const cpFile = `${JAVA_DIR}/target/cp.txt`;
  if (!existsSync(`${JAVA_DIR}/target/classes`) || !existsSync(cpFile)) {
    t.skip("java oracle not built (cd oracle/java && mvn package)");
    return null;
  }
  return `${JAVA_DIR}/target/classes:${readFileSync(cpFile, "utf8").trim()}`;
}

test("interop B: grpc-java client -> ingress proxy -> JS TestService server", { timeout: 280000 }, async (t) => {
  const cp = javaClasspath(t);
  if (!cp) return;
  const port = await startServerSide(t);
  for (const testCase of [...CASES, "cacheable_unary"]) {
    await t.test(testCase, async () => {
      const { stdout } = await run(
        "java",
        [
          "-cp", cp, "io.grpc.testing.integration.TestServiceClient",
          "--server_host=127.0.0.1", `--server_port=${port}`,
          `--test_case=${testCase}`, "--use_tls=false",
        ],
        { timeout: 120000 },
      );
      if (!stdout.includes("Test completed.")) {
        throw new Error(`unexpected client output: ${stdout}`);
      }
    });
  }
});

test("interop B: grpc-go client -> ingress proxy -> JS TestService server", { timeout: 280000 }, async (t) => {
  if (!existsSync(GO_CLIENT)) {
    t.skip("go interop client not built (cd oracle/go-interop && go build -o interop-client google.golang.org/grpc/interop/client)");
    return;
  }
  const port = await startServerSide(t);
  for (const testCase of CASES) {
    await t.test(testCase, async () => {
      await run(
        GO_CLIENT,
        ["-server_host", "127.0.0.1", "-server_port", String(port), "-test_case", testCase],
        { timeout: 120000 },
      );
    });
  }
});
