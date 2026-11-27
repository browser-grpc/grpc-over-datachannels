package tests

import grpcdc.KafkaNative
import grpcdc.kafka.v1.ConsumeRequest
import grpcdc.kafka.v1.CreateTopicsRequest
import grpcdc.kafka.v1.DeleteTopicsRequest
import grpcdc.kafka.v1.ListOffsetsRequest
import grpcdc.kafka.v1.MetadataRequest
import grpcdc.kafka.v1.NewTopic
import grpcdc.kafka.v1.ProduceRequest
import grpcdc.kafka.v1.Record

// Kafka native end-to-end: generated Kotlin messages ->
// libkafka_native in-process (no proxy, no gRPC hop).
//
// Env-gated: set KAFKA_E2E_BROKER=host:port of a broker and
// GRPC_DC_KAFKA_NATIVE_JNI=path/to/libkafka_native_jni.so.
// Skipped otherwise.

private fun suffix(): String {
    val bytes = ByteArray(4)
    java.security.SecureRandom().nextBytes(bytes)
    return bytes.joinToString("") { "%02x".format(it) }
}

fun testKafkaNative() {
    val broker = System.getenv("KAFKA_E2E_BROKER")
    val jni = System.getenv("GRPC_DC_KAFKA_NATIVE_JNI")
    if (broker.isNullOrEmpty() || jni.isNullOrEmpty()) {
        println("TestKafkaNative SKIP (KAFKA_E2E_BROKER / GRPC_DC_KAFKA_NATIVE_JNI not set)")
        return
    }
    val client = KafkaNative(broker, "grpc-dc-kafka-native-kotlin")
    val topic = "kotlin-kafka-native-" + suffix()
    try {
        val created = client.createTopics(
            CreateTopicsRequest(mutableListOf(NewTopic(topic, 1, 1)), 15000, false))
        check(created.results.size == 1 && created.results[0].errorCode == 0) { "create topic" }

        val deadline = System.currentTimeMillis() + 15000
        while (true) {
            val meta = client.metadata(MetadataRequest(mutableListOf(topic), false))
            val found = meta.topics.firstOrNull { it.name == topic }
            if (found != null && found.partitions.isNotEmpty()) break
            check(System.currentTimeMillis() < deadline) { "topic not visible" }
            Thread.sleep(250)
        }

        val produced = client.produce(ProduceRequest().apply {
            this.topic = topic
            records = mutableListOf(
                Record().apply { value = "one".toByteArray() },
                Record().apply { value = "two".toByteArray() },
                Record().apply { value = "three".toByteArray() },
            )
        })
        check(produced.errorCode == 0) { "produce: ${produced.errorCode}" }

        val values = mutableListOf<String>()
        val it = client.consume(ConsumeRequest().apply {
            this.topic = topic
            offset = -2
            maxRecords = 10
            maxWaitMs = 2000
        })
        while (values.size < 3 && it.hasNext()) {
            val chunk = it.next()
            check(chunk.errorCode == 0) { "consume error: ${chunk.errorCode}" }
            for (r in chunk.records) values.add(String(r.value))
        }
        check(values == listOf("one", "two", "three")) { "values: $values" }

        val latest = client.listOffsets(ListOffsetsRequest().apply {
            this.topic = topic
            timestamp = -1
        })
        check(latest.errorCode == 0 && latest.offset == 3L) {
            "listOffsets: ${latest.errorCode} ${latest.offset}"
        }
        println("TestKafkaNative OK")
    } finally {
        try {
            client.deleteTopics(DeleteTopicsRequest(mutableListOf(topic), 15000))
        } catch (_: Throwable) {
        }
        client.close()
    }
}
