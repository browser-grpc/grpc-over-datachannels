package tests

import java.io.File
import java.nio.file.{Files, Path}

/** Generated Scala message types (<Base>Messages.scala) from the
  * native protoc-gen-grpc-dc-scala plugin: kitchen-sink round-trip
  * plus a protoc oracle — protoc's own --encode bytes must decode
  * to the same message and re-encode semantically identically.
  */
def testPbMessages(): Unit = {
  val rootPath = root()
  val tmp = Path.of("/tmp/grpcdc-scala-pb")
  val gen = tmp.resolve("gen")
  run(List("rm", "-rf", tmp.toString))
  Files.createDirectories(gen)
  run(List(
    "protoc",
    s"--plugin=protoc-gen-grpc-dc-scala=$rootPath/bin/protoc-gen-grpc-dc-scala",
    s"--grpc-dc-scala_out=$gen",
    "-I", s"$rootPath/webapp/testdata", "common.proto", "kitchen.proto"))
  Files.deleteIfExists(gen.resolve("CommonGrpcDc.scala"))
  Files.deleteIfExists(gen.resolve("KitchenGrpcDc.scala"))
  Files.writeString(gen.resolve("Harness.scala"), harnessSource)
  val classes = tmp.resolve("classes")
  Files.createDirectories(classes)
  run(List(
    "scalac", "-d", classes.toString,
    gen.resolve("CommonMessages.scala").toString,
    gen.resolve("KitchenMessages.scala").toString,
    gen.resolve("Harness.scala").toString,
    s"$rootPath/scala/grpcdc/Transport.scala"))
  val out1 = capture(List("scala", "-cp", classes.toString, "Harness", "roundtrip"))
  check(out1.contains("roundtrip OK"), s"roundtrip: $out1")
  Files.writeString(tmp.resolve("kitchen.txt"), kitchenText)
  runShell(
    s"protoc --encode=kitchen.v1.Kitchen -I $rootPath/webapp/testdata kitchen.proto < $tmp/kitchen.txt > $tmp/protoc.bin")
  val out2 = capture(List("scala", "-cp", classes.toString, "Harness", "oracle", tmp.resolve("protoc.bin").toString))
  check(out2.contains("oracle OK"), s"oracle: $out2")
  println("TestPbMessages OK")
}

private def pbRun(pb: ProcessBuilder): Int = {
  pb.inheritIO()
  val proc = pb.start()
  proc.waitFor()
}

private def run(argv: List[String]): Unit = {
  check(pbRun(new ProcessBuilder(argv: _*)) == 0, s"command failed: ${argv.mkString(" ")}")
}

private def runShell(cmd: String): Unit = {
  check(pbRun(new ProcessBuilder("bash", "-c", cmd)) == 0, s"command failed: $cmd")
}

private def capture(argv: List[String]): String = {
  val pb = new ProcessBuilder(argv: _*)
  pb.redirectErrorStream(true)
  val proc = pb.start()
  val out = new String(proc.getInputStream.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8)
  check(proc.waitFor() == 0, s"capture failed: ${argv.mkString(" ")} -> $out")
  out
}

private val kitchenText: String =
  """d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
    |f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
    |blob: "\x01\x02\x03" color: GREEN
    |nested { note: "n" level: 3 }
    |item { sku: "abc" quantity: 2 }
    |nums: [1, -2, 300] words: ["a", "", "bc"]
    |manys { note: "m" level: 1 }
    |vals: [0.5, -1.25]
    |counts { key: "x" value: 1 } counts { key: "y" value: -2 }
    |by_id { key: 7 value { note: "z" level: 9 } }
    |text: "chosen" big_negative: -9007199254740993 neg32: -123456
    |""".stripMargin

private val harnessSource: String =
  """import kitchen.v1.{Kitchen, Nested, Color}
    |import shop.common.Item
    |
    |object Harness {
    |  def fail(msg: String): Nothing = {
    |    System.err.println(s"FAIL: $msg")
    |    System.exit(1)
    |    throw new AssertionError(msg)
    |  }
    |
    |  def make(): Kitchen = {
    |    val k = new Kitchen()
    |    k.d = 1.5; k.f = 2.5f; k.i32 = -3; k.i64 = -4L; k.u32 = 5; k.u64 = 6L
    |    k.s32 = -7; k.s64 = -8L; k.f32 = 9; k.f64 = 10L; k.sf32 = -11; k.sf64 = -12L
    |    k.flag = true; k.name = "sink"; k.blob = Array[Byte](1, 2, 3); k.color = Color.GREEN
    |    val nested = new Nested(); nested.note = "n"; nested.level = 3
    |    val item = new Item(); item.sku = "abc"; item.quantity = 2
    |    k.nested = nested; k.item = item
    |    k.nums = List(1, -2, 300); k.words = List("a", "", "bc")
    |    val m = new Nested(); m.note = "m"; m.level = 1
    |    k.manys = List(m); k.vals = List(0.5, -1.25)
    |    k.counts = Map("x" -> 1, "y" -> -2)
    |    val z = new Nested(); z.note = "z"; z.level = 9
    |    k.byId = Map(7L -> z)
    |    k.text = "chosen"; k.bigNegative = -9007199254740993L; k.neg32 = -123456
    |    k
    |  }
    |
    |  def checkSame(a: Kitchen, b: Kitchen): Unit = {
    |    val ok = a.d == b.d && a.f == b.f && a.i32 == b.i32 && a.i64 == b.i64
    |      && a.u32 == b.u32 && a.u64 == b.u64 && a.s32 == b.s32 && a.s64 == b.s64
    |      && a.f32 == b.f32 && a.f64 == b.f64 && a.sf32 == b.sf32 && a.sf64 == b.sf64
    |      && a.flag == b.flag && a.name == b.name && a.blob.sameElements(b.blob)
    |      && a.color == b.color
    |      && a.nested.note == b.nested.note && a.nested.level == b.nested.level
    |      && a.item.sku == b.item.sku && a.item.quantity == b.item.quantity
    |      && a.nums == b.nums && a.words == b.words
    |      && a.manys.length == 1 && a.manys.head.note == b.manys.head.note
    |      && a.vals == b.vals && a.counts == b.counts
    |      && a.byId(7L).note == b.byId(7L).note && a.byId(7L).level == b.byId(7L).level
    |      && a.text == b.text && a.bigNegative == b.bigNegative && a.neg32 == b.neg32
    |    if (!ok) fail("mismatch")
    |  }
    |
    |  def main(args: Array[String]): Unit = {
    |    val k = make()
    |    if (args(0) == "roundtrip") {
    |      val back = new Kitchen()
    |      back.unmarshalDc(k.marshalDc())
    |      checkSame(back, k)
    |      if (new Kitchen().marshalDc().nonEmpty) fail("empty")
    |      val both = new Kitchen()
    |      both.text = "a"; both.code = 7
    |      val bothBack = new Kitchen()
    |      bothBack.unmarshalDc(both.marshalDc())
    |      if (bothBack.text != "" || bothBack.code != 7) fail("oneof encode clearing")
    |      println("roundtrip OK")
    |    } else {
    |      val from = new Kitchen()
    |      from.unmarshalDc(java.nio.file.Files.readAllBytes(java.nio.file.Path.of(args(1))))
    |      checkSame(from, k)
    |      val again = new Kitchen()
    |      again.unmarshalDc(from.marshalDc())
    |      checkSame(again, from)
    |      println("oracle OK")
    |    }
    |  }
    |}
    |""".stripMargin
