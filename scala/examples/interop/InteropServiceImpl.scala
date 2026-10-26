package grpc.testing

import grpcdc.Endpoint
import grpcdc.StatusException
import grpcdc.Wire
import java.io.EOFException
import java.util.Base64
import scala.collection.mutable.ListBuffer

/**
 * TestService implementation (grpc.testing) over the generated
 * Server, mirroring the reference TestServiceImpl semantics the
 * interop cases grade. Used by the Direction-B interop tests
 * (official clients vs generated servers). Mirrors
 * js/test/interop_service.js.
 */
class InteropServiceImpl
    extends TestGrpcDc.TestServiceServer
    with xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceServer {

  private def echoMetadata(ctx: Endpoint#CallContext): Unit = {
    ctx.metadata.get("x-grpc-test-echo-initial").foreach { v =>
      ctx.setHeaders(Map("x-grpc-test-echo-initial" -> v))
    }
    ctx.metadata.get("x-grpc-test-echo-trailing-bin").foreach { v =>
      ctx.setTrailers(Map("x-grpc-test-echo-trailing-bin" -> v))
    }
  }

  private def setOrcaTrailer(ctx: Endpoint#CallContext, report: xds.data.orca.v3.OrcaLoadReport): Unit = {
    ctx.setTrailers(Map(
      "endpoint-load-metrics-bin" -> Base64.getEncoder.encodeToString(report.marshalDc())))
  }

  // Compression interop (server direction): the bridge
  // terminates gzip at the HTTP/2 hop and surfaces the
  // declared encoding as ordinary metadata.
  private def compressionChecks(ctx: Endpoint#CallContext, expectCompressed: BoolValue,
                                responseCompressed: BoolValue): Unit = {
    if (expectCompressed != null && expectCompressed.value
        && ctx.metadata.get("grpc-encoding") != Some("gzip")) {
      throw new StatusException(Wire.CODE_INVALID_ARGUMENT,
        "expected compressed request, got uncompressed")
    }
    if (responseCompressed != null && responseCompressed.value) {
      ctx.setHeaders(Map("grpc-encoding" -> "gzip"))
    }
  }

  private def maybeFail(status: EchoStatus): Unit = {
    if (status != null && (status.code != 0 || status.message.nonEmpty)) {
      throw new StatusException(status.code, status.message)
    }
  }

  private def unaryResponse(req: SimpleRequest): SimpleResponse = {
    maybeFail(req.responseStatus)
    val resp = new SimpleResponse()
    resp.payload = new Payload(req.responseType, new Array[Byte](math.max(0, req.responseSize)))
    resp
  }

  private def sleepInterval(param: ResponseParameters, first: Boolean): Unit = {
    if (!first && param.intervalUs > 0) {
      Thread.sleep((param.intervalUs / 1000).toLong, (param.intervalUs % 1000) * 1000)
    }
  }

  override def EmptyCall(ctx: Endpoint#CallContext, req: Empty): Empty = {
    echoMetadata(ctx)
    new Empty()
  }

  override def UnaryCall(ctx: Endpoint#CallContext, req: SimpleRequest): SimpleResponse = {
    echoMetadata(ctx)
    compressionChecks(ctx, req.expectCompressed, req.responseCompressed)
    if (req.orcaPerQueryReport != null) {
      val report = req.orcaPerQueryReport
      setOrcaTrailer(ctx, new xds.data.orca.v3.OrcaLoadReport(
        report.cpuUtilization, report.memoryUtilization, 0.0,
        report.requestCost, report.utilization))
    } else if (InteropServiceImpl.oobReport != null) {
      setOrcaTrailer(ctx, InteropServiceImpl.oobReport)
    }
    unaryResponse(req)
  }

  override def CacheableUnaryCall(ctx: Endpoint#CallContext, req: SimpleRequest): SimpleResponse = {
    echoMetadata(ctx)
    maybeFail(req.responseStatus)
    val resp = new SimpleResponse()
    resp.payload = if (req.payload != null) req.payload else new Payload()
    resp
  }

  override def StreamingOutputCall(req: StreamingOutputCallRequest,
                                   stream: TestGrpcDc.TestServiceServerStreamServer): Unit = {
    echoMetadata(stream.context)
    maybeFail(req.responseStatus)
    var first = true
    for (param <- req.responseParameters) {
      sleepInterval(param, first)
      first = false
      stream.send(new StreamingOutputCallResponse(
        new Payload(req.responseType, new Array[Byte](math.max(0, param.size)))))
    }
  }

  override def StreamingInputCall(stream: TestGrpcDc.TestServiceClientStreamServer): Unit = {
    echoMetadata(stream.context)
    var total = 0
    var done = false
    while (!done) {
      try {
        val req = stream.recv()
        if (req.expectCompressed != null && req.expectCompressed.value
            && stream.context.metadata.get("grpc-encoding") != Some("gzip")) {
          throw new StatusException(Wire.CODE_INVALID_ARGUMENT,
            "expected compressed request, got uncompressed")
        }
        total += (if (req.payload != null) req.payload.body.length else 0)
      } catch {
        case _: EOFException => done = true
      }
    }
    stream.sendAndClose(new StreamingInputCallResponse(total))
  }

  override def FullDuplexCall(stream: TestGrpcDc.TestServiceBidiServer): Unit = {
    echoMetadata(stream.context)
    var done = false
    while (!done) {
      try {
        val req = stream.recv()
        if (req.orcaOobReport != null) {
          val report = req.orcaOobReport
          InteropServiceImpl.oobReport = new xds.data.orca.v3.OrcaLoadReport(
            report.cpuUtilization, report.memoryUtilization, 0.0,
            Map.empty, report.utilization)
        }
        maybeFail(req.responseStatus)
        var first = true
        for (param <- req.responseParameters) {
          sleepInterval(param, first)
          first = false
          stream.send(new StreamingOutputCallResponse(
            new Payload(req.responseType, new Array[Byte](math.max(0, param.size)))))
        }
      } catch {
        case _: EOFException => done = true
      }
    }
  }

  override def HalfDuplexCall(stream: TestGrpcDc.TestServiceBidiServer): Unit = {
    echoMetadata(stream.context)
    val collected = ListBuffer.empty[StreamingOutputCallRequest]
    var done = false
    while (!done) {
      try {
        collected += stream.recv()
      } catch {
        case _: EOFException => done = true
      }
    }
    for (req <- collected) {
      maybeFail(req.responseStatus)
      var first = true
      for (param <- req.responseParameters) {
        sleepInterval(param, first)
        first = false
        stream.send(new StreamingOutputCallResponse(
          new Payload(req.responseType, new Array[Byte](math.max(0, param.size)))))
      }
    }
  }

  override def UnimplementedCall(ctx: Endpoint#CallContext, req: Empty): Empty = {
    throw new StatusException(Wire.CODE_UNIMPLEMENTED, "not implemented")
  }

  // OpenRcaService (ORCA out-of-band): stream the current OOB
  // report on an interval until the client goes away.
  override def StreamCoreMetrics(req: xds.service.orca.v3.OrcaLoadReportRequest,
                                 stream: xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceServerStreamServer): Unit = {
    while (true) {
      val report = InteropServiceImpl.oobReport
      stream.send(if (report != null) report else new xds.data.orca.v3.OrcaLoadReport())
      Thread.sleep(200)
    }
  }
}

object InteropServiceImpl {
  /** Latest ORCA out-of-band report (full-duplex updates). */
  @volatile var oobReport: xds.data.orca.v3.OrcaLoadReport = null
}
