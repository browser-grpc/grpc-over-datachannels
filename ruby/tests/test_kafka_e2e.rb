# Kafka proxy end-to-end: generated Ruby client -> Rust
# kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
#
# Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
# kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
# Skipped otherwise, so the plain `make test-ruby` run stays
# broker-free.

require "grpcdc"
require "securerandom"
require_relative "test_util"

module TestKafkaE2E
  def self.run
    addr = ENV["KAFKA_E2E_PROXY_ADDR"]
    if addr.nil? || addr.empty?
      puts "TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)"
      return
    end
    require "grpcdc/kafka_grpc_dc"
    require "grpcdc/kafka_pb"

    host, _, port = addr.rpartition(":")
    client = KafkaGrpcDc::KafkaClient.new(
      Grpcdc::Channel.new(Grpcdc::SidecarTransport.connect(host, port.to_i))
    )

    with_topic = lambda do |&block|
      topic = "rb-kafka-e2e-#{SecureRandom.hex(8)}"
      begin
        created = client.CreateTopics(KafkaPb::CreateTopicsRequest.new(
          topics: [KafkaPb::NewTopic.new(name: topic, num_partitions: 1, replication_factor: 1)],
          timeout_ms: 15_000
        ))
        TestUtil.assert_eq(created.results.map(&:error_code), [0], "create topic")
        deadline = Time.now + 15
        loop do
          latest = client.ListOffsets(KafkaPb::ListOffsetsRequest.new(topic: topic, partition: 0, timestamp: -1))
          break if latest.error_code.zero?
          raise "topic not visible" if Time.now > deadline

          sleep 0.25
        end
        block.call(topic)
      ensure
        begin
          client.DeleteTopics(KafkaPb::DeleteTopicsRequest.new(topics: [topic]))
        rescue StandardError
          # best effort
        end
      end
    end

    produce = lambda do |topic, values|
      values.map do |value|
        resp = client.Produce(KafkaPb::ProduceRequest.new(
          topic: topic, partition: 0,
          records: [KafkaPb::Record.new(key: "k-#{value}".b, value: value.b)]
        ))
        TestUtil.assert_eq(resp.error_code, 0, "produce error")
        resp.base_offset
      end
    end
    consume = lambda do |topic, offset, count|
      got = []
      client.Consume(KafkaPb::ConsumeRequest.new(topic: topic, partition: 0, offset: offset, max_records: count)).each do |chunk|
        TestUtil.assert_eq(chunk.error_code, 0, "consume error")
        got.concat(chunk.records)
        break if got.length >= count
      end
      got
    end

    with_topic.call do |topic|
      TestUtil.assert_eq(produce.call(topic, %w[v0 v1 v2]), [0, 1, 2], "roundtrip offsets")
      latest = client.ListOffsets(KafkaPb::ListOffsetsRequest.new(topic: topic, partition: 0, timestamp: -1))
      TestUtil.assert_eq([latest.offset, latest.error_code], [3, 0], "latest offset")
      got = consume.call(topic, 0, 3)
      TestUtil.assert_eq(got.map(&:value), %w[v0 v1 v2], "roundtrip values")
      TestUtil.assert_eq(got.map(&:key), %w[k-v0 k-v1 k-v2], "roundtrip keys")
    end

    with_topic.call do |topic|
      values = (0...10).map { |i| format("seq-%02d", i) }
      TestUtil.assert_eq(produce.call(topic, values), (0...10).to_a, "ordering offsets")
      TestUtil.assert_eq(consume.call(topic, 0, 10).map(&:value), values, "ordering values")
    end

    with_topic.call do |topic|
      produce.call(topic, %w[a b c d])
      TestUtil.assert_eq(consume.call(topic, 0, 2).map(&:value), %w[a b], "resume first")
      TestUtil.assert_eq(consume.call(topic, 2, 2).map(&:value), %w[c d], "resume rest")
    end
    puts "TestKafkaE2E OK"
  end
end
