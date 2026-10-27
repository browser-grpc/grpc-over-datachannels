package tests

import echo.StdioTransport
import grpc.testing.{EchoStatus, Empty, Payload, ResponseParameters, SimpleRequest, StreamingInputCallRequest, StreamingInputCallResponse, StreamingOutputCallRequest, StreamingOutputCallResponse, TestGrpcDc, TestOrcaReport}
import grpcdc.{Channel, StatusException}
import java.io.{BufferedReader, File, InputStreamReader}
import java.net.ServerSocket
import java.util.Base64
import scala.util.Using

/**
 * Interop client grading: the generated Scala TestService client
 * runs the canonical grpc interop cases (generated table:
 * InteropCases) against the official grpc-go TestServiceServer,
 * through the bridge (dc-to-http2, stdio = DataChannel). Mirrors
 * the Java/C#/Kotlin/JS/Python/Go/Rust interop oracle suites.
 * Skips when the oracle server binary is not built (Dockerfile.ci
 * builds it).
 */

private def interopPayload(size: Int): Payload = new Payload(body = new Array[Byte](size))

private def interopStreamRequest(respSizes: Array[Int], payloadSize: Int): StreamingOutputCallRequest = {
  val req = new StreamingOutputCallRequest(payload = interopPayload(payloadSize))
  req.responseParameters = respSizes.map(s => new ResponseParameters(size = s)).toList
  req
}

private def expectStatus(code: Int, message: String, what: String)(call: => Unit): Unit = {
  try {
    call
  } catch {
    case e: StatusException =>
      check(e.code == code, s"$what: code ${e.code} != $code")
      if (message.nonEmpty) {
        check(e.getMessage == message, s"$what: message '${e.getMessage}' != '$message'")
      }
      return
  }
  throw new AssertionError(s"$what: expected status $code, call succeeded")
}

// ORCA rows (upstream orca_per_rpc / orca_oob): per-RPC the
// report returns as the serialized OrcaLoadReport in the
// endpoint-load-metrics-bin trailer (base64 -bin value); OOB the
// value fed through FullDuplexCall comes back on the
// OpenRcaService StreamCoreMetrics stream.
// Compression rows (upstream client_compressed_unary,
// client_compressed_streaming, server_compressed_unary,
// server_compressed_streaming): the DataChannel wire is
// compression-free; the client declares grpc-encoding: gzip
// and the bridge gzips request messages on the HTTP/2 hop,
// decompressing responses the same way.
private def runCompressionCases(client: TestGrpcDc.TestServiceClient): Unit = {
  val gzip = Map("grpc-encoding" -> "gzip")
  {
    val req = new SimpleRequest(
      responseSize = 31415, payload = interopPayload(271828),
      expectCompressed = new grpc.testing.BoolValue(true))
    val resp = client.UnaryCall(req, gzip)
    check(resp.payload.body.length == 31415, "client_compressed_unary: body")
    println("interop case ok: client_compressed_unary")
  }
  {
    val sizes = Array(27182, 8, 1828, 45904)
    val reqs = sizes.map(s => new StreamingInputCallRequest(
      payload = interopPayload(s), expectCompressed = new grpc.testing.BoolValue(true))).toList
    val resp = client.StreamingInputCall(reqs, gzip)
    check(resp.aggregatedPayloadSize == sizes.sum,
      s"client_compressed_streaming: aggregated ${resp.aggregatedPayloadSize}")
    println("interop case ok: client_compressed_streaming")
  }
  {
    val req = new SimpleRequest(
      responseSize = 31415, payload = interopPayload(271828),
      responseCompressed = new grpc.testing.BoolValue(true))
    val resp = client.UnaryCall(req)
    check(resp.payload.body.length == 31415, "server_compressed_unary: body")
    println("interop case ok: server_compressed_unary")
  }
  {
    val sizes = Array(31415, 9, 2653, 58979)
    val req = new StreamingOutputCallRequest()
    req.responseParameters = sizes.map(s => new ResponseParameters(
      size = s, compressed = new grpc.testing.BoolValue(true))).toList
    Using.resource(client.StreamingOutputCall(req)) { stream =>
      for (size <- sizes) {
        val resp = stream.recv()
        check(resp.payload.body.length == size,
          s"server_compressed_streaming: body ${resp.payload.body.length}")
      }
    }
    println("interop case ok: server_compressed_streaming")
  }
}

