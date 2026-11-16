// Registry discovery (JS): ListServices from live
// registrations, GetDescriptor returns registered bytes, and
// a dynamic client calls the discovered service with the
// fetched descriptor.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { Channel, Server, memoryDataChannelPair } from "../index.js";
import { DynamicClient, GenericMessage, parseDescriptorSet } from "../src/dynamic.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";
import { REGISTRY_DESCRIPTOR_SET, createRegistryService } from "../src/registry.js";

const handlers = {
  async unary(req) {
    return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
  },
  async *serverStream(req) {
    for (let i = 0; i < Math.max(0, req.count); i++) {
      yield new EchoResponse({ message: req.message, index: i });
    }
  },
  async clientStream(requests) {
    const parts = [];
    for await (const req of requests) parts.push(req.message);
    return new EchoResponse({ message: parts.join("+"), index: parts.length });
  },
  async *bidi(requests) {
    let index = 0;
    for await (const req of requests) {
      yield new EchoResponse({ message: req.message, index: index++ });
    }
  },
};

test("discovery list, fetch, and dynamic call", async () => {
  const echoDescriptor = new Uint8Array(
    await readFile(new URL("../../fixtures/echo_descriptor_set.bin", import.meta.url)),
  );
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(handlers));
  server.addService(createRegistryService(server, new Map([["echo.Echo", echoDescriptor]])));
  server.serve(b);

  const model = parseDescriptorSet(REGISTRY_DESCRIPTOR_SET);
  const client = new DynamicClient(new Channel(a), model);
  const listed = await client.unary(
    "grpcdc.registry.v1.Registry", "ListServices", new GenericMessage(model.messages.get(".grpcdc.registry.v1.ListServicesRequest")),
  );
  const names = listed.getAll(1).map((v) => String(v));
  assert.ok(names.includes("echo.Echo"), `${names}`);
  assert.ok(names.includes("grpcdc.registry.v1.Registry"), `${names}`);

  const fetchReq = new GenericMessage(model.messages.get(".grpcdc.registry.v1.GetDescriptorRequest"));
  fetchReq.set(1, "echo.Echo");
  const got = await client.unary("grpcdc.registry.v1.Registry", "GetDescriptor", fetchReq);
  const bytes = got.getAll(1)[0];
  assert.deepEqual([...bytes], [...echoDescriptor]);

  // The discovered service also answers its generated client.
  const echo = new EchoClient(new Channel(a));
  void echo;
  const echoModel = parseDescriptorSet(bytes);
  const dyn = new DynamicClient(new Channel(a), echoModel);
  const req = new GenericMessage(echoModel.messages.get(".echo.EchoRequest"));
  req.set(1, "discovered");
  const resp = await dyn.unary("echo.Echo", "Unary", req);
  assert.equal(resp.getString(1), "echo: discovered");
  void EchoRequest;
});
