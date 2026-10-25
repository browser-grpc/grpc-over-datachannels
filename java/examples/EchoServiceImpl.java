package echo;

import grpcdc.Endpoint;
import grpcdc.StatusException;
import grpcdc.Wire;
import java.io.EOFException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Reference Echo implementation (mirrors the Rust/JS/Go/Python demos):
 * "fail" is rejected, everything else echoes.
 */
public final class EchoServiceImpl implements EchoGrpcDc.EchoServer {
    @Override
    public EchoResponse Unary(Endpoint.CallContext ctx, EchoRequest req) {
        if ("fail".equals(req.message)) {
            throw new StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail");
        }
        if (req.delayMs > 0) {
            try {
                Thread.sleep(req.delayMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        String suffix = "";
        String marker = ctx.metadata.get("x-echo");
        if (marker != null && !marker.isEmpty()) {
            suffix = " [" + marker + "]";
        }
        String trailerMarker = ctx.metadata.get("x-echo-trailer");
        if (trailerMarker != null && !trailerMarker.isEmpty()) {
            ctx.setTrailers(Map.of("x-echo-trailer", trailerMarker));
        }
        return new EchoResponse("echo: " + req.message + suffix, 0);
    }

    @Override
    public void ServerStream(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream) throws Exception {
        if ("fail".equals(req.message)) {
            throw new StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail");
        }
        for (int i = 0; i < Math.max(0, req.count); i++) {
            stream.send(new EchoResponse(req.message, i));
        }
    }

    @Override
    public void ClientStream(EchoGrpcDc.EchoClientStreamServer stream) throws Exception {
        List<String> parts = new ArrayList<>();
        while (true) {
            EchoRequest req;
            try {
                req = stream.recv();
            } catch (EOFException eof) {
                break;
            }
            parts.add(req.message);
        }
        stream.sendAndClose(new EchoResponse(String.join("+", parts), parts.size()));
    }

    @Override
    public void Bidi(EchoGrpcDc.EchoBidiServer stream) throws Exception {
        int index = 0;
        while (true) {
            EchoRequest req;
            try {
                req = stream.recv();
            } catch (EOFException eof) {
                return;
            }
            if ("fail".equals(req.message)) {
                throw new StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail");
            }
            stream.send(new EchoResponse(req.message, index++));
        }
    }
}
