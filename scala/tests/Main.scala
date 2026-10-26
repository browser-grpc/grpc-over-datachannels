package tests

// Test runner: java -cp tests.jar:scala-library.jar tests.Main <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestDeadline|TestPbMessages>
object Main {
  def main(args: Array[String]): Unit = {
    if (args.isEmpty) {
      System.err.println("usage: tests.Main <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestDeadline|TestPbMessages>")
      System.exit(2)
    }
    try {
      args(0) match {
        case "TestCodec" => testCodec()
        case "TestEcho" => testEcho()
        case "TestInterop" => testInterop()
        case "TestOracle" => testOracle()
        case "TestDynamic" => testDynamic()
        case "TestBdd" => testBdd()
        case "TestDeadline" => testDeadline()
        case "TestPbMessages" => testPbMessages()
        case "TestBddSchemas" => testBddSchemas()
        case "TestSidecar" => testSidecar()
        case "TestInteropOracle" => testInteropOracle()
        case other =>
          System.err.println(s"unknown test: $other")
          System.exit(2)
      }
    } catch {
      case e: Throwable =>
        e.printStackTrace()
        System.exit(1)
    }
  }
}
