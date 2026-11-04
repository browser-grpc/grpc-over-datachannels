using System;
using Grpcdc;
using Grpcdc.kafka.v1;

namespace Consumer
{
    /// <summary>
    /// Compile-and-load check for the KafkaGrpc package: touching
    /// the client and a message type must resolve unambiguously
    /// (this is what CS0433 broke in v0.37.0), and the client must
    /// construct over a consumer transport. Returns the owning
    /// assembly name so the host can assert the split.
    /// </summary>
    public static class KafkaUse
    {
        public static string Check()
        {
            (ITransport a, ITransport b) = MemoryTransport.Pair();
            var client = new KafkaGrpcDc.KafkaClient(new Channel(a));
            var req = new MetadataRequest(new System.Collections.Generic.List<string> { "smoke" }, false);
            if (client == null || req.Topics.Count != 1 || req.Topics[0] != "smoke")
            {
                throw new Exception("kafka consumer check failed");
            }
            a.Close();
            b.Close();
            return typeof(KafkaGrpcDc.KafkaClient).Assembly.GetName().Name;
        }
    }
}
