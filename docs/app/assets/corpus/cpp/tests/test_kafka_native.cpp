// Kafka native end-to-end (C++ direct C ABI consumer):
// generated C++ messages -> libkafka_native in-process via
// kafka_native.h (no proxy, no gRPC hop, no wrapper layer —
// C++ consumes the C ABI directly).
//
// Env-gated: KAFKA_E2E_BROKER=host:port of a broker.
// Prints TestKafkaNative OK.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "examples/kafka_messages.hpp"
#include "kafka_native.h"

namespace {

using namespace grpcdc::kafka::v1;

[[noreturn]] void Fail(const std::string& what) {
    throw std::runtime_error(what + ": " + kafka_native_last_error());
}

void Check(bool ok, const std::string& what) {
    if (!ok) Fail(what);
}

struct Client {
    KafkaNativeHandle* h;
    explicit Client(const char* broker) : h(kafka_native_new(broker, "grpc-dc-kafka-native")) {
        if (!h) Fail("kafka_native_new");
    }
    ~Client() { kafka_native_free(h); }

    template <typename Resp, typename Req>
    Resp Unary(const char* method, const Req& req) {
        auto payload = req.MarshalDc();
        uint8_t* out = nullptr;
        size_t out_len = 0;
        if (kafka_native_call(h, method, payload.data(), payload.size(), &out, &out_len) != 0) {
            Fail(method);
        }
        std::vector<uint8_t> data;
        if (out && out_len) data.assign(out, out + out_len);
        if (out) kafka_native_bytes_free(out, out_len);
        Resp resp;
        resp.UnmarshalDc(data);
        return resp;
    }
};

std::string RandSuffix() {
    std::random_device rd;
    char buf[17];
    std::snprintf(buf, sizeof(buf), "%08x%08x", rd(), rd());
    return buf;
}

}  // namespace

int main() {
    const char* broker = std::getenv("KAFKA_E2E_BROKER");
    if (!broker || !*broker) {
        std::puts("TestKafkaNative SKIP (KAFKA_E2E_BROKER not set)");
        return 0;
    }
    Client client(broker);
    std::string topic = "cpp-kafka-native-" + RandSuffix();
    try {
        CreateTopicsRequest create;
        NewTopic new_topic;
        new_topic.name = topic;
        new_topic.num_partitions = 1;
        new_topic.replication_factor = 1;
        create.topics.push_back(new_topic);
        create.timeout_ms = 15000;
        auto created = client.Unary<CreateTopicsResponse>("CreateTopics", create);
        Check(created.results.size() == 1 && created.results[0].error_code == 0, "create topic");

        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
        while (true) {
            MetadataRequest meta;
            meta.topics.push_back(topic);
            auto resp = client.Unary<MetadataResponse>("Metadata", meta);
            bool ready = false;
            for (auto& t : resp.topics) {
                if (t.name == topic && !t.partitions.empty()) ready = true;
            }
            if (ready) break;
            Check(std::chrono::steady_clock::now() < deadline, "topic not visible");
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
        }

        ProduceRequest produce;
        produce.topic = topic;
        produce.partition = 0;
        for (const char* v : {"one", "two", "three"}) {
            Record rec;
            rec.value = std::vector<uint8_t>(v, v + std::strlen(v));
            produce.records.push_back(rec);
        }
        auto produced = client.Unary<ProduceResponse>("Produce", produce);
        Check(produced.error_code == 0, "produce");

        ConsumeRequest consume;
        consume.topic = topic;
        consume.partition = 0;
        consume.offset = -2;
        consume.max_records = 10;
        consume.max_wait_ms = 2000;
        auto payload = consume.MarshalDc();
        KafkaNativeStream* stream =
            kafka_native_stream_new(client.h, "Consume", payload.data(), payload.size());
        if (!stream) Fail("stream_new");
        std::vector<std::string> values;
        while (values.size() < 3) {
            uint8_t* out = nullptr;
            size_t out_len = 0;
            int rc = kafka_native_stream_next(stream, &out, &out_len);
            Check(rc >= 0, "stream_next");
            if (rc == 0) break;
            ConsumeResponse chunk;
            std::vector<uint8_t> data;
            if (out && out_len) data.assign(out, out + out_len);
            if (out) kafka_native_bytes_free(out, out_len);
            chunk.UnmarshalDc(data);
            Check(chunk.error_code == 0, "consume error");
            for (auto& r : chunk.records) {
                values.emplace_back(r.value.begin(), r.value.end());
            }
        }
        kafka_native_stream_free(stream);
        Check(values == std::vector<std::string>({"one", "two", "three"}), "roundtrip values");

        ListOffsetsRequest offsets;
        offsets.topic = topic;
        offsets.partition = 0;
        offsets.timestamp = -1;
        auto latest = client.Unary<ListOffsetsResponse>("ListOffsets", offsets);
        Check(latest.error_code == 0 && latest.offset == 3, "listOffsets");
        std::puts("TestKafkaNative OK");
    } catch (const std::exception& e) {
        std::fprintf(stderr, "TestKafkaNative FAIL: %s\n", e.what());
        return 1;
    }
    return 0;
}
