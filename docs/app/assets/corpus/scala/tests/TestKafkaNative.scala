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
import java.security.SecureRandom
import scala.collection.mutable.ListBuffer

// Kafka native end-to-end: generated Scala messages ->
// libkafka_native in-process (no proxy, no gRPC hop).
//
// Env-gated: set KAFKA_E2E_BROKER=host:port of a broker and
// GRPC_DC_KAFKA_NATIVE_JNI=path/to/libkafka_native_jni.so.
// Skipped otherwise.

object TestKafkaNative {
  def run(): Unit = {
    val broker = System.getenv("KAFKA_E2E_BROKER")
    val jni = System.getenv("GRPC_DC_KAFKA_NATIVE_JNI")
    if (broker == null || broker.isEmpty || jni == null || jni.isEmpty) {
      println("TestKafkaNative SKIP (KAFKA_E2E_BROKER / GRPC_DC_KAFKA_NATIVE_JNI not set)")
      return
    }
    val client = new KafkaNative(broker, "grpc-dc-kafka-native-scala")
    val topic = "scala-kafka-native-%016x".format(new SecureRandom().nextLong())
    try {
      val created = client.createTopics(
        new CreateTopicsRequest(List(new NewTopic(topic, 1, 1)), 15000, false))
      check(created.results.size == 1 && created.results.head.errorCode == 0, "create topic")

      val deadline = System.currentTimeMillis() + 15000
      var visible = false
      while (!visible) {
        val meta = client.metadata(new MetadataRequest(List(topic), false))
        if (meta.topics.exists(t => t.name == topic && t.partitions.nonEmpty)) {
          visible = true
        } else {
          check(System.currentTimeMillis() < deadline, "topic not visible")
          Thread.sleep(250)
        }
      }

      val produced = client.produce(new ProduceRequest(
        topic,
        0,
        List(
          new Record(Array.empty[Byte], "one".getBytes),
          new Record(Array.empty[Byte], "two".getBytes),
          new Record(Array.empty[Byte], "three".getBytes)
        )
      ))
      check(produced.errorCode == 0, "produce: " + produced.errorCode)

      val values = ListBuffer.empty[String]
      val it = client.consume(new ConsumeRequest(topic, 0, -2, 10, 2000))
      while (values.size < 3 && it.hasNext) {
        val chunk = it.next()
        check(chunk.errorCode == 0, "consume error: " + chunk.errorCode)
        for (r <- chunk.records) values += new String(r.value)
      }
      check(values.toList == List("one", "two", "three"), "values: " + values.toList)

      val latest = client.listOffsets(new ListOffsetsRequest(topic, 0, -1))
      check(latest.errorCode == 0 && latest.offset == 3, "listOffsets: " + latest.errorCode + " " + latest.offset)
      println("TestKafkaNative OK")
    } finally {
      try {
        client.deleteTopics(new DeleteTopicsRequest(List(topic), 15000))
      } catch {
        case _: Throwable => ()
      }
      client.close()
    }
  }
}

def testKafkaNative(): Unit = TestKafkaNative.run()
