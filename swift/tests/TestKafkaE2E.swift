import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Kafka proxy end-to-end: generated Swift client -> Rust
// kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise, so the plain `make test-swift` run stays
// broker-free.

private func kafkaCreateTopic(_ client: KafkaGrpcDc.KafkaClient) throws -> String {
    let suffix = String(format: "%016x", UInt64.random(in: 0...UInt64.max))
    let topic = "swift-kafka-e2e-\(suffix)"
    let created = try client.CreateTopics(CreateTopicsRequest([NewTopic(topic, 1, 1)], 15000, false))
    try Check(created.results.count == 1 && created.results[0].errorCode == 0, "create topic")
    let deadline = Date().addingTimeInterval(15)
    while true {
        let latest = try client.ListOffsets(ListOffsetsRequest(topic, 0, -1))
        if latest.errorCode == 0 {
            return topic
        }
        try Check(Date() < deadline, "topic not visible")
        Thread.sleep(forTimeInterval: 0.25)
    }
}

private func kafkaProduce(
    _ client: KafkaGrpcDc.KafkaClient, _ topic: String, _ vals: [String]
) throws -> [Int64] {
    var offsets: [Int64] = []
    for value in vals {
        let resp = try client.Produce(ProduceRequest(topic, 0, [
            Record(Array(("k-" + value).utf8), Array(value.utf8)),
        ]))
        try Check(resp.errorCode == 0, "produce error \(resp.errorCode)")
        offsets.append(resp.baseOffset)
    }
    return offsets
}

private func kafkaConsume(
    _ client: KafkaGrpcDc.KafkaClient, _ topic: String, _ offset: Int64, _ count: Int32
) throws -> [FetchedRecord] {
    var got: [FetchedRecord] = []
    let stream = try client.Consume(ConsumeRequest(topic, 0, offset, count))
    while got.count < count {
        let chunk = try stream.Recv()
        try Check(chunk.errorCode == 0, "consume error \(chunk.errorCode)")
        got.append(contentsOf: chunk.records)
    }
    stream.Close()
    return got
}

private func kafkaValues(_ records: [FetchedRecord]) -> [String] {
    records.map { String(decoding: $0.value, as: UTF8.self) }
}

func TestKafkaE2E() throws {
    let addr = ProcessInfo.processInfo.environment["KAFKA_E2E_PROXY_ADDR"] ?? ""
    if addr.isEmpty {
        print("TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)")
        return
    }
    let sep = addr.lastIndex(of: ":")!
    let client = KafkaGrpcDc.KafkaClient(Channel(
        try SidecarTransport.Connect(String(addr[..<sep]), Int(addr[addr.index(after: sep)...])!)))

    var topic = try kafkaCreateTopic(client)
    try Check(try kafkaProduce(client, topic, ["v0", "v1", "v2"]) == [0, 1, 2], "roundtrip offsets")
    let latest = try client.ListOffsets(ListOffsetsRequest(topic, 0, -1))
    try Check(latest.offset == 3 && latest.errorCode == 0, "latest offset")
    let got = try kafkaConsume(client, topic, 0, 3)
    try Check(kafkaValues(got) == ["v0", "v1", "v2"], "roundtrip values")
    try Check(got.map { String(decoding: $0.key, as: UTF8.self) } == ["k-v0", "k-v1", "k-v2"],
              "roundtrip keys")
    _ = try client.DeleteTopics(DeleteTopicsRequest([topic], 0))

    topic = try kafkaCreateTopic(client)
    let want = (0..<10).map { String(format: "seq-%02d", $0) }
    try Check(try kafkaProduce(client, topic, want) == (0..<10).map { Int64($0) }, "ordering offsets")
    try Check(kafkaValues(try kafkaConsume(client, topic, 0, 10)) == want, "ordering values")
    _ = try client.DeleteTopics(DeleteTopicsRequest([topic], 0))

    topic = try kafkaCreateTopic(client)
    _ = try kafkaProduce(client, topic, ["a", "b", "c", "d"])
    try Check(kafkaValues(try kafkaConsume(client, topic, 0, 2)) == ["a", "b"], "resume first")
    try Check(kafkaValues(try kafkaConsume(client, topic, 2, 2)) == ["c", "d"], "resume rest")
    _ = try client.DeleteTopics(DeleteTopicsRequest([topic], 0))
    print("TestKafkaE2E OK")
}
