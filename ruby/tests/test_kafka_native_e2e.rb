# Kafka native end-to-end: generated Ruby client classes ->
# libkafka_native in-process (no proxy, no gRPC hop).
#
# Env-gated: set KAFKA_E2E_BROKER=host:port of a broker and
# GRPC_DC_KAFKA_NATIVE_LIB=path/to/libkafka_native.so.
# Skipped otherwise.

require "grpcdc"
require "securerandom"
require_relative "test_util"

module TestKafkaNative
  def self.run
    broker = ENV["KAFKA_E2E_BROKER"]
    lib = ENV["GRPC_DC_KAFKA_NATIVE_LIB"]
    if broker.nil? || broker.empty? || lib.nil? || lib.empty?
      puts "TestKafkaNative SKIP (KAFKA_E2E_BROKER / GRPC_DC_KAFKA_NATIVE_LIB not set)"
      return
    end
    require "grpcdc/kafka_grpc_dc"
    require "grpcdc/kafka_pb"
    require "grpcdc/kafka_native"

    client = Grpcdc::KafkaNativeClient.new(broker)
    topic = "rb-kafka-native-#{SecureRandom.hex(8)}"
    begin
      created = client.CreateTopics(KafkaPb::CreateTopicsRequest.new(
        topics: [KafkaPb::NewTopic.new(name: topic, num_partitions: 1, replication_factor: 1)],
        timeout_ms: 15_000
      ))
      TestUtil.assert_eq(created.results.map(&:error_code), [0], "create topic")

      deadline = Time.now + 15
      loop do
        meta = client.Metadata(KafkaPb::MetadataRequest.new(topics: [topic]))
        found = meta.topics.find { |t| t.name == topic }
        break if found && !found.partitions.empty?
        raise "topic not visible" if Time.now > deadline

        sleep 0.25
      end

      produced = client.Produce(KafkaPb::ProduceRequest.new(
        topic: topic, partition: 0,
        records: [KafkaPb::Record.new(value: "one".b),
                  KafkaPb::Record.new(value: "two".b),
                  KafkaPb::Record.new(value: "three".b)]
      ))
      TestUtil.assert_eq(produced.error_code, 0, "produce")

      values = []
      stream = client.Consume(KafkaPb::ConsumeRequest.new(
        topic: topic, partition: 0, offset: -2, max_records: 10, max_wait_ms: 2_000))
      begin
        stream.each do |chunk|
          TestUtil.assert_eq(chunk.error_code, 0, "consume error")
          chunk.records.each { |r| values << r.value }
          break if values.length >= 3
        end
      ensure
        stream.close
      end
      TestUtil.assert_eq(values, ["one".b, "two".b, "three".b], "roundtrip values")

      latest = client.ListOffsets(KafkaPb::ListOffsetsRequest.new(topic: topic, partition: 0, timestamp: -1))
      TestUtil.assert_eq([latest.offset, latest.error_code], [3, 0], "latest offset")
      puts "TestKafkaNative OK"
    ensure
      begin
        client.DeleteTopics(KafkaPb::DeleteTopicsRequest.new(topics: [topic]))
      rescue StandardError
        # best effort
      end
      client.close
    end
  end
end
