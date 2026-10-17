package echo

import grpcdc.{Channel, StatusException}
import java.io.{EOFException, FileDescriptor, FileInputStream}

// Interop harness: the Scala echo client over stdio. Prints one
// line per call shape to stderr (stdout carries frames) and exits
// non-zero on any failure. Mirrors go/examples/echo_client_stdio.
object EchoClientStdio {
  def main(args: Array[String]): Unit = {
    try {
      run()
    } catch {
      case e: Exception =>
        System.err.println(s"error: $e")
        System.exit(1)
    }
  }

  private def req(message: String, count: Int): EchoRequest = EchoRequest(message, count)

  private def run(): Unit = {
    val transport = new StdioTransport(System.out, new FileInputStream(FileDescriptor.in))
    val client = new EchoGrpcDc.EchoClient(new Channel(transport))

    val unary = client.Unary(req("hello", 0))
    System.err.println(s"unary=${unary.message}")

    val stream = client.ServerStream(req("tick", 3))
    val ticks = scala.collection.mutable.ListBuffer[String]()
    var done = false
    while (!done) {
      try {
        val resp = stream.recv()
        ticks += s"${resp.message}#${resp.index}"
      } catch {
        case e: EOFException => done = true
      }
    }
    System.err.println(s"server_stream=${ticks.mkString(",")}")

    val joined = client.ClientStream(List(req("a", 0), req("b", 0), req("c", 0)))
    System.err.println(s"client_stream=${joined.message}")

    val bidi = client.Bidi(List(req("x", 0), req("y", 0)))
    val echoed = scala.collection.mutable.ListBuffer[String]()
    done = false
    while (!done) {
      try {
        echoed += bidi.recv().message
      } catch {
        case e: EOFException => done = true
      }
    }
    System.err.println(s"bidi=${echoed.mkString(",")}")

    val mdResp = client.Unary(req("hello", 0), Map("x-echo" -> "meta"))
    System.err.println(s"metadata=${mdResp.message}")

    try {
      client.Unary(EchoRequest("slow", 0, 400), null, java.time.Duration.ofMillis(50))
      System.err.println("deadline=no error")
    } catch {
      case e: StatusException => System.err.println(s"deadline=${e.code}")
    }

    try {
      client.Unary(req("fail", 0))
      System.err.println("error_case=no error")
      System.exit(1)
    } catch {
      case e: StatusException => System.err.println(s"error_case=$e")
    }
  }
}
