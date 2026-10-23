// Dynamic Echo implementation: the reference Echo semantics built
// purely on the descriptor-driven runtime (no generated stubs).
// Field numbers come from proto/echo.proto: EchoRequest{message=1,
// count=2}, EchoResponse{message=1, index=2}.

import { GenericMessage, StatusError } from "../index.js";
import { StatusCode } from "../wire_gen.js";

function response(method, message, index) {
  return new GenericMessage(method.output).set(1, message).set(2, index);
}

export const dynamicEchoHandlers = {
  unary(ctx, method, req) {
    const message = req.getString(1);
    if (message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
    const marker = ctx.metadata?.["x-echo"];
    const suffix = marker ? ` [${marker}]` : "";
    return response(method, `echo: ${message}${suffix}`, 0);
  },

  serverStream(ctx, method, req) {
    const out = [];
    for (let i = 0; i < Math.max(0, req.getInt(2)); i++) {
      out.push(response(method, req.getString(1), i));
    }
    return out;
  },

  async clientStream(ctx, method, requests) {
    const parts = [];
    for await (const req of requests) parts.push(req.getString(1));
    return response(method, parts.join("+"), parts.length);
  },

  async *bidi(ctx, method, requests) {
    let index = 0;
    for await (const req of requests) {
      yield response(method, req.getString(1), index++);
    }
  },
};
