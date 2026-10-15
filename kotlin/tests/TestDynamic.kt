package tests

import echo.DynamicEchoService
import echo.StdioTransport
import grpcdc.Channel
import grpcdc.Dynamic
import grpcdc.MemoryTransport
import grpcdc.Server
import java.io.File
import java.util.concurrent.TimeUnit

private fun loadModel(root: String): Dynamic.FileModel? {
    val file = File(root, "fixtures/echo_descriptor_set.bin")
    if (!file.exists()) {
        return null
    }
    return Dynamic.parseDescriptorSet(file.readBytes())
}

/**
 * Dynamic (descriptor-driven) runtime: schemas consumed as data at
 * runtime, no generated stubs. Loopback plus the official grpc-java
 * oracle in both directions (the oracle is the runtime test bed).
 */
fun testDynamic() {
    val root = root()
    val model = loadModel(root)
    if (model == null) {
        println("TestDynamic SKIP (descriptor fixture missing)")
        return
    }

    // Generic codec + unknown-field retention round trip.
    val requestType = model.message(".echo.EchoRequest")
    val payload = byteArrayOf(0x0a, 0x02, 0x68, 0x69, 0x10, 0x02,
        0x98.toByte(), 0x06, 0x2a, 0xa2.toByte(), 0x06, 0x01, 0x78)
    val decoded = Dynamic.decodeGeneric(requestType, payload, model)
    check(decoded.unknown.size == 2, "unknown retained: ${decoded.unknown.size}")
    check(Dynamic.encodeGeneric(requestType, decoded, model).contentEquals(payload), "unknown round trip")

    // Loopback: dynamic client against dynamic server.
    val (a, b) = MemoryTransport.pair()
    val loopbackServer = Server()
    Dynamic.registerDynamicService(loopbackServer, model, "echo.Echo", DynamicEchoService())
    loopbackServer.serveTransport(b)
    runDynamicScenarios(Dynamic.DynamicClient(Channel(a), model), model)

    val cp = javaClasspath(root)
    if (cp == null) {
        println("TestDynamic OK (loopback; oracle skipped)")
        return
    }

    // Direction A: dynamic client -> bridge -> official server.
    val port = freePort()
    val server = ProcessBuilder("java", "-cp", cp, "dc.oracle.OracleServer", port.toString())
        .redirectOutput(ProcessBuilder.Redirect.PIPE)
        .start()
    try {
        if (!waitReady(bufferedReader(server), "READY")) {
            println("TestDynamic SKIP (oracle server did not start)")
            return
        }
        val bridge = ProcessBuilder("node", "$root/oracle/bridge.mjs", "dc-to-http2", "--grpc", "127.0.0.1:$port")
            .redirectInput(ProcessBuilder.Redirect.PIPE)
            .redirectOutput(ProcessBuilder.Redirect.PIPE)
            .redirectError(ProcessBuilder.Redirect.INHERIT)
            .start()
        try {
            val transport = StdioTransport(bridge.outputStream, bridge.inputStream)
            runDynamicScenarios(Dynamic.DynamicClient(Channel(transport), model), model)
        } finally {
            kill(bridge)
        }
    } finally {
        kill(server)
    }

    // Direction B: official client -> bridge -> dynamic server.
    val serverCmd = "java -jar $root/kotlin/build/dynamic_echo_server_stdio.jar"
    if (!File(serverCmd.substringAfter("java -jar ")).exists()) {
        println("TestDynamic SKIP (kotlin dynamic server not built)")
        return
    }
    val portB = freePort()
    val bridge = ProcessBuilder(
        "node", "$root/oracle/bridge.mjs", "http2-to-dc", "--port", portB.toString(),
        "--target-cmd", serverCmd
    ).redirectError(ProcessBuilder.Redirect.PIPE).start()
    try {
        if (!waitReady(bufferedReader(bridge), "listening")) {
            println("TestDynamic SKIP (bridge did not start)")
            return
        }
        val client = ProcessBuilder(
            "java", "-cp", cp, "dc.oracle.OracleClient", portB.toString(),
            "$root/fixtures/oracle_scenarios.txt"
        ).redirectOutput(ProcessBuilder.Redirect.PIPE).redirectError(ProcessBuilder.Redirect.PIPE).start()
        val output = readAll(client.inputStream)
        val errOutput = readAll(client.errorStream)
        val finished = client.waitFor(120, TimeUnit.SECONDS)
        check(finished, "oracle client timed out")
        check(client.exitValue() == 0, "oracle client failed:\n$output$errOutput")
        check(output.contains("ORACLE CLIENT: ALL OK"), "oracle client output:\n$output$errOutput")
        kill(client)
    } finally {
        kill(bridge)
    }
    println("TestDynamic OK")
}
