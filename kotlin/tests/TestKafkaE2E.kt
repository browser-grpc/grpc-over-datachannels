package tests

import grpcdc.Channel
import grpcdc.SidecarTransport
import grpcdc.kafka.v1.ConsumeRequest
import grpcdc.kafka.v1.CreateTopicsRequest
import grpcdc.kafka.v1.DeleteTopicsRequest
import grpcdc.kafka.v1.FetchedRecord
import grpcdc.kafka.v1.KafkaGrpcDc
import grpcdc.kafka.v1.ListOffsetsRequest
import grpcdc.kafka.v1.NewTopic
import grpcdc.kafka.v1.ProduceRequest
import grpcdc.kafka.v1.Record
import java.security.SecureRandom

// Kafka proxy end-to-end: generated Kotlin client -> Rust
// kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise, so the plain `make test-kotlin` run stays
// broker-free.

private fun createTopic(client: KafkaGrpcDc.KafkaClient): String {
    val topic = "kotlin-kafka-e2e-%016x".format(SecureRandom().nextLong())
    val created = client.CreateTopics(
        CreateTopicsRequest(mutableListOf(NewTopic(topic, 1, 1)), 15000, false)
    )
    check(created.results.size == 1 && created.results[0].errorCode == 0) { "create topic" }
    val deadline = System.currentTimeMillis() + 15000
    while (true) {
        val latest = client.ListOffsets(ListOffsetsRequest(topic, 0, -1))
        if (latest.errorCode == 0) return topic
        check(System.currentTimeMillis() < deadline) { "topic not visible" }
        Thread.sleep(250)
    }
}

private fun produce(
    client: KafkaGrpcDc.KafkaClient,
    topic: String,
    values: List<String>,
): List<Long> {
    val offsets = mutableListOf<Long>()
    for (value in values) {
        val resp = client.Produce(
            ProduceRequest(
                topic, 0,
                mutableListOf(Record("k-$value".toByteArray(), value.toByteArray())),
            )
        )
        check(resp.errorCode == 0) { "produce error ${resp.errorCode}" }
        offsets.add(resp.baseOffset)
    }
    return offsets
}

private fun consume(
    client: KafkaGrpcDc.KafkaClient,
    topic: String,
    offset: Long,
    count: Int,
): List<FetchedRecord> {
    val got = mutableListOf<FetchedRecord>()
    client.Consume(ConsumeRequest(topic, 0, offset, count)).use { stream ->
        while (got.size < count) {
            val chunk = stream.recv()
            check(chunk.errorCode == 0) { "consume error ${chunk.errorCode}" }
            got.addAll(chunk.records)
        }
    }
    return got
}

private fun values(records: List<FetchedRecord>): List<String> =
    records.map { String(it.value) }

fun testKafkaE2E() {
    val addr = System.getenv("KAFKA_E2E_PROXY_ADDR")
    if (addr.isNullOrEmpty()) {
        println("TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)")
        return
    }
    val sep = addr.lastIndexOf(':')
    val client = KafkaGrpcDc.KafkaClient(
        Channel(SidecarTransport.connect(addr.substring(0, sep), addr.substring(sep + 1).toInt()))
    )

    var topic = createTopic(client)
    check(produce(client, topic, listOf("v0", "v1", "v2")) == listOf(0L, 1L, 2L)) {
        "roundtrip offsets"
    }
    val latest = client.ListOffsets(ListOffsetsRequest(topic, 0, -1))
    check(latest.offset == 3L && latest.errorCode == 0) { "latest offset" }
    val got = consume(client, topic, 0, 3)
    check(values(got) == listOf("v0", "v1", "v2")) { "roundtrip values" }
    check(got.map { String(it.key) } == listOf("k-v0", "k-v1", "k-v2")) { "roundtrip keys" }
    client.DeleteTopics(DeleteTopicsRequest(mutableListOf(topic)))

    topic = createTopic(client)
    val want = (0 until 10).map { "seq-%02d".format(it) }
    check(produce(client, topic, want) == (0 until 10).map { it.toLong() }) {
        "ordering offsets"
    }
    check(values(consume(client, topic, 0, 10)) == want) { "ordering values" }
    client.DeleteTopics(DeleteTopicsRequest(mutableListOf(topic)))

    topic = createTopic(client)
    produce(client, topic, listOf("a", "b", "c", "d"))
    check(values(consume(client, topic, 0, 2)) == listOf("a", "b")) { "resume first" }
    check(values(consume(client, topic, 2, 2)) == listOf("c", "d")) { "resume rest" }
    client.DeleteTopics(DeleteTopicsRequest(mutableListOf(topic)))
    println("TestKafkaE2E OK")
}
