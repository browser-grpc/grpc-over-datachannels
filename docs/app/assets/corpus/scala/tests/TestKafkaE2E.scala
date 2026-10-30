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
import scala.collection.mutable.ListBuffer

// Kafka proxy end-to-end: generated Scala client -> Rust
// kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise, so the plain `make test-scala` run stays
// broker-free.

object TestKafkaE2E {
  private def createTopic(client: KafkaGrpcDc.KafkaClient): String = {
    val topic = "scala-kafka-e2e-%016x".format(new SecureRandom().nextLong())
    val created = client.CreateTopics(
      new CreateTopicsRequest(List(new NewTopic(topic, 1, 1)), 15000, false)
    )
    check(created.results.size == 1 && created.results.head.errorCode == 0, "create topic")
    val deadline = System.currentTimeMillis() + 15000
    var visible = false
    while (!visible) {
      val latest = client.ListOffsets(new ListOffsetsRequest(topic, 0, -1))
      if (latest.errorCode == 0) {
        visible = true
      } else {
        check(System.currentTimeMillis() < deadline, "topic not visible")
        Thread.sleep(250)
      }
    }
    topic
  }

  private def produce(
      client: KafkaGrpcDc.KafkaClient,
      topic: String,
      values: List[String]
  ): List[Long] = {
    val offsets = ListBuffer.empty[Long]
    for (value <- values) {
      val resp = client.Produce(new ProduceRequest(
        topic,
        0,
        List(new Record(("k-" + value).getBytes, value.getBytes))
      ))
      check(resp.errorCode == 0, "produce error " + resp.errorCode)
      offsets += resp.baseOffset
    }
    offsets.toList
  }

  private def consume(
      client: KafkaGrpcDc.KafkaClient,
      topic: String,
      offset: Long,
      count: Int
  ): List[FetchedRecord] = {
    val got = ListBuffer.empty[FetchedRecord]
    val stream = client.Consume(new ConsumeRequest(topic, 0, offset, count))
    try {
      while (got.size < count) {
        val chunk = stream.recv()
        check(chunk.errorCode == 0, "consume error " + chunk.errorCode)
        got ++= chunk.records
      }
    } finally {
      stream.close()
    }
    got.toList
  }

  private def values(records: List[FetchedRecord]): List[String] =
    records.map(r => new String(r.value))

  def run(): Unit = {
    val addr = System.getenv("KAFKA_E2E_PROXY_ADDR")
    if (addr == null || addr.isEmpty) {
      println("TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)")
      return
    }
    val sep = addr.lastIndexOf(':')
    val client = new KafkaGrpcDc.KafkaClient(
      new Channel(SidecarTransport.connect(addr.substring(0, sep), addr.substring(sep + 1).toInt))
    )

    var topic = createTopic(client)
    check(produce(client, topic, List("v0", "v1", "v2")) == List(0L, 1L, 2L), "roundtrip offsets")
    val latest = client.ListOffsets(new ListOffsetsRequest(topic, 0, -1))
    check(latest.offset == 3 && latest.errorCode == 0, "latest offset")
    val got = consume(client, topic, 0, 3)
    check(values(got) == List("v0", "v1", "v2"), "roundtrip values")
    check(got.map(r => new String(r.key)) == List("k-v0", "k-v1", "k-v2"), "roundtrip keys")
    client.DeleteTopics(new DeleteTopicsRequest(List(topic)))

    topic = createTopic(client)
    val want = (0 until 10).map(i => "seq-%02d".format(i)).toList
    check(produce(client, topic, want) == (0 until 10).map(_.toLong).toList, "ordering offsets")
    check(values(consume(client, topic, 0, 10)) == want, "ordering values")
    client.DeleteTopics(new DeleteTopicsRequest(List(topic)))

    topic = createTopic(client)
    produce(client, topic, List("a", "b", "c", "d"))
    check(values(consume(client, topic, 0, 2)) == List("a", "b"), "resume first")
    check(values(consume(client, topic, 2, 2)) == List("c", "d"), "resume rest")
    client.DeleteTopics(new DeleteTopicsRequest(List(topic)))
    println("TestKafkaE2E OK")
  }
}

def testKafkaE2E(): Unit = TestKafkaE2E.run()
