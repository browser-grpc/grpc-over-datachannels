package tests

import echo.{DynamicEchoService, StdioTransport}
import grpcdc.{Channel, Dynamic, MemoryTransport, Server}
import java.io.File
import java.util.concurrent.TimeUnit

private def loadModel(rootPath: String): Dynamic.FileModel = {
  val file = new File(rootPath, "fixtures/echo_descriptor_set.bin")
  if (!file.exists()) {
    return null
  }
  Dynamic.parseDescriptorSet(java.nio.file.Files.readAllBytes(file.toPath))
}

/**
 * Dynamic (descriptor-driven) runtime: schemas consumed as data at
 * runtime, no generated stubs. Loopback plus the official grpc-java
 * oracle in both directions (the oracle is the runtime test bed).
 */
def testDynamic(): Unit = {
  val rootPath = root()
  val model = loadModel(rootPath)
  if (model == null) {
    println("TestDynamic SKIP (descriptor fixture missing)")
    return
  }

  // Generic codec + unknown-field retention round trip.
  val requestType = model.message(".echo.EchoRequest")
  val payload = Array[Byte](0x0a, 0x02, 0x68, 0x69, 0x10, 0x02,
    0x98.toByte, 0x06, 0x2a, 0xa2.toByte, 0x06, 0x01, 0x78)
  val decoded = Dynamic.decodeGeneric(requestType, payload, model)
  check(decoded.unknown.size == 2, s"unknown retained: ${decoded.unknown.size}")
  check(Dynamic.encodeGeneric(requestType, decoded, model).sameElements(payload), "unknown round trip")

  // Loopback: dynamic client against dynamic server.
  val (a, b) = MemoryTransport.pair()
  val loopbackServer = new Server()
  Dynamic.registerDynamicService(loopbackServer, model, "echo.Echo", new DynamicEchoService())
  loopbackServer.serveTransport(b)
  runDynamicScenarios(new Dynamic.DynamicClient(new Channel(a), model), model)

  val cp = javaClasspath(rootPath)
  if (cp == null) {
    println("TestDynamic OK (loopback; oracle skipped)")
    return
  }

  // Direction A: dynamic client -> bridge -> official server.
  val port = freePort()
  val server = new ProcessBuilder("java", "-cp", cp, "dc.oracle.OracleServer", port.toString)
    .redirectOutput(ProcessBuilder.Redirect.PIPE)
    .start()
  try {
    if (!waitReady(bufferedReader(server), "READY")) {
      println("TestDynamic SKIP (oracle server did not start)")
      return
    }
    val bridge = new ProcessBuilder("node", s"$rootPath/oracle/bridge.mjs", "dc-to-http2", "--grpc", s"127.0.0.1:$port")
      .redirectInput(ProcessBuilder.Redirect.PIPE)
      .redirectOutput(ProcessBuilder.Redirect.PIPE)
      .redirectError(ProcessBuilder.Redirect.INHERIT)
      .start()
    try {
      val transport = new StdioTransport(bridge.getOutputStream, bridge.getInputStream)
      val dynClient = new Dynamic.DynamicClient(new Channel(transport), model)
      runDynamicScenarios(dynClient, model)
    } finally {
      kill(bridge)
    }
  } finally {
    kill(server)
  }

  // Direction B: official client -> bridge -> dynamic Scala server.
  val scalaHome = sys.env.getOrElse("SCALA3_HOME", "/usr/local/scala3")
  val serverJar = s"$rootPath/scala/build/dynamic_echo_server_stdio.jar"
  if (!new File(serverJar).exists()) {
    println("TestDynamic OK (loopback + direction A; dynamic server jar missing)")
    return
  }
  val serverCmd = s"java -cp $serverJar:$scalaHome/lib/scala3-library_3-3.3.6.jar:$scalaHome/lib/scala-library-2.13.16.jar echo.DynamicEchoServerStdio"
  val portB = freePort()
  val bridge = new ProcessBuilder(
    "node", s"$rootPath/oracle/bridge.mjs", "http2-to-dc", "--port", portB.toString,
    "--target-cmd", serverCmd
  ).redirectError(ProcessBuilder.Redirect.PIPE).start()
  try {
    if (!waitReady(bufferedReader(bridge), "listening")) {
      println("TestDynamic SKIP (bridge did not start)")
      return
    }
    val client = new ProcessBuilder(
      "java", "-cp", cp, "dc.oracle.OracleClient", portB.toString,
      s"$rootPath/fixtures/oracle_scenarios.txt"
    ).redirectOutput(ProcessBuilder.Redirect.PIPE).redirectError(ProcessBuilder.Redirect.PIPE).start()
    val output = readAll(client.getInputStream)
    val errOutput = readAll(client.getErrorStream)
    val finished = client.waitFor(120, TimeUnit.SECONDS)
    check(finished, "oracle client timed out")
    check(client.exitValue() == 0, s"oracle client failed:\n$output$errOutput")
    check(output.contains("ORACLE CLIENT: ALL OK"), s"oracle client output:\n$output$errOutput")
    kill(client)
  } finally {
    kill(bridge)
  }
  println("TestDynamic OK")
}
