// Kafka differential (Dart): transactional produce through
// one form factor, read_committed consume through the other,
// mirroring the Python/JS/Go differentials. Env-gated:
// KAFKA_E2E_BROKER (native), KAFKA_E2E_PROXY_ADDR (proxy),
// GRPC_DC_KAFKA_NATIVE_LIB. Skipped otherwise.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../grpcdc/channel.dart';
import '../grpcdc/kafka_grpc_dc.dart';
import '../grpcdc/kafka_messages.dart';
import '../grpcdc/kafka_native.dart';
import '../grpcdc/sidecar_transport.dart';
import 'test_util.dart';

String _randSuffix() {
  final r = Random.secure();
  return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

Future<void> testKafkaDifferential() async {
  final broker = Platform.environment['KAFKA_E2E_BROKER'];
  final proxyAddr = Platform.environment['KAFKA_E2E_PROXY_ADDR'];
  final lib = Platform.environment['GRPC_DC_KAFKA_NATIVE_LIB'];
  if (broker == null || broker.isEmpty || proxyAddr == null || proxyAddr.isEmpty || lib == null || lib.isEmpty) {
    print('TestKafkaDifferential SKIP (KAFKA_E2E_BROKER / KAFKA_E2E_PROXY_ADDR / GRPC_DC_KAFKA_NATIVE_LIB not set)');
    return;
  }
  final native = KafkaNativeClient(broker);
  final sep = proxyAddr.lastIndexOf(':');
  final transport = await SidecarTransport.connect(
    proxyAddr.substring(0, sep),
    int.parse(proxyAddr.substring(sep + 1)),
  );
  final proxy = KafkaClient(Channel(transport));
  final topic = 'dart-kafka-diff-${_randSuffix()}';
  try {
    final created = native.createTopics(CreateTopicsRequest(15000)
      ..topics = [NewTopic(topic, 1, 1)]);
    check(created.results.map((r) => r.errorCode).toList().toString() == '[0]',
        'create topic: ${created.results.map((r) => r.errorCode).toList()}');

    Future<void> txnNative(String label, bool commit) async {
      final opened = native.openProducer(OpenProducerRequest('grpc-dc-dart-diff-txn-$label', 60000));
      check(opened.errorCode == 0, 'native open producer: ${opened.errorCode}');
      final produced = native.produce(ProduceRequest(topic)
        ..acks = Acks.ACKS_ALL
        ..records = [Record()..value = utf8.encode(label)]
        ..sessionId = opened.sessionId);
      check(produced.errorCode == 0, 'native produce: ${produced.errorCode}');
      final ended = native.endTransaction(EndTransactionRequest(opened.sessionId, commit));
      check(ended.errorCode == 0, 'native end txn: ${ended.errorCode}');
    }

    Future<void> txnProxy(String label, bool commit) async {
      final opened = await proxy.openProducer(OpenProducerRequest('grpc-dc-dart-diff-txn-$label', 60000));
      check(opened.errorCode == 0, 'proxy open producer: ${opened.errorCode}');
      final produced = await proxy.produce(ProduceRequest(topic)
        ..acks = Acks.ACKS_ALL
        ..records = [Record()..value = utf8.encode(label)]
        ..sessionId = opened.sessionId);
      check(produced.errorCode == 0, 'proxy produce: ${produced.errorCode}');
      final ended = await proxy.endTransaction(EndTransactionRequest(opened.sessionId, commit));
      check(ended.errorCode == 0, 'proxy end txn: ${ended.errorCode}');
    }

    Future<List<String>> consumeNativeCommitted(int want) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final values = <String>[];
        await for (final chunk in native.consume(ConsumeRequest(topic, 0, -2)
          ..maxRecords = 10
          ..maxWaitMs = 1000
          ..readCommitted = true)) {
          check(chunk.errorCode == 0, 'native consume: ${chunk.errorCode}');
          for (final r in chunk.records) {
            values.add(utf8.decode(r.value));
          }
          if (values.length >= want) break;
        }
        if (values.length >= want) return values;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      throw StateError('native read_committed timed out (want $want)');
    }

    Future<List<String>> consumeProxyCommitted(int want) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final values = <String>[];
        final stream = await proxy.consume(ConsumeRequest(topic, 0, -2)
          ..maxRecords = 10
          ..maxWaitMs = 1000
          ..readCommitted = true);
        try {
          while (values.length < want) {
            final chunk = await stream.recv();
            check(chunk.errorCode == 0, 'proxy consume: ${chunk.errorCode}');
            for (final r in chunk.records) {
              values.add(utf8.decode(r.value));
            }
          }
        } catch (_) {
          // Stream closed by the service after maxWaitMs with
          // no more data; the outer loop retries from -2.
        }
        if (values.length >= want) return values;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      throw StateError('proxy read_committed timed out (want $want)');
    }

    // Proxy transacts, native reads committed; then swapped.
    await txnProxy('tx-proxy-commit', true);
    await txnProxy('tx-proxy-abort', false);
    var got = await consumeNativeCommitted(1);
    check(got.toString() == '[tx-proxy-commit]', 'native read_committed: $got');
    await txnNative('tx-native-commit', true);
    await txnNative('tx-native-abort', false);
    got = await consumeProxyCommitted(2);
    check(got.toString() == '[tx-proxy-commit, tx-native-commit]', 'proxy read_committed: $got');
  } finally {
    try {
      native.deleteTopics(DeleteTopicsRequest(15000)..topics = [topic]);
    } catch (_) {}
    native.close();
  }
}
