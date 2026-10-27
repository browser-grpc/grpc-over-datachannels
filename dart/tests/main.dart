import 'dart:io';

import 'test_bdd.dart';
import 'test_bdd_schemas.dart';
import 'test_deadline.dart';
import 'test_codec.dart';
import 'test_dynamic.dart';
import 'test_echo.dart';
import 'test_http2_oracle.dart';
import 'test_interop.dart';
import 'test_interop_server_oracle.dart';
import 'test_interop_oracle.dart';
import 'test_oracle.dart';
import 'test_pb_messages.dart';
import 'test_sidecar.dart';

// Test runner: ./tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic>
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestDeadline>');
    exit(2);
  }
  try {
    switch (args[0]) {
      case 'TestBdd':
        await testBdd();
        break;
      case 'TestBddSchemas':
        await testBddSchemas();
        break;
      case 'TestCodec':
        await testCodec();
        break;
      case 'TestEcho':
        await testEcho();
        break;
      case 'TestInterop':
        await testInterop();
        break;
      case 'TestOracle':
        await testOracle();
        break;
      case 'TestInteropOracle':
        await testInteropOracle();
        break;
      case 'TestHttp2Oracle':
        await testHttp2Oracle();
        break;
      case 'TestInteropServerOracle':
        await testInteropServerOracle();
        break;
      case 'TestDynamic':
        await testDynamic();
        break;
      case 'TestDeadline':
        await testDeadline();
        break;
      case 'TestPbMessages':
        await testPbMessages();
        break;
      case 'TestSidecar':
        await testSidecar();
        break;
      default:
        stderr.writeln('unknown test: ${args[0]}');
        exit(2);
    }
  } catch (e, stack) {
    stderr.writeln('$e\n$stack');
    exit(1);
  }
  exit(0);
}
