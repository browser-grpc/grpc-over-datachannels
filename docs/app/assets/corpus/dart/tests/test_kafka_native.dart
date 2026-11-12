// Kafka native end-to-end: generated Dart messages ->
// libkafka_native in-process (no proxy, no gRPC hop).
//
// Env-gated: set KAFKA_E2E_BROKER=host:port of a broker and
// GRPC_DC_KAFKA_NATIVE_LIB=path/to/libkafka_native.so.
// Skipped otherwise.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../grpcdc/kafka_messages.dart';
import '../grpcdc/kafka_native.dart';
import 'test_util.dart';

String _randSuffix() {
  final r = Random.secure();
  return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

Future<void> testKafkaNative() async {
  final broker = Platform.environment['KAFKA_E2E_BROKER'];
  final lib = Platform.environment['GRPC_DC_KAFKA_NATIVE_LIB'];
  if (broker == null || broker.isEmpty || lib == null || lib.isEmpty) {
    print('TestKafkaNative SKIP (KAFKA_E2E_BROKER / GRPC_DC_KAFKA_NATIVE_LIB not set)');
    return;
  }
  final client = KafkaNativeClient(broker);
  final topic = 'dart-kafka-native-${_randSuffix()}';
  try {
    final created = client.createTopics(CreateTopicsRequest(15000)
      ..topics = [NewTopic(topic, 1, 1)]);
    check(created.results.map((r) => r.errorCode).toList().toString() == '[0]',
        'create topic: ${created.results.map((r) => r.errorCode).toList()}');

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (true) {
      final meta = client.metadata(MetadataRequest()..topics = [topic]);
      final found = meta.topics.where((t) => t.name == topic).toList();
      if (found.isNotEmpty && found.first.partitions.isNotEmpty) break;
      check(DateTime.now().isBefore(deadline), 'topic not visible');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    final produced = client.produce(ProduceRequest(topic)
      ..records = [
        Record()..value = utf8.encode('one'),
        Record()..value = utf8.encode('two'),
        Record()..value = utf8.encode('three'),
      ]);
    check(produced.errorCode == 0, 'produce: ${produced.errorCode}');

    final values = <String>[];
    await for (final chunk in client.consume(ConsumeRequest(topic, 0, -2)
      ..maxRecords = 10
      ..maxWaitMs = 2000)) {
      check(chunk.errorCode == 0, 'consume error: ${chunk.errorCode}');
      for (final r in chunk.records) {
        values.add(utf8.decode(r.value));
      }
      if (values.length >= 3) break;
    }
    check(values.toString() == '[one, two, three]', 'values: $values');

    final latest = client.listOffsets(ListOffsetsRequest(topic, 0, -1));
    check(latest.errorCode == 0 && latest.offset == 3,
        'listOffsets: ${latest.errorCode} ${latest.offset}');
    print('TestKafkaNative OK');
  } finally {
    try {
      client.deleteTopics(DeleteTopicsRequest(15000)..topics = [topic]);
    } catch (_) {}
    client.close();
  }
}
