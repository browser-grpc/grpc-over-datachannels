import Foundation

/// TestService implementation (grpc.testing) over the generated
/// Server, mirroring the reference TestServiceImpl semantics the
/// interop cases grade. Used by the Direction-B interop tests
/// (official clients vs generated servers). Mirrors
/// js/test/interop_service.js.
final class InteropServiceImpl: TestGrpcDc.TestServiceServer, OrcaGrpcDc.OpenRcaServiceServer {
    /// Latest ORCA out-of-band report (full-duplex updates).
    static var oobReport: OrcaLoadReport? = nil

    private func EchoMetadata(_ ctx: Endpoint.CallContext) {
        if let initial = ctx.metadata["x-grpc-test-echo-initial"] {
            ctx.SetHeaders(["x-grpc-test-echo-initial": initial])
        }
        if let trailing = ctx.metadata["x-grpc-test-echo-trailing-bin"] {
            ctx.SetTrailers(["x-grpc-test-echo-trailing-bin": trailing])
        }
    }

    private func SetOrcaTrailer(_ ctx: Endpoint.CallContext, _ report: OrcaLoadReport) {
        ctx.SetTrailers([
            "endpoint-load-metrics-bin": Data(report.MarshalDc()).base64EncodedString(),
        ])
    }

    // Compression interop (server direction): the bridge
    // terminates gzip at the HTTP/2 hop and surfaces the
    // declared encoding as ordinary metadata.
    private func CompressionChecks(_ ctx: Endpoint.CallContext, _ expectCompressed: BoolValue?,
                                   _ responseCompressed: BoolValue?) throws {
        if expectCompressed?.value == true && ctx.metadata["grpc-encoding"] != "gzip" {
            throw StatusException(Wire.CodeInvalidArgument,
                                  "expected compressed request, got uncompressed")
        }
        if responseCompressed?.value == true {
            ctx.SetHeaders(["grpc-encoding": "gzip"])
        }
    }

    private func MaybeFail(_ status: EchoStatus?) throws {
        guard let status = status else { return }
        if status.code != 0 || !status.message.isEmpty {
            throw StatusException(Int(status.code), status.message)
        }
    }

    private func UnaryResponse(_ req: SimpleRequest) throws -> SimpleResponse {
        try MaybeFail(req.responseStatus)
        let resp = SimpleResponse()
        resp.payload = Payload(req.responseType,
                               [UInt8](repeating: 0, count: max(0, Int(req.responseSize))))
        return resp
    }

    private func SendResponses(_ req: StreamingOutputCallRequest,
                               _ send: (StreamingOutputCallResponse) throws -> Void) throws {
        try MaybeFail(req.responseStatus)
        var first = true
        for param in req.responseParameters {
            if !first && param.intervalUs > 0 {
                Thread.sleep(forTimeInterval: Double(param.intervalUs) / 1_000_000.0)
            }
            first = false
            try send(StreamingOutputCallResponse(
                Payload(req.responseType, [UInt8](repeating: 0, count: max(0, Int(param.size))))))
        }
    }

    func EmptyCall(_ ctx: Endpoint.CallContext, _ req: Empty) throws -> Empty {
        EchoMetadata(ctx)
        return Empty()
    }

    func UnaryCall(_ ctx: Endpoint.CallContext, _ req: SimpleRequest) throws -> SimpleResponse {
        EchoMetadata(ctx)
        try CompressionChecks(ctx, req.expectCompressed, req.responseCompressed)
        if let perQuery = req.orcaPerQueryReport {
            SetOrcaTrailer(ctx, OrcaLoadReport(
                perQuery.cpuUtilization, perQuery.memoryUtilization, 0,
                perQuery.requestCost, perQuery.utilization))
        } else if let oob = InteropServiceImpl.oobReport {
            SetOrcaTrailer(ctx, oob)
        }
        return try UnaryResponse(req)
    }

    func CacheableUnaryCall(_ ctx: Endpoint.CallContext, _ req: SimpleRequest) throws -> SimpleResponse {
        EchoMetadata(ctx)
        try MaybeFail(req.responseStatus)
        let resp = SimpleResponse()
        resp.payload = req.payload ?? Payload()
        return resp
    }

    func StreamingOutputCall(_ req: StreamingOutputCallRequest,
                             _ stream: TestGrpcDc.TestServiceStreamingOutputCallServer) throws {
        EchoMetadata(stream.context)
        try SendResponses(req) { resp in try stream.Send(resp) }
    }

    func StreamingInputCall(_ stream: TestGrpcDc.TestServiceStreamingInputCallServer) throws {
        EchoMetadata(stream.context)
        var total = 0
        while true {
            let req: StreamingInputCallRequest
            do {
                req = try stream.Recv()
            } catch is EndOfStreamError {
                break
            }
            if req.expectCompressed?.value == true
                && stream.context.metadata["grpc-encoding"] != "gzip" {
                throw StatusException(Wire.CodeInvalidArgument,
                                      "expected compressed request, got uncompressed")
            }
            total += req.payload?.body.count ?? 0
        }
        stream.SendAndClose(StreamingInputCallResponse(Int32(total)))
    }

    func FullDuplexCall(_ stream: TestGrpcDc.TestServiceFullDuplexCallServer) throws {
        EchoMetadata(stream.context)
        while true {
            let req: StreamingOutputCallRequest
            do {
                req = try stream.Recv()
            } catch is EndOfStreamError {
                return
            }
            if let oob = req.orcaOobReport {
                InteropServiceImpl.oobReport = OrcaLoadReport(
                    oob.cpuUtilization, oob.memoryUtilization, 0, [:], oob.utilization)
            }
            try SendResponses(req) { resp in try stream.Send(resp) }
        }
    }

    func HalfDuplexCall(_ stream: TestGrpcDc.TestServiceHalfDuplexCallServer) throws {
        EchoMetadata(stream.context)
        var collected: [StreamingOutputCallRequest] = []
        while true {
            do {
                collected.append(try stream.Recv())
            } catch is EndOfStreamError {
                break
            }
        }
        for req in collected {
            try SendResponses(req) { resp in try stream.Send(resp) }
        }
    }

    func UnimplementedCall(_ ctx: Endpoint.CallContext, _ req: Empty) throws -> Empty {
        throw StatusException(Wire.CodeUnimplemented, "not implemented")
    }

    // OpenRcaService (ORCA out-of-band): stream the current OOB
    // report on an interval until the client goes away.
    func StreamCoreMetrics(_ req: OrcaLoadReportRequest,
                           _ stream: OrcaGrpcDc.OpenRcaServiceStreamCoreMetricsServer) throws {
        while true {
            try stream.Send(InteropServiceImpl.oobReport ?? OrcaLoadReport())
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
