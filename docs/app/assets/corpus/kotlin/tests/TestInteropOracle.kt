package tests

import echo.StdioTransport
import grpc.testing.Empty
import grpc.testing.EchoStatus
import grpc.testing.Payload
import grpc.testing.ResponseParameters
import grpc.testing.SimpleRequest
import grpc.testing.StreamingInputCallRequest
import grpc.testing.StreamingOutputCallRequest
import grpc.testing.TestGrpcDc
import grpcdc.Channel
import grpcdc.StatusException
import java.io.BufferedReader
import java.io.EOFException
import java.io.File
import java.io.InputStreamReader
import java.net.ServerSocket
import java.util.Base64

/**
 * Interop client grading: the generated Kotlin TestService client
 * runs the canonical grpc interop cases (generated table:
 * InteropCases) against the official grpc-go TestServiceServer,
 * through the bridge (dc-to-http2, stdio = DataChannel). Mirrors
 * the Java/C#/JS/Python/Go/Rust interop oracle suites. Skips when
 * the oracle server binary is not built (Dockerfile.ci builds it).
 */

private fun interopPayload(size: Int): Payload = Payload(body = ByteArray(size))

private fun interopStreamRequest(respSizes: IntArray, payloadSize: Int): StreamingOutputCallRequest {
    val req = StreamingOutputCallRequest(payload = interopPayload(payloadSize))
    for (size in respSizes) {
        req.responseParameters.add(ResponseParameters(size = size))
    }
    return req
}

private fun expectStatus(code: Int, message: String, what: String, call: () -> Unit) {
    try {
        call()
    } catch (e: StatusException) {
        check(e.code == code, "$what: code ${e.code} != $code")
        if (message.isNotEmpty()) {
            check(e.message == message, "$what: message '${e.message}' != '$message'")
        }
        return
    }
    throw AssertionError("$what: expected status $code, call succeeded")
}

