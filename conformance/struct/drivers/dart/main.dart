import 'dart:io';
import 'dart:typed_data';

import 'msgs_messages.dart';
import 'OuterStruct.dart';
import 'InnerStruct.dart';

String hexOf(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main(List<String> args) {
  final goldenHex = args[0];
  final golden = Uint8List.fromList(List.generate(goldenHex.length ~/ 2,
      (i) => int.parse(goldenHex.substring(2 * i, 2 * i + 2), radix: 16)));
  final m = Outer();
  m.inner = Inner('x', -3);
  m.hue = Hue.RED;
  m.nums = [1, -2, 300];
  m.byName = {'b': Inner('second'), 'a': Inner('first', 9)};
  m.s = 'picked';
  m.blob = Uint8List.fromList([1, 2, 3]);
  m.names = ['n1', 'n2'];
  m.inners = [Inner('i1'), Inner('i2'), Inner('i3')];
  m.byId = {7: 'seven', 2: 'two'};
  m.score = 3.5;
  m.ratio = 0.25;
  m.flag = true;
  m.stamp = 123456789;
  m.delta = -77;
  final got = OuterStruct.marshal(m);
  if (hexOf(got) != goldenHex) {
    print('MARSHAL_MISMATCH\n got ${hexOf(got)}\nwant $goldenHex');
    exit(1);
  }
  final back = OuterStruct.unmarshal(golden);
  if (hexOf(OuterStruct.marshal(back)) != goldenHex) {
    print('ROUNDTRIP_MISMATCH');
    exit(1);
  }
  print('DECODE_OK');
}
