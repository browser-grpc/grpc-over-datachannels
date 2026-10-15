import 'dart:typed_data';

import '../grpcdc/transport.dart';
import 'pb.dart';

/// Hand-written protobuf messages for proto/echo.proto (package echo).
///
/// Deliberately minimal (two messages) so the example needs no
/// protobuf codegen dependency — the wire bytes are genuine protobuf:
/// EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
/// Mirrors go/examples/echo_pb.go.
class EchoRequest implements Marshaler, Unmarshaler {
  String message;
  int count;
  int delayMs;

  EchoRequest([this.message = '', this.count = 0, this.delayMs = 0]);

  @override
  Uint8List marshalDc() {
    final w = PbWriter();
    w.stringField(1, message);
    w.int32Field(2, count);
    w.int32Field(3, delayMs);
    return w.toBytes();
  }

  @override
  void unmarshalDc(List<int> data) {
    message = '';
    count = 0;
    delayMs = 0;
    final r = PbReader(Uint8List.fromList(data));
    while (true) {
      final field = r.next();
      if (field == null) break;
      switch (field.number) {
        case 1:
          message = field.asString();
          break;
        case 2:
          count = field.asInt32();
          break;
        case 3:
          delayMs = field.asInt32();
          break;
        default:
          break; // skip unknown fields
      }
    }
  }

  @override
  String toString() =>
      'EchoRequest{message=$message, count=$count, delayMs=$delayMs}';
}

class EchoResponse implements Marshaler, Unmarshaler {
  String message;
  int index;

  EchoResponse([this.message = '', this.index = 0]);

  @override
  Uint8List marshalDc() {
    final w = PbWriter();
    w.stringField(1, message);
    w.int32Field(2, index);
    return w.toBytes();
  }

  @override
  void unmarshalDc(List<int> data) {
    message = '';
    index = 0;
    final r = PbReader(Uint8List.fromList(data));
    while (true) {
      final field = r.next();
      if (field == null) break;
      switch (field.number) {
        case 1:
          message = field.asString();
          break;
        case 2:
          index = field.asInt32();
          break;
        default:
          break; // skip unknown fields
      }
    }
  }

  @override
  String toString() => 'EchoResponse{message=$message, index=$index}';
}
