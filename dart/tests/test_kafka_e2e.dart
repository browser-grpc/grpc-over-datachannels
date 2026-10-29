// Kafka proxy end-to-end: generated Dart client -> Rust
// kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise, so the plain `make test-dart` run stays
// broker-free.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../grpcdc/channel.dart';
import '../grpcdc/kafka_grpc_dc.dart';
import '../grpcdc/kafka_messages.dart';
import '../grpcdc/sidecar_transport.dart';
import 'test_util.dart';

String _randSuffix() {
  final r = Random.secure();
  return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

Future<void> testKafkaE2E() async {
  final addr = Platform.environment['KAFKA_E2E_PROXY_ADDR'];
  if (addr == null || addr.isEmpty) {
    print('TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)');
    return;
  }
  final sep = addr.lastIndexOf(':');
  final transport = await SidecarTransport.connect(
    addr.substring(0, sep),
    int.parse(addr.substring(sep + 1)),
  );
  final client = KafkaClient(Channel(transport));

  Future<String> createTopic() async {
    final topic = 'dart-kafka-e2e-${_randSuffix()}';
    final created = await client.createTopics(CreateTopicsRequest(15000)
      ..topics = [NewTopic(topic, 1, 1)]);
    check(created.results.map((r) => r.errorCode).toList().toString() == '[0]',
        'create topic: ${created.results.map((r) => r.errorCode).toList()}');
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (true) {
      final latest = await client.listOffsets(ListOffsetsRequest(topic, 0, -1));
      if (latest.errorCode == 0) break;
      check(DateTime.now().isBefore(deadline), 'topic not visible');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return topic;
  }

  Future<List<int>> produce(String topic, List<String> values) async {
    final offsets = <int>[];
    for (final value in values) {
      final resp = await client.produce(ProduceRequest(topic)
        ..records = [
          Record()
            ..key = utf8.encode('k-$value')
            ..value = utf8.encode(value),
        ]);
      check(resp.errorCode == 0, 'produce error ${resp.errorCode}');
      offsets.add(resp.baseOffset);
    }
    return offsets;
  }

  Future<List<FetchedRecord>> consume(String topic, int offset, int count) async {
    final stream = await client.consume(ConsumeRequest(topic, 0, offset, count));
    final got = <FetchedRecord>[];
    try {
      await for (final chunk in stream.responses) {
        check(chunk.errorCode == 0, 'consume error ${chunk.errorCode}');
        got.addAll(chunk.records);
        if (got.length >= count) break;
      }
    } finally {
      stream.close();
    }
    return got;
  }

  List<String> values(List<FetchedRecord> rs) =>
      rs.map((r) => utf8.decode(r.value)).toList();

  var topic = await createTopic();
  try {
    check((await produce(topic, ['v0', 'v1', 'v2'])).toString() == '[0, 1, 2]',
        'roundtrip offsets');
    final latest = await client.listOffsets(ListOffsetsRequest(topic, 0, -1));
    check(latest.offset == 3 && latest.errorCode == 0, 'latest $latest');
    final got = await consume(topic, 0, 3);
    check(values(got).toString() == '[v0, v1, v2]', 'roundtrip values ${values(got)}');
    check(got.map((r) => utf8.decode(r.key)).toList().toString() == '[k-v0, k-v1, k-v2]',
        'roundtrip keys');
  } finally {
    await client.deleteTopics(DeleteTopicsRequest()..topics = [topic]);
  }

  topic = await createTopic();
  try {
    final want = List.generate(10, (i) => 'seq-${i.toString().padLeft(2, '0')}');
    check((await produce(topic, want)).toString() == '[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]',
        'ordering offsets');
    check(values(await consume(topic, 0, 10)).toString() == want.toString(),
        'ordering values');
  } finally {
    await client.deleteTopics(DeleteTopicsRequest()..topics = [topic]);
  }

  topic = await createTopic();
  try {
    await produce(topic, ['a', 'b', 'c', 'd']);
    check(values(await consume(topic, 0, 2)).toString() == '[a, b]', 'resume first');
    check(values(await consume(topic, 2, 2)).toString() == '[c, d]', 'resume rest');
  } finally {
    await client.deleteTopics(DeleteTopicsRequest()..topics = [topic]);
  }
  print('TestKafkaE2E OK');
}