private def runOrcaCases(channel: Channel, client: TestGrpcDc.TestServiceClient): Unit = {
  val req = new SimpleRequest()
  req.orcaPerQueryReport = new TestOrcaReport(
    cpuUtilization = 0.8210,
    memoryUtilization = 0.5847,
    requestCost = Map("cost" -> 3456.32),
    utilization = Map("util" -> 0.30499))
  val stream = channel.serverStream("/grpc.testing.TestService/UnaryCall", req, null)
  try {
    val resp = new grpc.testing.SimpleResponse()
    stream.recv(resp)
    try {
      stream.recv(new grpc.testing.SimpleResponse())
      throw new AssertionError("orca_per_rpc: expected EOF")
    } catch {
      case _: java.io.EOFException => // end of stream: trailers now readable
    }
    val encodedOpt = stream.trailers.get("endpoint-load-metrics-bin")
    check(encodedOpt.isDefined, "orca_per_rpc: no endpoint-load-metrics-bin trailer")
    val encoded = encodedOpt.get
    val raw = Base64.getDecoder.decode(
      encoded + "=" * ((4 - encoded.length % 4) % 4))
    val loadReport = new xds.data.orca.v3.OrcaLoadReport()
    loadReport.unmarshalDc(raw)
    check(loadReport.cpuUtilization == 0.8210
      && loadReport.memUtilization == 0.5847
      && loadReport.requestCost.getOrElse("cost", 0.0) == 3456.32
      && loadReport.utilization.getOrElse("util", 0.0) == 0.30499,
      s"orca_per_rpc: report ${loadReport.cpuUtilization}/${loadReport.memUtilization}")
  } finally {
    stream.close()
  }
  println("interop case ok: orca_per_rpc")

  val feed = new StreamingOutputCallRequest()
  feed.orcaOobReport = new TestOrcaReport(
    cpuUtilization = 0.9,
    memoryUtilization = 0.85,
    utilization = Map("util" -> 0.5))
  Using.resource(client.FullDuplexCall(List(feed))) { duplex =>
    var done = false
    while (!done) {
      try {
        duplex.recv()
      } catch {
        case _: java.io.EOFException => done = true
      }
    }
  }
  val orca = new xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceClient(channel)
  val deadline = System.currentTimeMillis() + 30000
  var matched = false
  Using.resource(orca.StreamCoreMetrics(new xds.service.orca.v3.OrcaLoadReportRequest())) { stream =>
    while (!matched && System.currentTimeMillis() < deadline) {
      val got = stream.recv()
      matched = got.cpuUtilization == 0.9 && got.memUtilization == 0.85
        && got.utilization.getOrElse("util", 0.0) == 0.5
    }
  }
  check(matched, "orca_oob: no matching OOB report within 30s")
  println("interop case ok: orca_oob")
}

