// Kafka proxy end-to-end: generated C++ client -> Rust
// kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise, so the plain `make test-cpp` run stays
// broker-free.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "examples/kafka_grpc_dc.hpp"
#include "examples/kafka_messages.hpp"
#include "grpcdc/channel.hpp"
#include "grpcdc/sidecar_transport.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

using namespace grpcdc::kafka::v1;

std::vector<std::uint8_t> Bytes(const std::string& s) {
  return std::vector<std::uint8_t>(s.begin(), s.end());
}

std::string Str(const std::vector<std::uint8_t>& b) {
  return std::string(b.begin(), b.end());
}

std::string CreateTopic(KafkaGrpcDc::KafkaClient& client) {
  std::random_device rd;
  char suffix[17];
  std::snprintf(suffix, sizeof(suffix), "%08x%08x", rd(), rd());
  std::string topic = std::string("cpp-kafka-e2e-") + suffix;
  CreateTopicsRequest req;
  NewTopic spec;
  spec.name = topic;
  spec.num_partitions = 1;
  spec.replication_factor = 1;
  req.topics = {spec};
  req.timeout_ms = 15000;
  CreateTopicsResponse created = client.CreateTopics(req);
  Check(created.results.size() == 1 && created.results[0].error_code == 0,
        "create topic");
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  while (true) {
    ListOffsetsRequest latest_req;
    latest_req.topic = topic;
    latest_req.partition = 0;
    latest_req.timestamp = -1;
    ListOffsetsResponse latest = client.ListOffsets(latest_req);
    if (latest.error_code == 0) return topic;
    Check(std::chrono::steady_clock::now() < deadline, "topic not visible");
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
  }
}

std::vector<std::int64_t> Produce(KafkaGrpcDc::KafkaClient& client, const std::string& topic,
                                  const std::vector<std::string>& values) {
  std::vector<std::int64_t> offsets;
  for (const std::string& value : values) {
    ProduceRequest req;
    req.topic = topic;
    req.partition = 0;
    Record rec;
    rec.key = Bytes("k-" + value);
    rec.value = Bytes(value);
    req.records = {rec};
    ProduceResponse resp = client.Produce(req);
    Check(resp.error_code == 0, "produce error");
    offsets.push_back(resp.base_offset);
  }
  return offsets;
}

std::vector<FetchedRecord> Consume(KafkaGrpcDc::KafkaClient& client, const std::string& topic,
                                   std::int64_t offset, std::int32_t count) {
  ConsumeRequest req;
  req.topic = topic;
  req.partition = 0;
  req.offset = offset;
  req.max_records = count;
  std::vector<FetchedRecord> got;
  auto stream = client.Consume(req);
  while (static_cast<std::int32_t>(got.size()) < count) {
    ConsumeResponse chunk = stream.Recv();
    Check(chunk.error_code == 0, "consume error");
    got.insert(got.end(), chunk.records.begin(), chunk.records.end());
  }
  stream.Cancel();
  return got;
}

std::vector<std::string> Values(const std::vector<FetchedRecord>& records) {
  std::vector<std::string> out;
  for (const FetchedRecord& r : records) out.push_back(Str(r.value));
  return out;
}

void DeleteTopic(KafkaGrpcDc::KafkaClient& client, const std::string& topic) {
  DeleteTopicsRequest req;
  req.topics = {topic};
  client.DeleteTopics(req);
}

}  // namespace

void TestKafkaE2E() {
  const char* addr = std::getenv("KAFKA_E2E_PROXY_ADDR");
  if (addr == nullptr || std::string(addr).empty()) {
    std::printf("TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)\n");
    return;
  }
  std::string host_port = addr;
  size_t sep = host_port.rfind(':');
  KafkaGrpcDc::KafkaClient client(std::make_shared<grpcdc::Channel>(
      grpcdc::SidecarTransport::Connect(host_port.substr(0, sep),
                                        std::stoi(host_port.substr(sep + 1)))));

  std::string topic = CreateTopic(client);
  Check(Produce(client, topic, {"v0", "v1", "v2"}) ==
            std::vector<std::int64_t>({0, 1, 2}),
        "roundtrip offsets");
  {
    ListOffsetsRequest req;
    req.topic = topic;
    req.partition = 0;
    req.timestamp = -1;
    ListOffsetsResponse latest = client.ListOffsets(req);
    Check(latest.offset == 3 && latest.error_code == 0, "latest offset");
  }
  std::vector<FetchedRecord> got = Consume(client, topic, 0, 3);
  Check(Values(got) == std::vector<std::string>({"v0", "v1", "v2"}),
        "roundtrip values");
  Check(got.size() == 3 && Str(got[0].key) == "k-v0" && Str(got[2].key) == "k-v2",
        "roundtrip keys");
  DeleteTopic(client, topic);

  topic = CreateTopic(client);
  std::vector<std::string> want;
  std::vector<std::int64_t> want_offsets;
  for (int i = 0; i < 10; ++i) {
    char buf[16];
    std::snprintf(buf, sizeof(buf), "seq-%02d", i);
    want.emplace_back(buf);
    want_offsets.push_back(i);
  }
  Check(Produce(client, topic, want) == want_offsets, "ordering offsets");
  Check(Values(Consume(client, topic, 0, 10)) == want, "ordering values");
  DeleteTopic(client, topic);

  topic = CreateTopic(client);
  Produce(client, topic, {"a", "b", "c", "d"});
  Check(Values(Consume(client, topic, 0, 2)) ==
            std::vector<std::string>({"a", "b"}),
        "resume first");
  Check(Values(Consume(client, topic, 2, 2)) ==
            std::vector<std::string>({"c", "d"}),
        "resume rest");
  DeleteTopic(client, topic);
  std::printf("TestKafkaE2E OK\n");
}

}  // namespace tests
