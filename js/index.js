// grpc-dc: gRPC over WebRTC DataChannels (JavaScript runtime).
// Wire tables in wire_gen.js and the protoc plugin that generates service
// stubs are produced by the grpc-dc code generator.

export {
  FrameType,
  StatusCode,
  StatusName,
  StatusError,
  encodeFrame,
  decodeFrame,
  encodeTimeout,
  parseTimeout,
  setTracer,
  setTraceFilter,
  toHex,
  fromHex,
} from "./src/codec.js";
export { Endpoint, StreamInput } from "./src/endpoint.js";
export { Channel } from "./src/channel.js";
export { Server } from "./src/server.js";
export { memoryDataChannelPair } from "./src/loopback.js";
export { createGrpcDcBridge, createGrpcDcServerBridge } from "./src/wasm_bridge.js";
// Note: the Node WebRTC-Direct adapter (src/webrtc_direct.js)
// is deliberately NOT re-exported here -- it imports Node-only
// modules (node:dgram via webrtc/js/direct.js) and this index
// is also loaded in browsers. Import it directly:
//   import { directClientEndpoint } from "grpc-dc/webrtc_direct";
// The generated HTTP/2 client transport (src/http2.js, calls
// official gRPC servers directly) is Node-only for the same
// reason (node:http2). Import it directly:
//   import { http2Channel } from "grpc-dc/http2";

import { Channel } from "./src/channel.js";
import { Endpoint } from "./src/endpoint.js";
import { Server } from "./src/server.js";

/**
 * A bidirectional peer: a Channel and a Server sharing one endpoint, so
 * both sides can call each other over the same data channel. The peer
 * that created the channel allocates odd stream ids; the answering peer
 * must pass { parity: "even" }.
 */
export function createPeer(dc, { parity = "odd" } = {}) {
  const endpoint = new Endpoint(dc, { parity });
  const server = new Server();
  server.serve(endpoint);
  return { endpoint, server, channel: new Channel(endpoint) };
}
export {
  DynamicClient,
  GenericMessage,
  createDynamicService,
  parseDescriptorSet,
} from "./src/dynamic.js";
