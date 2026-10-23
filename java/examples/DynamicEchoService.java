package echo;

import grpcdc.Dynamic;
import grpcdc.Endpoint;
import grpcdc.StatusException;
import grpcdc.Wire;
import java.io.EOFException;

/**
 * Dynamic Echo implementation: the reference Echo semantics built
 * purely on the descriptor-driven runtime (no generated stubs).
 * Field numbers come from proto/echo.proto: EchoRequest{message=1,
 * count=2}, EchoResponse{message=1, index=2}.
 */
public final class DynamicEchoService implements Dynamic.DynamicHandler {
    private static Dynamic.GenericMessage response(Dynamic.MethodModel method, String message, long index) {
        return new Dynamic.GenericMessage(method.output).set(1, message).set(2, index);
    }

    @Override
    public Dynamic.GenericMessage unary(Endpoint.CallContext ctx, Dynamic.MethodModel method,
            Dynamic.GenericMessage req) {
        String message = req.getString(1);
        if ("fail".equals(message)) {
            throw new StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail");
        }
        String suffix = "";
        String marker = ctx.metadata.get("x-echo");
        if (marker != null && !marker.isEmpty()) {
            suffix = " [" + marker + "]";
        }
        return response(method, "echo: " + message + suffix, 0);
    }

    @Override
    public void serverStream(Endpoint.CallContext ctx, Dynamic.MethodModel method,
            Dynamic.GenericMessage req, Dynamic.SendFn send) throws Exception {
        long count = req.getInt(2);
        for (long i = 0; i < count; i++) {
            send.send(response(method, req.getString(1), i));
        }
    }

    @Override
    public Dynamic.GenericMessage clientStream(Endpoint.CallContext ctx, Dynamic.MethodModel method,
            Dynamic.RecvFn recv) throws Exception {
        StringBuilder joined = new StringBuilder();
        long count = 0;
        while (true) {
            Dynamic.GenericMessage req;
            try {
                req = recv.get();
            } catch (EOFException eof) {
                break;
            }
            if (count > 0) {
                joined.append('+');
            }
            joined.append(req.getString(1));
            count++;
        }
        return response(method, joined.toString(), count);
    }

    @Override
    public void bidi(Endpoint.CallContext ctx, Dynamic.MethodModel method,
            Dynamic.RecvFn recv, Dynamic.SendFn send) throws Exception {
        long index = 0;
        while (true) {
            Dynamic.GenericMessage req;
            try {
                req = recv.get();
            } catch (EOFException eof) {
                return;
            }
            send.send(response(method, req.getString(1), index++));
        }
    }
}
