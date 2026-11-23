package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.EchoServiceImpl
import grpcdc.Channel
import grpcdc.MemoryTransport
import grpcdc.Server
import grpcdc.StatusException
import grpcdc.Wire
import java.io.EOFException
import java.util.ArrayList

private fun setupStruct(clientStruct: Boolean, serverStruct: Boolean): EchoGrpcDc.EchoClient {
    val (a, b) = MemoryTransport.pair()
    val server = Server()
    server.setStructCodec(serverStruct)
    EchoGrpcDc.registerEchoServer(server, EchoServiceImpl())
    server.serveTransport(b)
    val channel = Channel(a)
    channel.setStructCodec(clientStruct)
    return EchoGrpcDc.EchoClient(channel)
}

/** Struct-codec negotiation: struct<->struct roundtrip, mismatch rejected, plain still works. */
fun testStructCodec() {
    val client = setupStruct(true, true)

    val unary = client.Unary(EchoRequest("hello", 0))
    check(unary.message == "echo: hello", "struct unary: $unary")

    val stream = client.ServerStream(EchoRequest("tick", 3))
    var n = 0
    while (true) {
        try {
            stream.recv()
        } catch (e: EOFException) {
            break
        }
        n++
    }
    check(n == 3, "struct server-stream count: $n")

    val joined = client.ClientStream(listOf(EchoRequest("a", 0), EchoRequest("b", 0)))
    check(joined.message == "a+b", "struct client-stream: $joined")

    val bidi = client.Bidi(listOf(EchoRequest("x", 0), EchoRequest("y", 0)))
    val echoed = ArrayList<String>()
    while (true) {
        try {
            echoed.add(bidi.recv().message)
        } catch (e: EOFException) {
            break
        }
    }
    check(echoed == listOf("x", "y"), "struct bidi: $echoed")

    val structBytes = EchoRequest("hello", 0).marshalStruct()
    check(structBytes.size > 4
            && structBytes[0] == 'D'.code.toByte() && structBytes[1] == 'C'.code.toByte()
            && structBytes[2] == 'S'.code.toByte() && structBytes[3] == '1'.code.toByte(),
        "struct magic missing")
    val back = EchoRequest()
    back.unmarshalStruct(structBytes)
    check(back.message == "hello", "struct roundtrip: ${back.message}")

    val mismatch = setupStruct(true, false)
    try {
        mismatch.Unary(EchoRequest("hello", 0))
        check(false, "struct client vs plain server should fail")
    } catch (e: StatusException) {
        check(e.code == Wire.CODE_UNIMPLEMENTED, "mismatch status: $e")
    }

    val plain = setupStruct(false, true)
    val plainResp = plain.Unary(EchoRequest("hello", 0))
    check(plainResp.message == "echo: hello", "plain vs struct server: $plainResp")

    println("TestStructCodec OK")
}
