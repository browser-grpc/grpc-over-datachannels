// TestService implementation (grpc.testing) over our generated
// Server, mirroring the reference TestServiceImpl semantics the
// interop cases grade: payload sizes are answered with zero
// bodies of the requested size, response_parameters drive
// streamed responses (interval_us honored), response_status
// fails the call, streaming input is aggregated by byte count.
// Used by the Direction-B interop tests (official clients vs
// our servers).

import { StatusCode, StatusError } from "../index.js";
import { Empty } from "../examples/interop/empty_pb.js";
import {
  Payload,
  SimpleResponse,
  StreamingInputCallResponse,
  StreamingOutputCallResponse,
} from "../examples/interop/messages_pb.js";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const zeros = (n) => new Uint8Array(n);

// Reference echo (custom_metadata case): the echo-initial
// request value returns as initial metadata, the
// echo-trailing-bin value (base64 on our wire) as trailers.
function echoMetadata(ctx) {
  if (!ctx) return;
  const initial = ctx.metadata["x-grpc-test-echo-initial"];
  if (initial !== undefined) {
    ctx.setHeaders({ "x-grpc-test-echo-initial": initial });
  }
  const trailing = ctx.metadata["x-grpc-test-echo-trailing-bin"];
  if (trailing !== undefined) {
    ctx.setTrailers({ "x-grpc-test-echo-trailing-bin": trailing });
  }
}

function maybeFail(req) {
  const status = req.responseStatus;
  if (status && (status.code !== 0 || status.message !== "")) {
    throw new StatusError(status.code, status.message);
  }
}

function unaryResponse(req) {
  maybeFail(req);
  return new SimpleResponse({
    payload: new Payload({ type: req.responseType, body: zeros(req.responseSize) }),
  });
}

async function* streamingResponses(req) {
  maybeFail(req);
  let first = true;
  for (const param of req.responseParameters) {
    if (!first && param.intervalUs > 0) await sleep(param.intervalUs / 1000);
    first = false;
    yield new StreamingOutputCallResponse({
      payload: new Payload({ type: req.responseType, body: zeros(param.size) }),
    });
  }
}

export const testServiceHandlers = {
  async emptyCall(req, ctx) {
    echoMetadata(ctx);
    return new Empty();
  },

  async unaryCall(req, ctx) {
    echoMetadata(ctx);
    return unaryResponse(req);
  },

  async cacheableUnaryCall(req, ctx) {
    echoMetadata(ctx);
    // Reference semantics: echo the request payload (the case
    // asserts identical requests give identical responses and
    // differing requests differ).
    maybeFail(req);
    return new SimpleResponse({ payload: req.payload ?? new Payload() });
  },

  async *streamingOutputCall(req, ctx) {
    echoMetadata(ctx);
    yield* streamingResponses(req);
  },

  async streamingInputCall(requests, ctx) {
    echoMetadata(ctx);
    let total = 0;
    for await (const req of requests) total += req.payload?.body.length ?? 0;
    return new StreamingInputCallResponse({ aggregatedPayloadSize: total });
  },

  async *fullDuplexCall(requests, ctx) {
    echoMetadata(ctx);
    for await (const req of requests) {
      yield* streamingResponses(req);
    }
  },

  async *halfDuplexCall(requests, ctx) {
    echoMetadata(ctx);
    const collected = [];
    for await (const req of requests) collected.push(req);
    for (const req of collected) {
      yield* streamingResponses(req);
    }
  },

  async unimplementedCall() {
    throw new StatusError(StatusCode.UNIMPLEMENTED, "not implemented");
  },
};
