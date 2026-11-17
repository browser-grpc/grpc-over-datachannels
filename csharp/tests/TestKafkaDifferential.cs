using System.Security.Cryptography;
using System.Text;
using Grpcdc;
using Grpcdc.kafka.v1;

namespace Tests;

/// <summary>
/// Kafka differential (C#): transactional produce through
/// one form factor, read_committed consume through the other,
/// mirroring the Python/JS/Go/Dart differentials. Env-gated:
/// KAFKA_E2E_BROKER (native), KAFKA_E2E_PROXY_ADDR (proxy),
/// GRPC_DC_KAFKA_NATIVE_LIB. Skipped otherwise.
/// </summary>
public static class TestKafkaDifferential
{
    private static ProduceRequest TxnProduce(string topic, string label, string session) =>
        new(topic, 0,
            new List<Record>
            {
                new Record(null, Encoding.UTF8.GetBytes(label), new List<Header>(), 0, false),
            },
            Acks.ACKS_ALL, 0, Compression.COMPRESSION_NONE, session, "");

    public static void Run()
    {
        var broker = Environment.GetEnvironmentVariable("KAFKA_E2E_BROKER");
        var proxyAddr = Environment.GetEnvironmentVariable("KAFKA_E2E_PROXY_ADDR");
        var lib = Environment.GetEnvironmentVariable("GRPC_DC_KAFKA_NATIVE_LIB");
        if (string.IsNullOrEmpty(broker) || string.IsNullOrEmpty(proxyAddr) || string.IsNullOrEmpty(lib))
        {
            Console.WriteLine("TestKafkaDifferential SKIP (KAFKA_E2E_BROKER / KAFKA_E2E_PROXY_ADDR / GRPC_DC_KAFKA_NATIVE_LIB not set)");
            return;
        }
        using var native = new KafkaNativeClient(broker);
        var sep = proxyAddr.LastIndexOf(':');
        var proxy = new KafkaGrpcDc.KafkaClient(new Channel(
            SidecarTransport.Connect(proxyAddr[..sep], int.Parse(proxyAddr[(sep + 1)..]))));
        var topic = "csharp-kafka-diff-" +
            Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
        try
        {
            var created = native.CreateTopics(new CreateTopicsRequest(
                new List<NewTopic> { new NewTopic(topic, 1, 1) }, 15000, false));
            Program.Check(created.Results.Count == 1 && created.Results[0].ErrorCode == 0, "create topic");

            void TxnNative(string label, bool commit)
            {
                var opened = native.OpenProducer(new OpenProducerRequest("grpc-dc-csharp-diff-txn-" + label, 60000));
                Program.Check(opened.ErrorCode == 0, "native open producer " + opened.ErrorCode);
                var produced = native.Produce(TxnProduce(topic, label, opened.SessionId));
                Program.Check(produced.ErrorCode == 0, "native produce " + produced.ErrorCode);
                var ended = native.EndTransaction(new EndTransactionRequest(opened.SessionId, commit));
                Program.Check(ended.ErrorCode == 0, "native end txn " + ended.ErrorCode);
            }

            void TxnProxy(string label, bool commit)
            {
                var opened = proxy.OpenProducer(new OpenProducerRequest("grpc-dc-csharp-diff-txn-" + label, 60000));
                Program.Check(opened.ErrorCode == 0, "proxy open producer " + opened.ErrorCode);
                var produced = proxy.Produce(TxnProduce(topic, label, opened.SessionId));
                Program.Check(produced.ErrorCode == 0, "proxy produce " + produced.ErrorCode);
                var ended = proxy.EndTransaction(new EndTransactionRequest(opened.SessionId, commit));
                Program.Check(ended.ErrorCode == 0, "proxy end txn " + ended.ErrorCode);
            }

            List<string> ConsumeNativeCommitted(int want)
            {
                var deadline = DateTime.UtcNow.AddSeconds(20);
                while (DateTime.UtcNow < deadline)
                {
                    var values = new List<string>();
                    foreach (var chunk in native.Consume(new ConsumeRequest(topic, 0, -2, 10, 1000, 0, true)))
                    {
                        Program.Check(chunk.ErrorCode == 0, "native consume " + chunk.ErrorCode);
                        foreach (var r in chunk.Records) values.Add(Encoding.UTF8.GetString(r.Value));
                        if (values.Count >= want) break;
                    }
                    if (values.Count >= want) return values;
                    Thread.Sleep(250);
                }
                throw new Exception("native read_committed timed out (want " + want + ")");
            }

            List<string> ConsumeProxyCommitted(int want)
            {
                var deadline = DateTime.UtcNow.AddSeconds(20);
                while (DateTime.UtcNow < deadline)
                {
                    var values = new List<string>();
                    var stream = proxy.Consume(new ConsumeRequest(topic, 0, -2, 10, 1000, 0, true));
                    try
                    {
                        while (values.Count < want)
                        {
                            var chunk = stream.Recv();
                            Program.Check(chunk.ErrorCode == 0, "proxy consume " + chunk.ErrorCode);
                            foreach (var r in chunk.Records) values.Add(Encoding.UTF8.GetString(r.Value));
                        }
                    }
                    catch
                    {
                        // Stream closed at maxWaitMs; retry from -2.
                    }
                    if (values.Count >= want) return values;
                    Thread.Sleep(250);
                }
                throw new Exception("proxy read_committed timed out (want " + want + ")");
            }

            // Proxy transacts, native reads committed; then swapped.
            TxnProxy("tx-proxy-commit", true);
            TxnProxy("tx-proxy-abort", false);
            var got = ConsumeNativeCommitted(1);
            Program.Check(got.Count == 1 && got[0] == "tx-proxy-commit",
                "native read_committed: " + string.Join(",", got));
            TxnNative("tx-native-commit", true);
            TxnNative("tx-native-abort", false);
            got = ConsumeProxyCommitted(2);
            Program.Check(got.Count == 2 && got[0] == "tx-proxy-commit" && got[1] == "tx-native-commit",
                "proxy read_committed: " + string.Join(",", got));
        }
        finally
        {
            try
            {
                native.DeleteTopics(new DeleteTopicsRequest(new List<string> { topic }, 15000));
            }
            catch
            {
                // best effort cleanup
            }
        }
    }
}
