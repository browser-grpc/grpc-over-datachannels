package tests

import kotlin.system.exitProcess

// Test runner: java -jar tests.jar <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd>
fun main(args: Array<String>) {
    if (args.isEmpty()) {
        System.err.println("usage: tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd>")
        exitProcess(2)
    }
    try {
        when (args[0]) {
            "TestCodec" -> testCodec()
            "TestEcho" -> testEcho()
            "TestInterop" -> testInterop()
            "TestOracle" -> testOracle()
            "TestDynamic" -> testDynamic()
            "TestBdd" -> testBdd()
            else -> {
                System.err.println("unknown test: ${args[0]}")
                exitProcess(2)
            }
        }
    } catch (e: Throwable) {
        e.printStackTrace()
        exitProcess(1)
    }
}
