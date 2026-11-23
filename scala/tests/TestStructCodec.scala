package tests

import echo.{EchoGrpcDc, EchoRequest, EchoServiceImpl}
import grpcdc.{Channel, MemoryTransport, Server, StatusException, Wire}
import java.io.EOFException
import scala.collection.mutable.ListBuffer

private def setupStruct(clientStruct: Boolean, serverStruct: Boolean): EchoGrpcDc.EchoClient = {
  val (a, b) = MemoryTransport.pair()
  val server = new Server()
  server.setStructCodec(serverStruct)
  EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl())
  server.serveTransport(b)
  val channel = new Channel(a)
  channel.setStructCodec(clientStruct)
  new EchoGrpcDc.EchoClient(channel)
}

/** Struct-codec negotiation: struct<->struct roundtrip, mismatch rejected, plain still works. */
def testStructCodec(): Unit = {
  val client = setupStruct(true, true)

  val unary = client.Unary(EchoRequest("hello", 0))
  check(unary.message == "echo: hello", s"struct unary: $unary")

  val stream = client.ServerStream(EchoRequest("tick", 3))
  var n = 0
  var done = false
  while (!done) {
    try {
      stream.recv()
      n += 1
    } catch {
      case e: EOFException => done = true
    }
  }
  check(n == 3, s"struct server-stream count: $n")

  val joined = client.ClientStream(List(EchoRequest("a", 0), EchoRequest("b", 0)))
  check(joined.message == "a+b", s"struct client-stream: $joined")

  val bidi = client.Bidi(List(EchoRequest("x", 0), EchoRequest("y", 0)))
  val echoed = ListBuffer[String]()
  done = false
  while (!done) {
    try {
      echoed += bidi.recv().message
    } catch {
      case e: EOFException => done = true
    }
  }
  check(echoed.toList == List("x", "y"), s"struct bidi: $echoed")

  val structBytes = EchoRequest("hello", 0).marshalStruct()
  check(structBytes.length > 4
      && structBytes(0) == 'D'.toByte && structBytes(1) == 'C'.toByte
      && structBytes(2) == 'S'.toByte && structBytes(3) == '1'.toByte,
    "struct magic missing")
  val back = new EchoRequest()
  back.unmarshalStruct(structBytes)
  check(back.message == "hello", s"struct roundtrip: ${back.message}")

  val mismatch = setupStruct(true, false)
  try {
    mismatch.Unary(EchoRequest("hello", 0))
    check(false, "struct client vs plain server should fail")
  } catch {
    case e: StatusException =>
      check(e.code == Wire.CODE_UNIMPLEMENTED, s"mismatch status: $e")
  }

  val plain = setupStruct(false, true)
  val plainResp = plain.Unary(EchoRequest("hello", 0))
  check(plainResp.message == "echo: hello", s"plain vs struct server: $plainResp")

  println("TestStructCodec OK")
}
