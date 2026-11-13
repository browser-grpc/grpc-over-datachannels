using System.Security.Cryptography;
using System.Text;
using Grpcdc;
using Grpcdc.kafka.v1;

namespace Tests;

/// <summary>
/// KIP-932 share groups: generated C# client -&gt; Rust
/// kafka_proxy (--tcp) -&gt; Apache Kafka. ACCEPT retires,
/// RELEASE redelivers with DeliveryCount incremented.
///
/// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
/// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
/// Brokers that cannot run share state skip: Redpanda refuses
/// the open, and a combined-mode SASL fixture cannot
/// initialize the share persister (the reference share
/// consumer stalls identically there). Delivery failures
/// WITH an assignment still fail.
/// </summary>
public static class TestKafkaShareE2E
{
    private static List<SharePollRecord> Poll(
        KafkaGrpcDc.KafkaClient client, string session, int want)
    {
        var outList = new List<SharePollRecord>();
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (outList.Count < want && DateTime.UtcNow < deadline)
        {
            var resp = client.SharePoll(new SharePollRequest(session, 10, 500));
            Program.Check(resp.ErrorCode == 0, "share poll error " + resp.ErrorCode);
            outList.AddRange(resp.Records);
            if (outList.Count == 0)
            {
                Thread.Sleep(200);
            }
        }
        return outList;
    }

    private static void ProduceOne(KafkaGrpcDc.KafkaClient client, string topic, string value)
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
    }

    public static void Run()
    {
        var addr = Environment.GetEnvironmentVariable("KAFKA_E2E_PROXY_ADDR");
        if (string.IsNullOrEmpty(addr))
        {
            Console.WriteLine("TestKafkaShareE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)");
            return;
        }
        var sep = addr.LastIndexOf(':');
        var client = new KafkaGrpcDc.KafkaClient(new Channel(
            SidecarTransport.Connect(addr[..sep], int.Parse(addr[(sep + 1)..]))));

        var suffix = Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
        var topic = "csharp-share-e2e-" + suffix;
        var group = "csharp-share-group-" + suffix;
        var created = client.CreateTopics(new CreateTopicsRequest(
            new List<NewTopic> { new NewTopic(topic, 1, 1) }, 15000, false));
        Program.Check(created.Results.Count == 1 && created.Results[0].ErrorCode == 0,
            "create topic");
        try
        {
            OpenShareGroupResponse opened;
            try
            {
                opened = client.OpenShareGroup(new OpenShareGroupRequest(
                    group, new List<string> { topic }, "", 0));
            }
            catch (Exception e)
            {
                Console.WriteLine($"TestKafkaShareE2E SKIP (share open raised: {e.Message})");
                return;
            }
            if (opened.ErrorCode != 0)
            {
                Console.WriteLine(
                    $"TestKafkaShareE2E SKIP (broker refused share group, error {opened.ErrorCode})");
                return;
            }
            var session = opened.SessionId;
            Program.Check(session.Length > 0, "empty share session");
            // Assignment settles asynchronously (bounded in the
            // service); it may still be empty here. Delivery
            // below proves it arrived.
            var assignmentEmpty = opened.Assignment == null
                || opened.Assignment.Partitions.Count == 0;

            // A share partition's start offset is taken at its
            // first fetch; initialize it before producing.
            var init = client.SharePoll(new SharePollRequest(session, 10, 500));
            Program.Check(init.ErrorCode == 0 && init.Records.Count == 0, "init poll");

            ProduceOne(client, topic, "s1");
            ProduceOne(client, topic, "s2");
            var first = Poll(client, session, 2);
            if (first.Count == 0 && assignmentEmpty)
            {
                Console.WriteLine(
                    "TestKafkaShareE2E SKIP (share assignment never delivered on this broker)");
                return;
            }
            Program.Check(first.Count == 2, "share delivery timed out");
            Program.Check(first.Select(r => Encoding.UTF8.GetString(r.Value))
                .SequenceEqual(new[] { "s1", "s2" }), "first values");
            Program.Check(first.All(r => r.DeliveryCount == 1), "first deliveryCount");

            var acked = client.ShareAck(new ShareAckRequest(session,
                first.Select(r => new ShareAckEntry(topic, 0, r.Offset, 1)).ToList()));
            Program.Check(acked.ErrorCode == 0, "accept error " + acked.ErrorCode);
            var empty = client.SharePoll(new SharePollRequest(session, 10, 500));
            Program.Check(empty.ErrorCode == 0 && empty.Records.Count == 0,
                "poll after accept not empty");

            ProduceOne(client, topic, "s3");
            var third = Poll(client, session, 1);
            Program.Check(third.Count == 1, "share delivery of s3 timed out");
            Program.Check(third[0].DeliveryCount == 1, "s3 deliveryCount");
            var released = client.ShareAck(new ShareAckRequest(session,
                new List<ShareAckEntry> { new ShareAckEntry(topic, 0, third[0].Offset, 2) }));
            Program.Check(released.ErrorCode == 0, "release error " + released.ErrorCode);
            var redelivered = Poll(client, session, 1);
            Program.Check(redelivered.Count == 1, "release redelivery timed out");
            Program.Check(redelivered[0].Offset == third[0].Offset, "redelivered offset");
            Program.Check(redelivered[0].DeliveryCount == 2,
                "RELEASE must bump deliveryCount: " + redelivered[0].DeliveryCount);

            var closed = client.CloseShareGroup(new CloseShareGroupRequest(session));
            Program.Check(closed.ErrorCode == 0, "close error " + closed.ErrorCode);
            Console.WriteLine("TestKafkaShareE2E OK");
        }
        finally
        {
            client.DeleteTopics(new DeleteTopicsRequest(new List<string> { topic }, 0));
        }
    }
}
