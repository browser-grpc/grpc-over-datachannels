import 'dart:async';
import 'dart:typed_data';

import '../grpcdc/status.dart';
import '../grpcdc/transport.dart';

/// Frames DataChannel messages over a byte stream with a 4-byte
/// big-endian length prefix (the prefix exists only to frame messages
/// on a byte stream; each framed unit is exactly one DataChannel
/// message). Used by the cross-language interop harnesses over
/// dart:io stdin/stdout or process pipes.
class StdioTransport implements Transport {
  final void Function(List<int> data) _write;
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();
  final _pending = <int>[];
  bool _closed = false;

  StdioTransport(Stream<List<int>> input, this._write, {void Function()? onEof}) {
    input.listen(
      (chunk) {
        _pending.addAll(chunk);
        _drain();
      },
      onError: (_) => _shutdown(onEof),
      onDone: () => _shutdown(onEof),
    );
  }

  void _shutdown(void Function()? onEof) {
    if (_closed) return;
    _closed = true;
    _controller.close();
    onEof?.call();
  }

  void _drain() {
    while (true) {
      if (_pending.length < 4) return;
      final len = (_pending[0] << 24) |
          (_pending[1] << 16) |
          (_pending[2] << 8) |
          _pending[3];
      if (_pending.length < 4 + len) return;
      final frame = Uint8List.fromList(_pending.sublist(4, 4 + len));
      _pending.removeRange(0, 4 + len);
      _controller.add(frame);
    }
  }

  @override
  Stream<Uint8List> get onMessage => _controller.stream;

  @override
  void send(Uint8List data) {
    if (_closed) {
      throw EndOfStreamError();
    }
    final len = data.length;
    _write([
      (len >> 24) & 0xff,
      (len >> 16) & 0xff,
      (len >> 8) & 0xff,
      len & 0xff,
      ...data,
    ]);
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _controller.close();
  }
}
