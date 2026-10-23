package tests

import java.nio.file.{Files, Path}

/// BDD schema scenarios: golden protoc bytes, generated classes.
/// The case table (BddSchemas.cases, generated from
/// the schema scenarios) carries protoc's own --encode output
/// over webapp/testdata/{kitchen,features}.proto. Each case
/// decodes with the generated classes and re-encodes
/// byte-identically. The generated-classes harness mirrors
/// TestPbMessages.
def testBddSchemas(): Unit = {
  val rootPath = root()
  val tmp = Path.of("/tmp/grpcdc-scala-schemas")
  val gen = tmp.resolve("gen")
  run(List("rm", "-rf", tmp.toString))
  Files.createDirectories(gen)
  run(List(
    "protoc",
    s"--plugin=protoc-gen-grpc-dc-scala=$rootPath/bin/protoc-gen-grpc-dc-scala",
    s"--grpc-dc-scala_out=$gen",
    "-I", s"$rootPath/webapp/testdata", "common.proto", "kitchen.proto", "features.proto"))
  Files.deleteIfExists(gen.resolve("CommonGrpcDc.scala"))
  Files.deleteIfExists(gen.resolve("KitchenGrpcDc.scala"))
  Files.deleteIfExists(gen.resolve("FeaturesGrpcDc.scala"))

  val rows = BddSchemas.cases.map { c =>
    s"""    Array("${c.name}", "${c.message}", "${c.input}", "${c.expect}"),"""
  }.mkString("\n")

  val harnessSource =
    s"""import kitchen.v1.Kitchen
       |import feat.v1.Outer
       |
       |object Harness {
       |  def unhex(s: String): Array[Byte] = {
       |    val out = new Array[Byte](s.length / 2)
       |    var i = 0
       |    while (i < out.length) {
       |      out(i) = Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16).toByte
       |      i += 1
       |    }
       |    out
       |  }
       |
       |  def main(args: Array[String]): Unit = {
       |    val cases = Array(
       |$rows
       |    )
       |    for (c <- cases) {
       |      val input = unhex(c(2))
       |      val got: Array[Byte] = c(1) match {
       |        case "kitchen" =>
       |          val m = new Kitchen()
       |          m.unmarshalDc(input)
       |          m.marshalDc()
       |        case "outer" =>
       |          val m = new Outer()
       |          m.unmarshalDc(input)
       |          m.marshalDc()
       |        case other =>
       |          System.err.println("FAIL: unknown message " + other)
       |          System.exit(1)
       |          new Array[Byte](0)
       |      }
       |      val hex = got.map(b => "%02x".format(b & 0xFF)).mkString
       |      if (hex != c(3)) {
       |        System.err.println("FAIL: re-encode mismatch: " + c(0))
       |        System.exit(1)
       |      }
       |    }
       |    println("schemas OK")
       |  }
       |}
       |""".stripMargin

  Files.writeString(gen.resolve("Harness.scala"), harnessSource)
  val classes = tmp.resolve("classes")
  Files.createDirectories(classes)
  run(List(
    "scalac", "-d", classes.toString,
    gen.resolve("CommonMessages.scala").toString,
    gen.resolve("KitchenMessages.scala").toString,
    gen.resolve("FeaturesMessages.scala").toString,
    gen.resolve("Harness.scala").toString,
    s"$rootPath/scala/grpcdc/Transport.scala"))
  val out = capture(List("scala", "-cp", classes.toString, "Harness"))
  check(out.contains("schemas OK"), s"schemas: $out")
  println("TestBddSchemas OK")
}
