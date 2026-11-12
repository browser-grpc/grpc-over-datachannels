using System.Security.Cryptography;
using System.Text;
using Grpcdc;
using Grpcdc.kafka.v1;

namespace Tests;

/// <summary>
/// Kafka native end-to-end: generated C# messages ->
/// libkafka_native in-process (no proxy, no gRPC hop).
/// Env-gated: KAFKA_E2E_BROKER=host:port of a broker and
/// GRPC_DC_KAFKA_NATIVE_LIB=path/to/libkafka_native.so.
/// </summary>
public static class TestKafkaNative
{
    public static void Run()
    {
        var broker = Environment.GetEnvironmentVariable("KAFKA_E2E_BROKER");
        var lib = Environment.GetEnvironmentVariable("GRPC_DC_KAFKA_NATIVE_LIB");
        if (string.IsNullOrEmpty(broker) || string.IsNullOrEmpty(lib))
        {
            Console.WriteLine("TestKafkaNative SKIP (KAFKA_E2E_BROKER / GRPC_DC_KAFKA_NATIVE_LIB not set)");
            return;
        }
        using var client = new KafkaNativeClient(broker);
        var topic = "csharp-kafka-native-" +
            Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
        try
        {
            var created = client.CreateTopics(new CreateTopicsRequest(
                new List<NewTopic> { new NewTopic(topic, 1, 1) }, 15000, false));
            Program.Check(created.Results.Count == 1 && created.Results[0].ErrorCode == 0, "create topic");

            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (true)
            {
                var meta = client.Metadata(new MetadataRequest(new List<string> { topic }, false));
                var found = meta.Topics.Find(t => t.Name == topic);
                if (found != null && found.Partitions.Count > 0) break;
                Program.Check(DateTime.UtcNow < deadline, "topic not visible");
                Thread.Sleep(250);
            }

            var produced = client.Produce(new ProduceRequest(
                topic, 0,
                new List<Record>
                {
                    new Record(null, Encoding.UTF8.GetBytes("one"), new List<Header>(), 0, false),
                    new Record(null, Encoding.UTF8.GetBytes("two"), new List<Header>(), 0, false),
                    new Record(null, Encoding.UTF8.GetBytes("three"), new List<Header>(), 0, false),
                },
                Acks.ACKS_ALL, 0, Compression.COMPRESSION_NONE, "", ""));
            Program.Check(produced.ErrorCode == 0, "produce error " + produced.ErrorCode);

            var values = new List<string>();
            foreach (var chunk in client.Consume(new ConsumeRequest(topic, 0, -2, 10, 2000, 0, false)))
            {
                Program.Check(chunk.ErrorCode == 0, "consume error " + chunk.ErrorCode);
                foreach (var r in chunk.Records) values.Add(Encoding.UTF8.GetString(r.Value));
                if (values.Count >= 3) break;
            }
            Program.Check(string.Join(",", values) == "one,two,three", "values " + string.Join(",", values));

            var latest = client.ListOffsets(new ListOffsetsRequest(topic, 0, -1, false));
            Program.Check(latest.ErrorCode == 0 && latest.Offset == 3, "listOffsets");
            Console.WriteLine("TestKafkaNative OK");
        }
        finally
        {
            try
            {
                client.DeleteTopics(new DeleteTopicsRequest(new List<string> { topic }, 15000));
            }
            catch (KafkaNativeException)
            {
                // best effort
            }
        }
    }
}
