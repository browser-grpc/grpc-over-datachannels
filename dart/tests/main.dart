import 'dart:io';

import 'test_bdd.dart';
import 'test_codec.dart';
import 'test_dynamic.dart';
import 'test_echo.dart';
import 'test_interop.dart';
import 'test_oracle.dart';

// Test runner: ./tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic>
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd>');
    exit(2);
  }
  try {
    switch (args[0]) {
      case 'TestBdd':
        await testBdd();
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
      case 'TestDynamic':
        await testDynamic();
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
