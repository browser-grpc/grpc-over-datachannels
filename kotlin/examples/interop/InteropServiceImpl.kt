package grpc.testing

import grpcdc.Endpoint
import grpcdc.StatusException
import grpcdc.Wire
import java.io.EOFException
import java.util.Base64

/**
 * TestService implementation (grpc.testing) over the generated
 * Server, mirroring the reference TestServiceImpl semantics the
 * interop cases grade. Used by the Direction-B interop tests
 * (official clients vs generated servers). Mirrors
 * js/test/interop_service.js.
 */
class InteropServiceImpl :
    TestGrpcDc.TestServiceServer,
    xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceServer {

    companion object {
        /** Latest ORCA out-of-band report (full-duplex updates). */
        @Volatile
        var oobReport: xds.data.orca.v3.OrcaLoadReport? = null
    }

    private fun echoMetadata(ctx: Endpoint.CallContext) {
        ctx.metadata["x-grpc-test-echo-initial"]?.let {
            ctx.setHeaders(mapOf("x-grpc-test-echo-initial" to it))
        }
        ctx.metadata["x-grpc-test-echo-trailing-bin"]?.let {
            ctx.setTrailers(mapOf("x-grpc-test-echo-trailing-bin" to it))
        }
    }

    private fun setOrcaTrailer(ctx: Endpoint.CallContext, report: xds.data.orca.v3.OrcaLoadReport) {
        ctx.setTrailers(mapOf(
            "endpoint-load-metrics-bin" to Base64.getEncoder().encodeToString(report.marshalDc())))
    }

    // Compression interop (server direction): the bridge
    // terminates gzip at the HTTP/2 hop and surfaces the
    // declared encoding as ordinary metadata.
    private fun compressionChecks(ctx: Endpoint.CallContext, expectCompressed: BoolValue?,
                                  responseCompressed: BoolValue?) {
        if (expectCompressed?.value == true && ctx.metadata["grpc-encoding"] != "gzip") {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT,
                "expected compressed request, got uncompressed")
        }
        if (responseCompressed?.value == true) {
            ctx.setHeaders(mapOf("grpc-encoding" to "gzip"))
        }
    }

    private fun maybeFail(status: EchoStatus?) {
        if (status != null && (status.code != 0 || status.message.isNotEmpty())) {
            throw StatusException(status.code, status.message)
        }
    }

    private fun unaryResponse(req: SimpleRequest): SimpleResponse {
        maybeFail(req.responseStatus)
        val resp = SimpleResponse()
        resp.payload = Payload(req.responseType, ByteArray(maxOf(0, req.responseSize)))
        return resp
    }

    private fun sleepInterval(param: ResponseParameters, first: Boolean) {
        if (!first && param.intervalUs > 0) {
            Thread.sleep((param.intervalUs / 1000).toLong(), (param.intervalUs % 1000) * 1000)
        }
    }

    override fun EmptyCall(ctx: Endpoint.CallContext, req: Empty): Empty {
        echoMetadata(ctx)
        return Empty()
    }

    override fun UnaryCall(ctx: Endpoint.CallContext, req: SimpleRequest): SimpleResponse {
        echoMetadata(ctx)
        compressionChecks(ctx, req.expectCompressed, req.responseCompressed)
        val perQuery = req.orcaPerQueryReport
        if (perQuery != null) {
            setOrcaTrailer(ctx, xds.data.orca.v3.OrcaLoadReport(
                perQuery.cpuUtilization, perQuery.memoryUtilization, 0.0,
                perQuery.requestCost, perQuery.utilization))
        } else {
            oobReport?.let { setOrcaTrailer(ctx, it) }
        }
        return unaryResponse(req)
    }

    override fun CacheableUnaryCall(ctx: Endpoint.CallContext, req: SimpleRequest): SimpleResponse {
        echoMetadata(ctx)
        maybeFail(req.responseStatus)
        val resp = SimpleResponse()
        resp.payload = req.payload ?: Payload()
        return resp
    }

    override fun StreamingOutputCall(req: StreamingOutputCallRequest,
                                     stream: TestGrpcDc.TestServiceStreamingOutputCallServer) {
        echoMetadata(stream.context)
        maybeFail(req.responseStatus)
        var first = true
        for (param in req.responseParameters) {
            sleepInterval(param, first)
            first = false
            stream.send(StreamingOutputCallResponse(
                Payload(req.responseType, ByteArray(maxOf(0, param.size)))))
        }
    }

    override fun StreamingInputCall(stream: TestGrpcDc.TestServiceStreamingInputCallServer) {
        echoMetadata(stream.context)
        var total = 0
        while (true) {
            val req: StreamingInputCallRequest
            try {
                req = stream.recv()
            } catch (eof: EOFException) {
                break
            }
            if (req.expectCompressed?.value == true
                && stream.context.metadata["grpc-encoding"] != "gzip") {
                throw StatusException(Wire.CODE_INVALID_ARGUMENT,
                    "expected compressed request, got uncompressed")
            }
            total += req.payload?.body?.size ?: 0
        }
        stream.sendAndClose(StreamingInputCallResponse(total))
    }

    override fun FullDuplexCall(stream: TestGrpcDc.TestServiceFullDuplexCallServer) {
        echoMetadata(stream.context)
        while (true) {
            val req: StreamingOutputCallRequest
            try {
                req = stream.recv()
            } catch (eof: EOFException) {
                return
            }
            req.orcaOobReport?.let { report ->
                oobReport = xds.data.orca.v3.OrcaLoadReport(
                    report.cpuUtilization, report.memoryUtilization, 0.0,
                    mutableMapOf(), report.utilization)
            }
            maybeFail(req.responseStatus)
            var first = true
            for (param in req.responseParameters) {
                sleepInterval(param, first)
                first = false
                stream.send(StreamingOutputCallResponse(
                    Payload(req.responseType, ByteArray(maxOf(0, param.size)))))
            }
        }
    }

    override fun HalfDuplexCall(stream: TestGrpcDc.TestServiceHalfDuplexCallServer) {
        echoMetadata(stream.context)
        val collected = mutableListOf<StreamingOutputCallRequest>()
        while (true) {
            try {
                collected.add(stream.recv())
            } catch (eof: EOFException) {
                break
            }
        }
        for (req in collected) {
            maybeFail(req.responseStatus)
            var first = true
            for (param in req.responseParameters) {
                sleepInterval(param, first)
                first = false
                stream.send(StreamingOutputCallResponse(
                    Payload(req.responseType, ByteArray(maxOf(0, param.size)))))
            }
        }
    }

    override fun UnimplementedCall(ctx: Endpoint.CallContext, req: Empty): Empty {
        throw StatusException(Wire.CODE_UNIMPLEMENTED, "not implemented")
    }

    // OpenRcaService (ORCA out-of-band): stream the current OOB
    // report on an interval until the client goes away.
    override fun StreamCoreMetrics(req: xds.service.orca.v3.OrcaLoadReportRequest,
                                   stream: xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceStreamCoreMetricsServer) {
        while (true) {
            stream.send(oobReport ?: xds.data.orca.v3.OrcaLoadReport())
            Thread.sleep(200)
        }
    }
}
