import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

void check(bool condition, String what) {
  if (!condition) {
    throw StateError('check failed: $what');
  }
}

Uint8List fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Repository root, located by walking up from the cwd looking for
/// fixtures/echo_descriptor_set.bin.
String root() {
  final env = Platform.environment['GRPC_DC_ROOT'];
  if (env != null && env.isNotEmpty) {
    return env;
  }
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/fixtures/echo_descriptor_set.bin').existsSync()) {
      return dir.path;
    }
    if (File('${dir.path}/grpc-over-datachannels/fixtures/echo_descriptor_set.bin')
        .existsSync()) {
      return '${dir.path}/grpc-over-datachannels';
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  return '.';
}

bool fileExists(String path) => File(path).existsSync();

String? javaClasspath(String rootPath) {
  final target = '$rootPath/oracle/java/target';
  final cpFile = File('$target/cp.txt');
  if (!cpFile.existsSync() || !Directory('$target/classes').existsSync()) {
    return null;
  }
  return '$target/classes:${cpFile.readAsStringSync().trim()}';
}

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Read lines from a process stream until one contains needle.
Future<bool> waitReady(Stream<List<int>> stream, String needle) async {
  final lines = stream.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.contains(needle)) {
      return true;
    }
  }
  return false;
}

Future<String> readAll(Stream<List<int>> stream) async {
  return stream.transform(utf8.decoder).join();
}
