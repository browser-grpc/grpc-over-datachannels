// Kafka native end-to-end (Swift direct C ABI consumer):
// generated Swift messages -> libkafka_native in-process
// via the KafkaNativeC module (kafka_native.h) — no proxy,
// no gRPC hop, no wrapper layer; Swift imports the C ABI
// directly.
//
// Compile (native leg only): swiftc swift/grpcdc/*.swift
// swift/tests/TestKafkaNative.swift -I <modulemap dir>
// -L <lib dir> -lkafka_native. Env-gated on
// KAFKA_E2E_BROKER=host:port. Prints TestKafkaNative OK.

import Foundation
import KafkaNativeC

final class NativeError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String) {
        description = "\(what): \(String(cString: kafka_native_last_error()))"
    }
}

func check(_ ok: Bool, _ what: String) throws {
    if !ok { throw NativeError(what) }
}

func unary<Resp: Unmarshaler>(_ handle: OpaquePointer, _ method: String, _ req: Marshaler, _ make: () -> Resp) throws -> Resp {
    let payload = req.MarshalDc()
    var out: UnsafeMutablePointer<UInt8>?
    var outLen = 0
    let rc = payload.withUnsafeBufferPointer { buf in
        kafka_native_call(handle, method, buf.baseAddress, buf.count, &out, &outLen)
    }
    if rc != 0 { throw NativeError(method) }
    var data: [UInt8] = []
    if let out, outLen > 0 {
        data = Array(UnsafeBufferPointer(start: out, count: outLen))
        kafka_native_bytes_free(out, outLen)
    }
    let resp = make()
    resp.UnmarshalDc(data)
    return resp
}

@main
struct KafkaNativeMain {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard let broker = env["KAFKA_E2E_BROKER"], !broker.isEmpty else {
            print("TestKafkaNative SKIP (KAFKA_E2E_BROKER not set)")
            return
        }
        guard let handle = kafka_native_new(broker, "grpc-dc-kafka-native") else {
            throw NativeError("kafka_native_new")
        }
        defer { kafka_native_free(handle) }

        let suffix = String(format: "%016x", UInt64.random(in: 0...UInt64.max))
        let topic = "swift-kafka-native-\(suffix)"

        var newTopic = NewTopic()
        newTopic.name = topic
        newTopic.numPartitions = 1
        newTopic.replicationFactor = 1
        var createReq = CreateTopicsRequest()
        createReq.topics = [newTopic]
        createReq.timeoutMs = 15000
        let created: CreateTopicsResponse = try unary(handle, "CreateTopics", createReq) { CreateTopicsResponse() }
        try check(created.results.map { $0.errorCode } == [0], "create topic")

        let deadline = Date().addingTimeInterval(15)
        while true {
            var metaReq = MetadataRequest()
            metaReq.topics = [topic]
            let meta: MetadataResponse = try unary(handle, "Metadata", metaReq) { MetadataResponse() }
            if meta.topics.contains(where: { $0.name == topic && !$0.partitions.isEmpty }) { break }
            try check(Date() < deadline, "topic not visible")
            Thread.sleep(forTimeInterval: 0.25)
        }

        var produceReq = ProduceRequest()
        produceReq.topic = topic
        produceReq.partition = 0
        produceReq.records = ["one", "two", "three"].map { v in
            var r = Record()
            r.value = [UInt8](v.utf8)
            return r
        }
        let produced: ProduceResponse = try unary(handle, "Produce", produceReq) { ProduceResponse() }
        try check(produced.errorCode == 0, "produce")

        var consumeReq = ConsumeRequest()
        consumeReq.topic = topic
        consumeReq.partition = 0
        consumeReq.offset = -2
        consumeReq.maxRecords = 10
        consumeReq.maxWaitMs = 2000
        let payload = consumeReq.MarshalDc()
        let stream = payload.withUnsafeBufferPointer { buf in
            kafka_native_stream_new(handle, "Consume", buf.baseAddress, buf.count)
        }
        guard let stream else { throw NativeError("stream_new") }
        var values: [String] = []
        while values.count < 3 {
            var out: UnsafeMutablePointer<UInt8>?
            var outLen = 0
            let rc = kafka_native_stream_next(stream, &out, &outLen)
            try check(rc >= 0, "stream_next")
            if rc == 0 { break }
            var data: [UInt8] = []
            if let out, outLen > 0 {
                data = Array(UnsafeBufferPointer(start: out, count: outLen))
                kafka_native_bytes_free(out, outLen)
            }
            var chunk = ConsumeResponse()
            chunk.UnmarshalDc(data)
            try check(chunk.errorCode == 0, "consume error")
            values += chunk.records.map { String(decoding: $0.value, as: UTF8.self) }
        }
        kafka_native_stream_free(stream)
        try check(values == ["one", "two", "three"], "roundtrip values: \(values)")

        var offsetsReq = ListOffsetsRequest()
        offsetsReq.topic = topic
        offsetsReq.partition = 0
        offsetsReq.timestamp = -1
        let latest: ListOffsetsResponse = try unary(handle, "ListOffsets", offsetsReq) { ListOffsetsResponse() }
        try check(latest.errorCode == 0 && latest.offset == 3, "listOffsets")
        print("TestKafkaNative OK")
    }
}
