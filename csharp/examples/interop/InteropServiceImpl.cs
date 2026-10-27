using Grpcdc;

namespace Grpc.testing;

/// <summary>
/// TestService implementation (grpc.testing) over the generated
/// Server, mirroring the reference TestServiceImpl semantics the
/// interop cases grade. Used by the Direction-B interop tests
/// (official clients vs generated servers). Mirrors
/// js/test/interop_service.js.
/// </summary>
public sealed class InteropServiceImpl : TestGrpcDc.TestServiceServer, Xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceServer
{
    /// <summary>Latest ORCA out-of-band report (full-duplex updates).</summary>
    private static volatile Xds.data.orca.v3.OrcaLoadReport OobReport;

    private static void EchoMetadata(Endpoint.CallContext ctx)
    {
        if (ctx.Metadata.TryGetValue("x-grpc-test-echo-initial", out string initial))
        {
            ctx.SetHeaders(new Dictionary<string, string> { ["x-grpc-test-echo-initial"] = initial });
        }
        if (ctx.Metadata.TryGetValue("x-grpc-test-echo-trailing-bin", out string trailing))
        {
            ctx.SetTrailers(new Dictionary<string, string> { ["x-grpc-test-echo-trailing-bin"] = trailing });
        }
    }

    private static void SetOrcaTrailer(Endpoint.CallContext ctx, Xds.data.orca.v3.OrcaLoadReport report)
    {
        ctx.SetTrailers(new Dictionary<string, string>
        {
            ["endpoint-load-metrics-bin"] = Convert.ToBase64String(report.MarshalDc()),
        });
    }

    // Compression interop (server direction): the bridge
    // terminates gzip at the HTTP/2 hop and surfaces the
    // declared encoding as ordinary metadata.
    private static void CompressionChecks(Endpoint.CallContext ctx, BoolValue expectCompressed,
                                          BoolValue responseCompressed)
    {
        if (expectCompressed != null && expectCompressed.Value
            && !(ctx.Metadata.TryGetValue("grpc-encoding", out string enc) && enc == "gzip"))
        {
            throw new StatusException(Wire.CodeInvalidArgument,
                "expected compressed request, got uncompressed");
        }
        if (responseCompressed != null && responseCompressed.Value)
        {
            ctx.SetHeaders(new Dictionary<string, string> { ["grpc-encoding"] = "gzip" });
        }
    }

    private static void MaybeFail(EchoStatus status)
    {
        if (status != null && (status.Code != 0 || status.Message.Length > 0))
        {
            throw new StatusException(status.Code, status.Message);
        }
    }

    private static SimpleResponse UnaryResponse(SimpleRequest req)
    {
        MaybeFail(req.ResponseStatus);
        return new SimpleResponse
        {
            Payload = new Payload(req.ResponseType, new byte[Math.Max(0, req.ResponseSize)]),
        };
    }

    private static void SleepInterval(ResponseParameters param, bool first)
    {
        if (!first && param.IntervalUs > 0)
        {
            Thread.Sleep(TimeSpan.FromMicroseconds(param.IntervalUs));
        }
    }

    private static void SendResponses(StreamingOutputCallRequest req, Action<StreamingOutputCallResponse> send)
    {
        MaybeFail(req.ResponseStatus);
        bool first = true;
        foreach (ResponseParameters param in req.ResponseParameters)
        {
            SleepInterval(param, first);
            first = false;
            send(new StreamingOutputCallResponse(
                new Payload(req.ResponseType, new byte[Math.Max(0, param.Size)])));
        }
    }

    public Empty EmptyCall(Endpoint.CallContext ctx, Empty req)
    {
        EchoMetadata(ctx);
        return new Empty();
    }

    public SimpleResponse UnaryCall(Endpoint.CallContext ctx, SimpleRequest req)
    {
        EchoMetadata(ctx);
        CompressionChecks(ctx, req.ExpectCompressed, req.ResponseCompressed);
        if (req.OrcaPerQueryReport != null)
        {
            TestOrcaReport report = req.OrcaPerQueryReport;
            SetOrcaTrailer(ctx, new Xds.data.orca.v3.OrcaLoadReport(
                report.CpuUtilization, report.MemoryUtilization, 0,
                report.RequestCost, report.Utilization));
        }
        else if (OobReport != null)
        {
            SetOrcaTrailer(ctx, OobReport);
        }
        return UnaryResponse(req);
    }

    public SimpleResponse CacheableUnaryCall(Endpoint.CallContext ctx, SimpleRequest req)
    {
        EchoMetadata(ctx);
        MaybeFail(req.ResponseStatus);
        return new SimpleResponse { Payload = req.Payload ?? new Payload() };
    }

    public void StreamingOutputCall(StreamingOutputCallRequest req,
                                    TestGrpcDc.TestServiceStreamingOutputCallServer stream)
    {
        EchoMetadata(stream.Context);
        SendResponses(req, stream.Send);
    }

    public void StreamingInputCall(TestGrpcDc.TestServiceStreamingInputCallServer stream)
    {
        EchoMetadata(stream.Context);
        int total = 0;
        while (true)
        {
            StreamingInputCallRequest req;
            try
            {
                req = stream.Recv();
            }
            catch (EndOfStreamException)
            {
                break;
            }
            if (req.ExpectCompressed != null && req.ExpectCompressed.Value
                && !(stream.Context.Metadata.TryGetValue("grpc-encoding", out string enc) && enc == "gzip"))
            {
                throw new StatusException(Wire.CodeInvalidArgument,
                    "expected compressed request, got uncompressed");
            }
            total += req.Payload != null ? req.Payload.Body.Length : 0;
        }
        stream.SendAndClose(new StreamingInputCallResponse(total));
    }

    public void FullDuplexCall(TestGrpcDc.TestServiceFullDuplexCallServer stream)
    {
        EchoMetadata(stream.Context);
        while (true)
        {
            StreamingOutputCallRequest req;
            try
            {
                req = stream.Recv();
            }
            catch (EndOfStreamException)
            {
                return;
            }
            if (req.OrcaOobReport != null)
            {
                TestOrcaReport report = req.OrcaOobReport;
                OobReport = new Xds.data.orca.v3.OrcaLoadReport(
                    report.CpuUtilization, report.MemoryUtilization, 0,
                    new Dictionary<string, double>(), report.Utilization);
            }
            SendResponses(req, stream.Send);
        }
    }

    public void HalfDuplexCall(TestGrpcDc.TestServiceHalfDuplexCallServer stream)
    {
        EchoMetadata(stream.Context);
        var collected = new List<StreamingOutputCallRequest>();
        while (true)
        {
            try
            {
                collected.Add(stream.Recv());
            }
            catch (EndOfStreamException)
            {
                break;
            }
        }
        foreach (StreamingOutputCallRequest req in collected)
        {
            SendResponses(req, stream.Send);
        }
    }

    public Empty UnimplementedCall(Endpoint.CallContext ctx, Empty req)
    {
        throw new StatusException(Wire.CodeUnimplemented, "not implemented");
    }

    // OpenRcaService (ORCA out-of-band): stream the current OOB
    // report on an interval until the client goes away.
    public void StreamCoreMetrics(Xds.service.orca.v3.OrcaLoadReportRequest req,
                                  Xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceStreamCoreMetricsServer stream)
    {
        while (true)
        {
            stream.Send(OobReport ?? new Xds.data.orca.v3.OrcaLoadReport());
            Thread.Sleep(200);
        }
    }
}
