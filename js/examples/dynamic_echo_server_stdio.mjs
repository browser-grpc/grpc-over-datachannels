// Interop harness: the dynamic (descriptor-driven) JS echo server
// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
// no generated stubs involved. Used by the oracle tests.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { Endpoint, Server, createDynamicService, parseDescriptorSet } from "../index.js";
import { dynamicEchoHandlers } from "./dynamic_echo.js";
import { StdioChannel } from "../../oracle/bridge.mjs";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const descriptors = readFileSync(`${ROOT}fixtures/echo_descriptor_set.bin`);
const model = parseDescriptorSet(new Uint8Array(descriptors));

const server = new Server();
server.addService(createDynamicService(model, "echo.Echo", dynamicEchoHandlers));
const endpoint = new Endpoint(new StdioChannel(process.stdin, process.stdout), { parity: "even" });
server.serve(endpoint);

setInterval(() => {}, 1000);
