import 'dart:io';
import 'dart:typed_data';

import 'test_util.dart';

/// Generated Dart message types (<base>_messages.dart) from the
/// native protoc-gen-grpc-dc-dart plugin: kitchen-sink round-trip
/// plus a protoc oracle — protoc's own --encode bytes must decode
/// to the same message and re-encode semantically identically.
Future<void> testPbMessages() async {
  const kitchenText = '''
d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
blob: "\\x01\\x02\\x03" color: GREEN
nested { note: "n" level: 3 }
item { sku: "abc" quantity: 2 }
nums: [1, -2, 300] words: ["a", "", "bc"]
manys { note: "m" level: 1 }
vals: [0.5, -1.25]
counts { key: "x" value: 1 } counts { key: "y" value: -2 }
by_id { key: 7 value { note: "z" level: 9 } }
text: "chosen" big_negative: -9007199254740993 neg32: -123456
''';

  const harness = r'''
import 'dart:io';
import 'dart:typed_data';
import 'kitchen_messages.dart';
import 'common_messages.dart';

void fail(String msg) {
  stderr.writeln('FAIL: $msg');
  exit(1);
}

Kitchen make() {
  final k = Kitchen();
  k.d = 1.5; k.f = 2.5; k.i32 = -3; k.i64 = -4; k.u32 = 5; k.u64 = 6;
  k.s32 = -7; k.s64 = -8; k.f32 = 9; k.f64 = 10; k.sf32 = -11; k.sf64 = -12;
  k.flag = true; k.name = 'sink'; k.blob = Uint8List.fromList([1, 2, 3]);
  k.color = Color.GREEN;
  final nested = Nested(); nested.note = 'n'; nested.level = 3;
  k.nested = nested;
  final item = Item(); item.sku = 'abc'; item.quantity = 2;
  k.item = item;
  k.nums = [1, -2, 300];
  k.words = ['a', '', 'bc'];
  final m = Nested(); m.note = 'm'; m.level = 1;
  k.manys = [m];
  k.vals = [0.5, -1.25];
  k.counts = {'x': 1, 'y': -2};
  final z = Nested(); z.note = 'z'; z.level = 9;
  k.byId = {7: z};
  k.text = 'chosen'; k.bigNegative = -9007199254740993; k.neg32 = -123456;
  return k;
}

void checkSame(Kitchen a, Kitchen b) {
  final ok = a.d == b.d && a.f == b.f && a.i32 == b.i32 && a.i64 == b.i64
      && a.u32 == b.u32 && a.u64 == b.u64 && a.s32 == b.s32 && a.s64 == b.s64
      && a.f32 == b.f32 && a.f64 == b.f64 && a.sf32 == b.sf32 && a.sf64 == b.sf64
      && a.flag == b.flag && a.name == b.name && a.blob.toString() == b.blob.toString()
      && a.color == b.color
      && a.nested?.note == b.nested?.note && a.nested?.level == b.nested?.level
      && a.item?.sku == b.item?.sku && a.item?.quantity == b.item?.quantity
      && a.nums.toString() == b.nums.toString() && a.words.toString() == b.words.toString()
      && a.manys.length == b.manys.length && a.manys[0].note == b.manys[0].note
      && a.vals.toString() == b.vals.toString() && a.counts.toString() == b.counts.toString()
      && a.byId[7]?.note == b.byId[7]?.note
      && a.text == b.text && a.bigNegative == b.bigNegative && a.neg32 == b.neg32;
  if (!ok) fail('mismatch');
}

Future<void> main(List<String> args) async {
  final k = make();
  if (args[0] == 'roundtrip') {
    final back = Kitchen();
    back.unmarshalDc(k.marshalDc());
    checkSame(back, k);
    if (Kitchen().marshalDc().isNotEmpty) fail('empty must encode empty');
    final both = Kitchen();
    both.text = 'a'; both.code = 7;
    final bothBack = Kitchen();
    bothBack.unmarshalDc(both.marshalDc());
    if (bothBack.text != '' || bothBack.code != 7) fail('oneof encode clearing');
    print('roundtrip OK');
    return;
  }
  final bytes = await File(args[1]).readAsBytes();
  final from = Kitchen();
  from.unmarshalDc(bytes);
  checkSame(from, k);
  final again = Kitchen();
  again.unmarshalDc(from.marshalDc());
  checkSame(again, from);
  print('oracle OK');
}
''';

  Future<String> run(List<String> cmd, String cwd, {String? stdinText}) async {
    final proc = await Process.start(cmd[0], cmd.sublist(1), workingDirectory: cwd);
    if (stdinText != null) {
      proc.stdin.write(stdinText);
      await proc.stdin.close();
    } else {
      await proc.stdin.close();
    }
    final out = await proc.stdout
        .transform(const SystemEncoding().decoder)
        .join()
        .timeout(const Duration(minutes: 5));
    final err = await proc.stderr
        .transform(const SystemEncoding().decoder)
        .join()
        .timeout(const Duration(minutes: 5));
    final code = await proc.exitCode;
    check(code == 0 && !out.contains('FAIL'), 'command failed $cmd: $out $err');
    return out;
  }

  var root = '..';
  if (!File('$root/webapp/testdata/kitchen.proto').existsSync()) {
    root = '.';
  }
  final rootAbs = File('$root/webapp/testdata/kitchen.proto').absolute.parent.parent.parent.path;
  final testdata = '$rootAbs/webapp/testdata';
  final tmp = await Directory.systemTemp.createTemp('grpcdc-dart-pb-');
  final gen = Directory('${tmp.path}/gen');
  await gen.create();
  await run([
    'protoc',
    '--plugin=protoc-gen-grpc-dc-dart=$rootAbs/bin/protoc-gen-grpc-dc-dart',
    '--grpc-dc-dart_out=${gen.path}',
    '-I', testdata, 'common.proto', 'kitchen.proto',
  ], testdata);
  await File('${gen.path}/common_grpc_dc.dart').delete();
  await File('${gen.path}/kitchen_grpc_dc.dart').delete();
  await File('${gen.path}/main.dart').writeAsString(harness);
  // Generated support classes import ../grpcdc/transport.dart.
  await Directory('${tmp.path}/grpcdc').create();
  await File('$rootAbs/dart/grpcdc/transport.dart')
      .copy('${tmp.path}/grpcdc/transport.dart');
  final app = Directory('${tmp.path}/app');
  await app.create();
  await File('${gen.path}/common_messages.dart').rename('${app.path}/common_messages.dart');
  await File('${gen.path}/kitchen_messages.dart').rename('${app.path}/kitchen_messages.dart');
  await File('${gen.path}/main.dart').rename('${app.path}/main.dart');
  final appPath = app.path;
  final out1 = await run(['dart', 'main.dart', 'roundtrip'], appPath);
  check(out1.contains('roundtrip OK'), 'roundtrip: $out1');
  final bin = '${tmp.path}/protoc.bin';
  await File('${tmp.path}/kitchen.txt').writeAsString(kitchenText);
  await run([
    'bash', '-c',
    'protoc --encode=kitchen.v1.Kitchen -I $testdata kitchen.proto < ${tmp.path}/kitchen.txt > $bin',
  ], testdata);
  final out2 = await run(['dart', 'main.dart', 'oracle', bin], appPath);
  check(out2.contains('oracle OK'), 'oracle: $out2');
  print('TestPbMessages OK');
}