private def runInteropCases(
    channel: Channel,
    client: TestGrpcDc.TestServiceClient,
    unimpl: TestGrpcDc.UnimplementedServiceClient,
): Unit = {
  for (row <- InteropCases.CASES) {
    val name = row(0).asInstanceOf[String]
    val kind = row(1).asInstanceOf[String]
    val reqSizes = row(2).asInstanceOf[Array[Int]]
    val respSizes = row(3).asInstanceOf[Array[Int]]
    val statusCode = row(4).asInstanceOf[Int]
    val statusMessage = row(5).asInstanceOf[String]
    kind match {
      case "EMPTY" => client.EmptyCall(new Empty())
      case "LARGE_UNARY" =>
        val req = new SimpleRequest(responseSize = respSizes(0), payload = interopPayload(reqSizes(0)))
        val resp = client.UnaryCall(req)
        check(resp.payload.body.length == respSizes(0), s"$name: body ${resp.payload.body.length}")
      case "CLIENT_STREAMING" =>
        val reqs = reqSizes.map(s => new StreamingInputCallRequest(payload = interopPayload(s))).toList
        val resp = client.StreamingInputCall(reqs)
        check(resp.aggregatedPayloadSize == reqSizes.sum, s"$name: aggregated ${resp.aggregatedPayloadSize}")
      case "SERVER_STREAMING" =>
        Using.resource(client.StreamingOutputCall(interopStreamRequest(respSizes, 0))) { stream =>
          for (size <- respSizes) {
            val resp = stream.recv()
            check(resp.payload.body.length == size, s"$name: body ${resp.payload.body.length} != $size")
          }
          try {
            stream.recv()
            throw new AssertionError(s"$name: expected EOF")
          } catch {
            case _: java.io.EOFException => // end of stream
          }
        }
      case "PING_PONG" =>
        val reqs = respSizes.indices.map(i => interopStreamRequest(Array(respSizes(i)), reqSizes(i))).toList
        Using.resource(client.FullDuplexCall(reqs)) { stream =>
          for (size <- respSizes) {
            val resp = stream.recv()
            check(resp.payload.body.length == size, s"$name: body ${resp.payload.body.length} != $size")
          }
        }
      case "EMPTY_STREAM" =>
        Using.resource(client.FullDuplexCall(List.empty)) { stream =>
          try {
            stream.recv()
            throw new AssertionError(s"$name: expected EOF")
          } catch {
            case _: java.io.EOFException => // end of stream
          }
        }
      case "CUSTOM_METADATA" =>
        // Upstream custom_metadata, duplex leg (mirrors the Java runner).
        val trailingBin = Base64.getEncoder.encodeToString(Array[Byte](0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b))
        val md = Map(
          "x-grpc-test-echo-initial" -> "test_initial_metadata_value",
          "x-grpc-test-echo-trailing-bin" -> trailingBin)
        Using.resource(client.FullDuplexCall(List(interopStreamRequest(Array(1), 1)), md)) { stream =>
          val resp = stream.recv()
          check(resp.payload.body.length == 1, s"$name: body")
          try {
            stream.recv()
            throw new AssertionError(s"$name: expected EOF")
          } catch {
            case _: java.io.EOFException => // end of stream: trailers now readable
          }
          check(stream.headers != null && stream.headers.get("x-grpc-test-echo-initial").contains("test_initial_metadata_value"),
            s"$name: initial ${stream.headers}")
          check(stream.trailers != null && stream.trailers.get("x-grpc-test-echo-trailing-bin").contains(trailingBin),
            s"$name: trailing ${stream.trailers}")
        }
      case "STATUS_UNARY" =>
        val req = new SimpleRequest(responseStatus = new EchoStatus(statusCode, statusMessage))
        expectStatus(statusCode, statusMessage, name) { client.UnaryCall(req) }
      case "STATUS_DUPLEX" =>
        val req = interopStreamRequest(Array(0), 0)
        req.responseStatus = new EchoStatus(statusCode, statusMessage)
        expectStatus(statusCode, statusMessage, name) {
          Using.resource(client.FullDuplexCall(List(req))) { stream => stream.recv() }
        }
      case "SPECIAL_STATUS" =>
        val req = new SimpleRequest(responseStatus = new EchoStatus(statusCode, statusMessage))
        expectStatus(statusCode, statusMessage, name) { client.UnaryCall(req) }
      case "CANCEL_AFTER_BEGIN" =>
        // Begin a client-streaming call and cancel it before
        // sending any request: the pending recv must report
        // CANCELLED.
        val stream = channel.openStream("/grpc.testing.TestService/StreamingInputCall")
        stream.cancel()
        expectStatus(statusCode, "", name) { stream.recv(new StreamingInputCallResponse()) }
      case "CANCEL_AFTER_FIRST" =>
        // Duplex call (no half-close): the server answers the
        // one request, then waits for more input, so the cancel
        // deterministically lands mid-call (same shape as the
        // Python/JS suites).
        val stream = channel.openStream("/grpc.testing.TestService/FullDuplexCall")
        stream.send(interopStreamRequest(Array(respSizes(0)), 1))
        val resp = new StreamingOutputCallResponse()
        stream.recv(resp)
        check(resp.payload.body.length == respSizes(0), s"$name: body ${resp.payload.body.length}")
        stream.cancel()
        expectStatus(statusCode, "", name) { stream.recv(new StreamingOutputCallResponse()) }
      case "TIMEOUT_SLEEPING" =>
        val req = new StreamingOutputCallRequest()
        req.responseParameters = respSizes.map(s => new ResponseParameters(size = s, intervalUs = 1000000)).toList
        expectStatus(statusCode, "", name) {
          Using.resource(client.StreamingOutputCall(req, null, java.time.Duration.ofMillis(100))) { stream =>
            stream.recv()
          }
        }
      case "UNIMPLEMENTED_METHOD" =>
        expectStatus(statusCode, "", name) { client.UnimplementedCall(new Empty()) }
      case "UNIMPLEMENTED_SERVICE" =>
        expectStatus(statusCode, "", name) { unimpl.UnimplementedCall(new Empty()) }
      case _ => throw new AssertionError(s"unknown interop kind $kind")
    }
    println(s"interop case ok: $name")
  }
}

