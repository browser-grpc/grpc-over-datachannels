import 'dart:convert';
import 'dart:io';

import 'bdd_schemas.dart';
import 'test_util.dart';

/// BDD schema scenarios: golden protoc bytes, generated classes.
/// The case table (bdd_schemas.dart) is generated from
/// the schema scenarios: protoc's own --encode output over
/// webapp/testdata/{kitchen,features}.proto. Each case decodes
/// with the generated classes and re-encodes byte-identically.
/// The generated-classes harness mirrors test_pb_messages.dart.

Future<String> run(List<String> cmd, String cwd) async {
  final proc = await Process.start(cmd[0], cmd.sublist(1),
      workingDirectory: cwd);
  await proc.stdin.close();
  final out = await proc.stdout.transform(const SystemEncoding().decoder).join();
  final err = await proc.stderr.transform(const SystemEncoding().decoder).join();
  final code = await proc.exitCode;
  if (code != 0) {
    throw StateError('command failed ($code): ${cmd.join(" ")}\n$err');
  }
  return out;
}

Future<void> testBddSchemas() async {
  final root = Directory.current.path.endsWith('/dart')
      ? Directory.current.parent.path
      : Directory.current.path;
  final rootAbs = File('$root/webapp/testdata/kitchen.proto')
      .absolute
      .parent
      .parent
      .parent
      .path;
  final testdata = '$rootAbs/webapp/testdata';
  final tmp = await Directory.systemTemp.createTemp('grpcdc-dart-schemas-');
  final gen = Directory('${tmp.path}/gen');
  await gen.create();
  await run([
    'protoc',
    '--plugin=protoc-gen-grpc-dc-dart=$rootAbs/bin/protoc-gen-grpc-dc-dart',
    '--grpc-dc-dart_out=${gen.path}',
    '-I',
    testdata,
    'common.proto',
    'kitchen.proto',
    'features.proto',
  ], testdata);
  for (final stub in [
    'common_grpc_dc.dart',
    'kitchen_grpc_dc.dart',
    'features_grpc_dc.dart'
  ]) {
    await File('${gen.path}/$stub').delete();
  }

  final caseRows = bddSchemas
      .map((c) =>
          "  BddSchema('${c.name}', '${c.message}', '${c.input}', '${c.expect}'),")
      .join('\n');
  final harness = '''
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'kitchen_messages.dart';
import 'features_messages.dart';

class BddSchema {
  final String name;
  final String message;
  final String input;
  final String expect;
  const BddSchema(this.name, this.message, this.input, this.expect);
}

const cases = <BddSchema>[
$caseRows
];

Uint8List unhex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  for (final c in cases) {
    final input = unhex(c.input);
    late List<int> got;
    if (c.message == 'kitchen') {
      final m = Kitchen();
      m.unmarshalDc(input);
      got = m.marshalDc();
    } else if (c.message == 'outer') {
      final m = Outer();
      m.unmarshalDc(input);
      got = m.marshalDc();
    } else {
      stderr.writeln('FAIL: \${c.name}: unknown message \${c.message}');
      exit(1);
    }
    if (hex(got) != c.expect) {
      stderr.writeln('FAIL: \${c.name}: re-encode mismatch');
      exit(1);
    }
  }
  print('schemas OK');
}
''';

  await File('${gen.path}/main.dart').writeAsString(harness);
  await Directory('${tmp.path}/grpcdc').create();
  await File('$rootAbs/dart/grpcdc/transport.dart')
      .copy('${tmp.path}/grpcdc/transport.dart');
  final app = Directory('${tmp.path}/app');
  await app.create();
  for (final f in [
    'common_messages.dart',
    'kitchen_messages.dart',
    'features_messages.dart',
    'main.dart'
  ]) {
    await File('${gen.path}/$f').rename('${app.path}/$f');
  }
  final out = await run(['dart', 'main.dart'], app.path);
  check(out.contains('schemas OK'), 'schemas harness: $out');
  print('TestBddSchemas OK');
}
