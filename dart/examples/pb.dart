import 'dart:convert';
import 'dart:typed_data';

/// Minimal protobuf wire writer/reader for the hand-written messages.
class PbWriter {
  final _out = BytesBuilder();

  void varint(int value) {
    var v = value;
    while ((v & ~0x7f) != 0) {
      _out.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _out.addByte(v & 0xff);
  }

  void stringField(int field, String value) {
    if (value.isEmpty) return;
    final bytes = utf8.encode(value);
    varint((field << 3) | 2);
    varint(bytes.length);
    _out.add(bytes);
  }

  void int32Field(int field, int value) {
    if (value == 0) return;
    varint((field << 3) | 0);
    varint(value);
  }

  Uint8List toBytes() => _out.toBytes();
}

class PbField {
  final int number;
  final int varintValue;
  final Uint8List bytesValue;

  PbField(this.number, this.varintValue, this.bytesValue);

  int asInt32() => varintValue.toSigned(32);
  String asString() => utf8.decode(bytesValue);
}

class PbReader {
  final Uint8List _buf;
  int _pos = 0;

  PbReader(this._buf);

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _buf.length) {
        throw ArgumentError('truncated varint');
      }
      final b = _buf[_pos++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
      if (shift >= 64) {
        throw ArgumentError('varint too long');
      }
    }
  }

  /// Next field, or null at end.
  PbField? next() {
    if (_pos >= _buf.length) return null;
    final tag = varint();
    final number = tag >> 3;
    switch (tag & 7) {
      case 0:
        return PbField(number, varint(), Uint8List(0));
      case 2:
        final n = varint();
        if (_pos + n > _buf.length) {
          throw ArgumentError('truncated bytes field');
        }
        final bytes = Uint8List.fromList(_buf.sublist(_pos, _pos + n));
        _pos += n;
        return PbField(number, 0, bytes);
      case 1:
        if (_pos + 8 > _buf.length) {
          throw ArgumentError('truncated fixed64');
        }
        final bytes = Uint8List.fromList(_buf.sublist(_pos, _pos + 8));
        _pos += 8;
        return PbField(number, 0, bytes);
      case 5:
        if (_pos + 4 > _buf.length) {
          throw ArgumentError('truncated fixed32');
        }
        final bytes = Uint8List.fromList(_buf.sublist(_pos, _pos + 4));
        _pos += 4;
        return PbField(number, 0, bytes);
      default:
        throw ArgumentError('bad wire type');
    }
  }
}
