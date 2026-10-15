import 'dart:async';
import 'dart:io';

import '../examples/dynamic_echo_service.dart';
import '../examples/stdio_transport.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/dynamic.dart';
import '../grpcdc/memory_transport.dart';
import '../grpcdc/server.dart';
import 'scenario_runner.dart';
import 'test_util.dart';

FileModel? loadModel(String rootPath) {
  final file = File('$rootPath/fixtures/echo_descriptor_set.bin');
  if (!file.existsSync()) {
    return null;
  }
  return parseDescriptorSet(file.readAsBytesSync());
}

/// Dynamic (descriptor-driven) runtime: schemas consumed as data at
/// runtime, no generated stubs. Loopback plus the official grpc-java
/// oracle in both directions (the oracle is the runtime test bed).
Future<void> testDynamic() async {
  final rootPath = root();
  final model = loadModel(rootPath);
  if (model == null) {
    print('TestDynamic SKIP (descriptor fixture missing)');
    return;
  }

  // Generic codec + unknown-field retention round trip.
  final requestType = model.message('.echo.EchoRequest');
  final payload = [0x0a, 0x02, 0x68, 0x69, 0x10, 0x02, 0x98, 0x06, 0x2a, 0xa2, 0x06, 0x01, 0x78];
  final decoded = decodeGeneric(requestType, payload, model);
  check(decoded.unknown.length == 2, 'unknown retained: ${decoded.unknown.length}');
  check(toHex(encodeGeneric(requestType, decoded, model)) == toHex(payload), 'unknown round trip');

  // Loopback: dynamic client against dynamic server.
  final (a, b) = memoryTransportPair();
  final loopbackServer = Server();
  registerDynamicService(loopbackServer, model, 'echo.Echo', DynamicEchoService());
  loopbackServer.serveTransport(b);
  await runDynamicScenarios(DynamicClient(Channel(a), model), model);

  final cp = javaClasspath(rootPath);
  if (cp == null) {
    print('TestDynamic OK (loopback; oracle skipped)');
    return;
  }

  // Direction A: dynamic client -> bridge -> official server.
  final port = await freePort();
  final server = await Process.start('java', ['-cp', cp, 'dc.oracle.OracleServer', '$port']);
  try {
    if (!await waitReady(server.stderr, 'READY')) {
      print('TestDynamic SKIP (oracle server did not start)');
      return;
    }
    final bridge = await Process.start(
        'node', ['$rootPath/oracle/bridge.mjs', 'dc-to-http2', '--grpc', '127.0.0.1:$port']);
    try {
      final transport = StdioTransport(bridge.stdout, bridge.stdin.add);
      await runDynamicScenarios(DynamicClient(Channel(transport), model), model);
    } finally {
      bridge.kill(ProcessSignal.sigkill);
      await bridge.exitCode;
    }
  } finally {
    server.kill(ProcessSignal.sigkill);
    await server.exitCode;
  }

  // Direction B: official client -> bridge -> dynamic server.
  final serverBin = '$rootPath/dart/build/dynamic_echo_server_stdio';
  if (!fileExists(serverBin)) {
    print('TestDynamic SKIP (dart dynamic server not built)');
    return;
  }
  final portB = await freePort();
  final bridge = await Process.start('node', [
    '$rootPath/oracle/bridge.mjs',
    'http2-to-dc',
    '--port',
    '$portB',
    '--target-cmd',
    serverBin,
  ]);
  try {
    if (!await waitReady(bridge.stderr, 'listening')) {
      print('TestDynamic SKIP (bridge did not start)');
      return;
    }
    final client = await Process.start('java', [
      '-cp',
      cp,
      'dc.oracle.OracleClient',
      '$portB',
      '$rootPath/fixtures/oracle_scenarios.txt',
    ]);
    final output = await readAll(client.stdout);
    final errOutput = await readAll(client.stderr);
    final exitCode = await client.exitCode.timeout(const Duration(seconds: 120),
        onTimeout: () {
      client.kill(ProcessSignal.sigkill);
      return -1;
    });
    check(exitCode == 0, 'oracle client failed:\n$output$errOutput');
    check(output.contains('ORACLE CLIENT: ALL OK'), 'oracle client output:\n$output$errOutput');
  } finally {
    bridge.kill(ProcessSignal.sigkill);
    await bridge.exitCode;
  }
  print('TestDynamic OK');
}
