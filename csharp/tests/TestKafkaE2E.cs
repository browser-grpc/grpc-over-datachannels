using System.Security.Cryptography;
using System.Text;
using Grpcdc;
using Grpcdc.kafka.v1;

namespace Tests;

/// <summary>
/// Kafka proxy end-to-end: generated C# client -&gt; Rust
/// kafka_proxy (--tcp) -&gt; Apache Kafka / Redpanda.
///
/// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
/// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
/// Skipped otherwise, so the plain `make test-csharp` run stays
/// broker-free.
/// </summary>
public static class TestKafkaE2E
{
    private static string CreateTopic(KafkaGrpcDc.KafkaClient client)
    {
        var suffix = Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
        var topic = "csharp-kafka-e2e-" + suffix;
        var created = client.CreateTopics(new CreateTopicsRequest(
            new List<NewTopic> { new NewTopic(topic, 1, 1) }, 15000, false));
        Program.Check(created.Results.Count == 1 && created.Results[0].ErrorCode == 0, "create topic");
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (true)
        {
            var latest = client.ListOffsets(new ListOffsetsRequest(topic, 0, -1, false));
            if (latest.ErrorCode == 0)
            {
                return topic;
            }
            Program.Check(DateTime.UtcNow < deadline, "topic not visible");
            Thread.Sleep(250);
        }
    }

    private static List<long> Produce(KafkaGrpcDc.KafkaClient client, string topic, List<string> values)
    {
        var offsets = new List<long>();
        foreach (var value in values)
        {
            var resp = client.Produce(new ProduceRequest(
                topic, 0,
                new List<Record>
                {
                    new Record(Encoding.UTF8.GetBytes("k-" + value), Encoding.UTF8.GetBytes(value),
                        new List<Header>(), 0, false),
                },
                Acks.ACKS_UNSPECIFIED, 0, Compression.COMPRESSION_NONE, "", ""));
            Program.Check(resp.ErrorCode == 0, "produce error " + resp.ErrorCode);
            offsets.Add(resp.BaseOffset);
        }
        return offsets;
    }

    private static List<FetchedRecord> Consume(KafkaGrpcDc.KafkaClient client, string topic, long offset, int count)
    {
        var got = new List<FetchedRecord>();
        using (var stream = client.Consume(new ConsumeRequest(topic, 0, offset, count, 0, 0, false)))
        {
            while (got.Count < count)
            {
                var chunk = stream.Recv();
                Program.Check(chunk.ErrorCode == 0, "consume error " + chunk.ErrorCode);
                got.AddRange(chunk.Records);
            }
        }
        return got;
    }

    private static List<string> Values(List<FetchedRecord> records) =>
        records.Select(r => Encoding.UTF8.GetString(r.Value)).ToList();

    public static void Run()
    {
        var addr = Environment.GetEnvironmentVariable("KAFKA_E2E_PROXY_ADDR");
        if (string.IsNullOrEmpty(addr))
        {
            Console.WriteLine("TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)");
            return;
        }
        var sep = addr.LastIndexOf(':');
        var client = new KafkaGrpcDc.KafkaClient(new Channel(
            SidecarTransport.Connect(addr[..sep], int.Parse(addr[(sep + 1)..]))));

        var topic = CreateTopic(client);
        try
        {
            Program.Check(Produce(client, topic, new List<string> { "v0", "v1", "v2" })
                .SequenceEqual(new List<long> { 0, 1, 2 }), "roundtrip offsets");
            var latest = client.ListOffsets(new ListOffsetsRequest(topic, 0, -1, false));
            Program.Check(latest.Offset == 3 && latest.ErrorCode == 0, "latest offset");
            var got = Consume(client, topic, 0, 3);
            Program.Check(Values(got).SequenceEqual(new[] { "v0", "v1", "v2" }), "roundtrip values");
            Program.Check(got.Select(r => Encoding.UTF8.GetString(r.Key))
                .SequenceEqual(new[] { "k-v0", "k-v1", "k-v2" }), "roundtrip keys");
        }
        finally
        {
            client.DeleteTopics(new DeleteTopicsRequest(new List<string> { topic }, 0));
        }

        topic = CreateTopic(client);
        try
        {
            var want = Enumerable.Range(0, 10).Select(i => $"seq-{i:00}").ToList();
            Program.Check(Produce(client, topic, want)
                .SequenceEqual(Enumerable.Range(0, 10).Select(i => (long)i)), "ordering offsets");
            Program.Check(Values(Consume(client, topic, 0, 10)).SequenceEqual(want), "ordering values");
        }
        finally
        {
            client.DeleteTopics(new DeleteTopicsRequest(new List<string> { topic }, 0));
        }

        topic = CreateTopic(client);
        try
        {
            Produce(client, topic, new List<string> { "a", "b", "c", "d" });
            Program.Check(Values(Consume(client, topic, 0, 2)).SequenceEqual(new[] { "a", "b" }), "resume first");
            Program.Check(Values(Consume(client, topic, 2, 2)).SequenceEqual(new[] { "c", "d" }), "resume rest");
        }
        finally
        {
            client.DeleteTopics(new DeleteTopicsRequest(new List<string> { topic }, 0));
        }
        Console.WriteLine("TestKafkaE2E OK");
    }
}