private fun runInteropCases(
    client: TestGrpcDc.TestServiceClient,
    unimpl: TestGrpcDc.UnimplementedServiceClient,
) {
    for (row in InteropCases.CASES) {
        val name = row[0] as String
        val kind = row[1] as String
        val reqSizes = row[2] as IntArray
        val respSizes = row[3] as IntArray
        val statusCode = row[4] as Int
        val statusMessage = row[5] as String
        when (kind) {
            "EMPTY" -> client.EmptyCall(Empty())
            "LARGE_UNARY" -> {
                val req = SimpleRequest(responseSize = respSizes[0], payload = interopPayload(reqSizes[0]))
                val resp = client.UnaryCall(req)
                check(resp.payload!!.body.size == respSizes[0], "$name: body ${resp.payload!!.body.size}")
            }
            "CLIENT_STREAMING" -> {
                val reqs = reqSizes.map { StreamingInputCallRequest(payload = interopPayload(it)) }
                val resp = client.StreamingInputCall(reqs)
                check(resp.aggregatedPayloadSize == reqSizes.sum(), "$name: aggregated ${resp.aggregatedPayloadSize}")
            }
            "SERVER_STREAMING" -> {
                client.StreamingOutputCall(interopStreamRequest(respSizes, 0)).use { stream ->
                    for (size in respSizes) {
                        val resp = stream.recv()
                        check(resp.payload!!.body.size == size, "$name: body ${resp.payload!!.body.size} != $size")
                    }
                    try {
                        stream.recv()
                        throw AssertionError("$name: expected EOF")
                    } catch (expected: EOFException) {
                        // end of stream
                    }
                }
            }
            "PING_PONG" -> {
                val reqs = respSizes.indices.map { interopStreamRequest(intArrayOf(respSizes[it]), reqSizes[it]) }
                client.FullDuplexCall(reqs).use { stream ->
                    for (size in respSizes) {
                        val resp = stream.recv()
                        check(resp.payload!!.body.size == size, "$name: body ${resp.payload!!.body.size} != $size")
                    }
                }
            }
            "EMPTY_STREAM" -> {
                client.FullDuplexCall(emptyList()).use { stream ->
                    try {
                        stream.recv()
                        throw AssertionError("$name: expected EOF")
                    } catch (expected: EOFException) {
                        // end of stream
                    }
                }
            }
            "CUSTOM_METADATA" -> {
                // Upstream custom_metadata, duplex leg (mirrors the Java runner).
                val trailingBin = Base64.getEncoder().encodeToString(
                    byteArrayOf(0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b))
                val md = mapOf(
                    "x-grpc-test-echo-initial" to "test_initial_metadata_value",
                    "x-grpc-test-echo-trailing-bin" to trailingBin)
                client.FullDuplexCall(listOf(interopStreamRequest(intArrayOf(1), 1)), md).use { stream ->
                    val resp = stream.recv()
                    check(resp.payload!!.body.size == 1, "$name: body")
                    try {
                        stream.recv()
                        throw AssertionError("$name: expected EOF")
                    } catch (expected: EOFException) {
                        // end of stream: trailers now readable
                    }
                    check(stream.headers()?.get("x-grpc-test-echo-initial") == "test_initial_metadata_value",
                        "$name: initial ${stream.headers()}")
                    check(stream.trailers()?.get("x-grpc-test-echo-trailing-bin") == trailingBin,
                        "$name: trailing ${stream.trailers()}")
                }
            }
            "STATUS_UNARY" -> {
                val req = SimpleRequest(responseStatus = EchoStatus(statusCode, statusMessage))
                expectStatus(statusCode, statusMessage, name) { client.UnaryCall(req) }
            }
            "STATUS_DUPLEX" -> {
                val req = interopStreamRequest(intArrayOf(0), 0)
                req.responseStatus = EchoStatus(statusCode, statusMessage)
                expectStatus(statusCode, statusMessage, name) {
                    client.FullDuplexCall(listOf(req)).use { stream -> stream.recv() }
                }
            }
            "UNIMPLEMENTED_METHOD" -> expectStatus(statusCode, "", name) { client.UnimplementedCall(Empty()) }
            "UNIMPLEMENTED_SERVICE" -> expectStatus(statusCode, "", name) { unimpl.UnimplementedCall(Empty()) }
            else -> throw AssertionError("unknown interop kind $kind")
        }
        println("interop case ok: $name")
    }
}

fun testInteropOracle() {
    val root = root()
    val serverBin = File(root, "oracle/go-interop/interop-server")
    if (!serverBin.canExecute()) {
        println("TestInteropOracle SKIP (go interop server not built)")
        return
    }
    val port = ServerSocket(0).use { it.localPort }
    val server = ProcessBuilder(serverBin.path, "-port", port.toString())
        .redirectErrorStream(true)
        .start()
    try {
        server.inputStream.bufferedReader().let { reader ->
            Thread {
                while (reader.readLine() != null) {
                    // discard
                }
            }.apply { isDaemon = true }.start()
        }
        val deadline = System.currentTimeMillis() + 30000
        var ready = false
        while (System.currentTimeMillis() < deadline) {
            try {
                java.net.Socket("127.0.0.1", port).close()
                ready = true
                break
            } catch (e: Exception) {
                Thread.sleep(100)
            }
        }
        check(ready, "go interop server did not start")

        val bridge = ProcessBuilder("node", File(root, "oracle/bridge.mjs").path,
            "dc-to-http2", "--grpc", "127.0.0.1:$port")
            .redirectErrorStream(false)
            .start()
        try {
            Thread {
                BufferedReader(InputStreamReader(bridge.errorStream)).forEachLine { }
            }.apply { isDaemon = true }.start()
            val transport = StdioTransport(bridge.outputStream, bridge.inputStream)
            val channel = Channel(transport)
            runInteropCases(TestGrpcDc.TestServiceClient(channel), TestGrpcDc.UnimplementedServiceClient(channel))
        } finally {
            bridge.destroyForcibly()
        }
    } finally {
        server.destroyForcibly()
    }
    println("TestInteropOracle OK")
}
