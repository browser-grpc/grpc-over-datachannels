package tests

import echo.StdioTransport
import grpc.testing.{EchoStatus, Empty, Payload, ResponseParameters, SimpleRequest, StreamingInputCallRequest, StreamingOutputCallRequest, TestGrpcDc}
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

private def runInteropCases(
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
      runInteropCases(new TestGrpcDc.TestServiceClient(channel), new TestGrpcDc.UnimplementedServiceClient(channel))
    } finally {
      bridge.destroyForcibly()
    }
  } finally {
    server.destroyForcibly()
  }
  println("TestInteropOracle OK")
}
