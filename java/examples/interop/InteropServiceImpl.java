package grpc.testing;

import grpcdc.Endpoint;
import grpcdc.StatusException;
import grpcdc.Wire;
import java.io.EOFException;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;

/**
 * TestService implementation (grpc.testing) over the generated
 * Server, mirroring the reference TestServiceImpl semantics the
 * interop cases grade: payload sizes are answered with zero
 * bodies of the requested size, response_parameters drive
 * streamed responses (interval_us honored), response_status
 * fails the call, streaming input is aggregated by byte count.
 * Used by the Direction-B interop tests (official clients vs
 * generated servers). Mirrors js/test/interop_service.js.
 */
public final class InteropServiceImpl
        implements TestGrpcDc.TestServiceServer, xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceServer {
    /** Latest ORCA out-of-band report (full-duplex updates). */
    private static volatile xds.data.orca.v3.OrcaLoadReport oobReport;

    private static void echoMetadata(Endpoint.CallContext ctx) {
        if (ctx == null) {
            return;
        }
        String initial = ctx.metadata.get("x-grpc-test-echo-initial");
        if (initial != null) {
            ctx.setHeaders(Map.of("x-grpc-test-echo-initial", initial));
        }
        String trailing = ctx.metadata.get("x-grpc-test-echo-trailing-bin");
        if (trailing != null) {
            ctx.setTrailers(Map.of("x-grpc-test-echo-trailing-bin", trailing));
        }
    }

    private static void setOrcaTrailer(Endpoint.CallContext ctx,
                                       xds.data.orca.v3.OrcaLoadReport report) {
        ctx.setTrailers(Map.of("endpoint-load-metrics-bin",
                Base64.getEncoder().encodeToString(report.marshalDc())));
    }

    // Compression interop (server direction): the bridge
    // terminates gzip at the HTTP/2 hop and surfaces the
    // declared encoding as ordinary metadata.
    private static void compressionChecks(Endpoint.CallContext ctx,
                                          BoolValue expectCompressed,
                                          BoolValue responseCompressed) {
        if (expectCompressed != null && expectCompressed.value
                && !"gzip".equals(ctx.metadata.get("grpc-encoding"))) {
            throw new StatusException(Wire.CODE_INVALID_ARGUMENT,
                    "expected compressed request, got uncompressed");
        }
        if (responseCompressed != null && responseCompressed.value) {
            ctx.setHeaders(Map.of("grpc-encoding", "gzip"));
        }
    }

    private static void maybeFail(EchoStatus status) {
        if (status != null && (status.code != 0 || !status.message.isEmpty())) {
            throw new StatusException(status.code, status.message);
        }
    }

    private static SimpleResponse unaryResponse(SimpleRequest req) {
        maybeFail(req.responseStatus);
        Payload payload = new Payload();
        payload.type = req.responseType;
        payload.body = new byte[Math.max(0, req.responseSize)];
        SimpleResponse resp = new SimpleResponse();
        resp.payload = payload;
        return resp;
    }

    private static void streamingResponses(StreamingOutputCallRequest req,
                                           TestGrpcDc.TestServiceStreamingOutputCallServer stream)
            throws Exception {
        maybeFail(req.responseStatus);
        boolean first = true;
        for (ResponseParameters param : req.responseParameters) {
            if (!first && param.intervalUs > 0) {
                Thread.sleep(param.intervalUs / 1000, (param.intervalUs % 1000) * 1000);
            }
            first = false;
            Payload payload = new Payload();
            payload.type = req.responseType;
            payload.body = new byte[Math.max(0, param.size)];
            stream.send(new StreamingOutputCallResponse(payload));
        }
    }

    private static void fullDuplexResponses(StreamingOutputCallRequest req,
                                            TestGrpcDc.TestServiceFullDuplexCallServer stream)
            throws Exception {
        maybeFail(req.responseStatus);
        boolean first = true;
        for (ResponseParameters param : req.responseParameters) {
            if (!first && param.intervalUs > 0) {
                Thread.sleep(param.intervalUs / 1000, (param.intervalUs % 1000) * 1000);
            }
            first = false;
            Payload payload = new Payload();
            payload.type = req.responseType;
            payload.body = new byte[Math.max(0, param.size)];
            stream.send(new StreamingOutputCallResponse(payload));
        }
    }

    @Override
    public Empty EmptyCall(Endpoint.CallContext ctx, Empty req) {
        echoMetadata(ctx);
        return new Empty();
    }

    @Override
    public SimpleResponse UnaryCall(Endpoint.CallContext ctx, SimpleRequest req) {
        echoMetadata(ctx);
        compressionChecks(ctx, req.expectCompressed, req.responseCompressed);
        if (req.orcaPerQueryReport != null) {
            TestOrcaReport report = req.orcaPerQueryReport;
            setOrcaTrailer(ctx, new xds.data.orca.v3.OrcaLoadReport(
                    report.cpuUtilization, report.memoryUtilization, 0,
                    report.requestCost, report.utilization));
        } else if (oobReport != null) {
            setOrcaTrailer(ctx, oobReport);
        }
        return unaryResponse(req);
    }

    @Override
    public SimpleResponse CacheableUnaryCall(Endpoint.CallContext ctx, SimpleRequest req) {
        echoMetadata(ctx);
        maybeFail(req.responseStatus);
        SimpleResponse resp = new SimpleResponse();
        resp.payload = req.payload != null ? req.payload : new Payload();
        return resp;
    }

    @Override
    public void StreamingOutputCall(StreamingOutputCallRequest req,
                                    TestGrpcDc.TestServiceStreamingOutputCallServer stream)
            throws Exception {
        echoMetadata(stream.context());
        // StreamingOutputCallRequest has no expect/response
        // compressed fields in the wire shape used here.
        streamingResponses(req, stream);
    }

    @Override
    public void StreamingInputCall(TestGrpcDc.TestServiceStreamingInputCallServer stream)
            throws Exception {
        echoMetadata(stream.context());
        int total = 0;
        while (true) {
            StreamingInputCallRequest req;
            try {
                req = stream.recv();
            } catch (EOFException eof) {
                break;
            }
            if (req.expectCompressed != null && req.expectCompressed.value
                    && !"gzip".equals(stream.context().metadata.get("grpc-encoding"))) {
                throw new StatusException(Wire.CODE_INVALID_ARGUMENT,
                        "expected compressed request, got uncompressed");
            }
            total += req.payload != null ? req.payload.body.length : 0;
        }
        stream.sendAndClose(new StreamingInputCallResponse(total));
    }

    @Override
    public void FullDuplexCall(TestGrpcDc.TestServiceFullDuplexCallServer stream)
            throws Exception {
        echoMetadata(stream.context());
        while (true) {
            StreamingOutputCallRequest req;
            try {
                req = stream.recv();
            } catch (EOFException eof) {
                return;
            }
            if (req.orcaOobReport != null) {
                TestOrcaReport report = req.orcaOobReport;
                oobReport = new xds.data.orca.v3.OrcaLoadReport(
                        report.cpuUtilization, report.memoryUtilization, 0,
                        Map.of(), report.utilization);
            }
            fullDuplexResponses(req, stream);
        }
    }

    @Override
    public void HalfDuplexCall(TestGrpcDc.TestServiceHalfDuplexCallServer stream)
            throws Exception {
        echoMetadata(stream.context());
        List<StreamingOutputCallRequest> collected = new ArrayList<>();
        while (true) {
            StreamingOutputCallRequest req;
            try {
                req = stream.recv();
            } catch (EOFException eof) {
                break;
            }
            collected.add(req);
        }
        for (StreamingOutputCallRequest req : collected) {
            maybeFail(req.responseStatus);
            boolean first = true;
            for (ResponseParameters param : req.responseParameters) {
                if (!first && param.intervalUs > 0) {
                    Thread.sleep(param.intervalUs / 1000, (param.intervalUs % 1000) * 1000);
                }
                first = false;
                Payload payload = new Payload();
                payload.type = req.responseType;
                payload.body = new byte[Math.max(0, param.size)];
                stream.send(new StreamingOutputCallResponse(payload));
            }
        }
    }

    @Override
    public Empty UnimplementedCall(Endpoint.CallContext ctx, Empty req) {
        throw new StatusException(Wire.CODE_UNIMPLEMENTED, "not implemented");
    }

    // OpenRcaService (ORCA out-of-band): stream the current OOB
    // report on an interval until the client goes away.
    @Override
    public void StreamCoreMetrics(xds.service.orca.v3.OrcaLoadReportRequest req,
                                  xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceStreamCoreMetricsServer stream)
            throws Exception {
        while (true) {
            xds.data.orca.v3.OrcaLoadReport report = oobReport;
            stream.send(report != null ? report : new xds.data.orca.v3.OrcaLoadReport());
            Thread.sleep(200);
        }
    }
}