def testInteropOracle(): Unit = {
  val rootPath = root()
  val serverBin = new File(rootPath, "oracle/go-interop/interop-server")
  if (!serverBin.canExecute) {
    println("TestInteropOracle SKIP (go interop server not built)")
    return
  }
  val port = Using.resource(new ServerSocket(0))(_.getLocalPort)
  val server = new ProcessBuilder(serverBin.getPath, "-port", port.toString)
    .redirectErrorStream(true)
    .start()
  try {
    val drain = new Thread(() => {
      val reader = new BufferedReader(new InputStreamReader(server.getInputStream))
      while (reader.readLine() != null) {
        // discard
      }
    })
    drain.setDaemon(true)
    drain.start()
    val deadline = System.currentTimeMillis() + 30000
    var ready = false
    while (System.currentTimeMillis() < deadline && !ready) {
      try {
        new java.net.Socket("127.0.0.1", port).close()
        ready = true
      } catch {
        case _: Exception => Thread.sleep(100)
      }
    }
    check(ready, "go interop server did not start")

    val bridge = new ProcessBuilder("node", new File(rootPath, "oracle/bridge.mjs").getPath,
      "dc-to-http2", "--grpc", s"127.0.0.1:$port")
      .redirectErrorStream(false)
      .start()
    try {
      val errDrain = new Thread(() => {
        val reader = new BufferedReader(new InputStreamReader(bridge.getErrorStream))
        while (reader.readLine() != null) {
          // discard
        }
      })
      errDrain.setDaemon(true)
      errDrain.start()
      val transport = new StdioTransport(bridge.getOutputStream, bridge.getInputStream)
      val channel = new Channel(transport)
      val client = new TestGrpcDc.TestServiceClient(channel)
      runInteropCases(channel, client, new TestGrpcDc.UnimplementedServiceClient(channel))
      runCompressionCases(client)
      runOrcaCases(channel, client)
    } finally {
      bridge.destroyForcibly()
    }
  } finally {
    server.destroyForcibly()
  }
  println("TestInteropOracle OK")
}
