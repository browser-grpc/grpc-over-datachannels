// KIP-932 share groups: generated Dart client -> Rust
// kafka_proxy (--tcp) -> Apache Kafka. ACCEPT retires,
// RELEASE redelivers with deliveryCount incremented.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Brokers that cannot run share state skip: Redpanda refuses
// the open, and a combined-mode SASL fixture cannot
// initialize the share persister (the reference share
// consumer stalls identically there); delivery failures
// WITH an assignment still fail.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../grpcdc/channel.dart';
import '../grpcdc/kafka_grpc_dc.dart';
import '../grpcdc/kafka_messages.dart';
import '../grpcdc/sidecar_transport.dart';
import 'test_util.dart';

String _suffix() {
  final r = Random.secure();
  return List.generate(
      8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

Future<void> testKafkaShareE2E() async {
  final addr = Platform.environment['KAFKA_E2E_PROXY_ADDR'];
  if (addr == null || addr.isEmpty) {
    print('TestKafkaShareE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)');
    return;
  }
  final sep = addr.lastIndexOf(':');
  final transport = await SidecarTransport.connect(
    addr.substring(0, sep),
    int.parse(addr.substring(sep + 1)),
  );
  final client = KafkaClient(Channel(transport));
  final topic = 'dart-share-e2e-${_suffix()}';
  final group = 'dart-share-group-${_suffix()}';

  Future<List<SharePollRecord>> poll(String session, int want) async {
    final out = <SharePollRecord>[];
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (out.length < want && DateTime.now().isBefore(deadline)) {
      final resp = await client.sharePoll(SharePollRequest(session, 10, 500));
      check(resp.errorCode == 0, 'share poll error ${resp.errorCode}');
      out.addAll(resp.records);
      if (out.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return out;
  }

  Future<void> produceOne(String value) async {
    final resp = await client.produce(ProduceRequest(topic)
      ..records = [Record()..value = utf8.encode(value)]);
    check(resp.errorCode == 0, 'produce error ${resp.errorCode}');
  }

  final created = await client.createTopics(CreateTopicsRequest(15000)
    ..topics = [NewTopic(topic, 1, 1)]);
  check(created.results.map((r) => r.errorCode).toList().toString() == '[0]',
      'create topic: ${created.results.map((r) => r.errorCode).toList()}');
  try {
    OpenShareGroupResponse opened;
    try {
      opened = await client
          .openShareGroup(OpenShareGroupRequest(group)..topics = [topic]);
    } catch (e) {
      print('TestKafkaShareE2E SKIP (share open raised: $e)');
      return;
    }
    if (opened.errorCode != 0) {
      print('TestKafkaShareE2E SKIP (broker refused share group, '
          'error ${opened.errorCode})');
      return;
    }
    final session = opened.sessionId;
    check(session.isNotEmpty, 'empty share session');
    // Assignment settles asynchronously (bounded in the
    // service); it may still be empty here. Delivery below
    // proves it arrived.
    final assignmentEmpty =
        opened.assignment == null || opened.assignment!.partitions.isEmpty;

    // A share partition's start offset is taken at its first
    // fetch; initialize it before producing.
    final init = await client.sharePoll(SharePollRequest(session, 10, 500));
    check(init.errorCode == 0, 'init poll error ${init.errorCode}');
    check(init.records.isEmpty, 'init poll not empty: ${init.records}');

    await produceOne('s1');
    await produceOne('s2');
    final first = await poll(session, 2);
    if (first.isEmpty && assignmentEmpty) {
      print('TestKafkaShareE2E SKIP '
          '(share assignment never delivered on this broker)');
      return;
    }
    check(first.length == 2, 'share delivery timed out: $first');
    check(first.map((r) => utf8.decode(r.value)).toList().toString() ==
        '[s1, s2]', 'first values');
    check(first.every((r) => r.deliveryCount == 1),
        'first deliveryCount: ${first.map((r) => r.deliveryCount).toList()}');

    final acked = await client.shareAck(ShareAckRequest(session)
      ..entries = [
        for (final r in first) ShareAckEntry(topic, 0, r.offset, 1)
      ]);
    check(acked.errorCode == 0, 'accept error ${acked.errorCode}');
    final empty = await client.sharePoll(SharePollRequest(session, 10, 500));
    check(empty.errorCode == 0 && empty.records.isEmpty,
        'poll after accept not empty');

    await produceOne('s3');
    final third = await poll(session, 1);
    check(third.length == 1, 'share delivery of s3 timed out');
    check(third[0].deliveryCount == 1, 's3 deliveryCount');
    final released = await client.shareAck(ShareAckRequest(session)
      ..entries = [ShareAckEntry(topic, 0, third[0].offset, 2)]);
    check(released.errorCode == 0, 'release error ${released.errorCode}');
    final redelivered = await poll(session, 1);
    check(redelivered.length == 1, 'release redelivery timed out');
    check(redelivered[0].offset == third[0].offset, 'redelivered offset');
    check(redelivered[0].deliveryCount == 2,
        'RELEASE must bump deliveryCount: ${redelivered[0].deliveryCount}');

    final closed = await client.closeShareGroup(CloseShareGroupRequest(session));
    check(closed.errorCode == 0, 'close error ${closed.errorCode}');
    print('TestKafkaShareE2E OK');
  } finally {
    await client.deleteTopics(DeleteTopicsRequest()..topics = [topic]);
  }
}
