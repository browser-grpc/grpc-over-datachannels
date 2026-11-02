using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Echo;
using Grpcdc;

namespace Consumer
{
    /// <summary>
    /// A consumer-owned transport, written the way a Unity / .NET
    /// Framework consumer must write one against netstandard2.0:
    /// Send/Recv/Close all implemented explicitly (there is no
    /// default interface Close() off net8). Cross-wired blocking
    /// queues stand in for a DataChannel pair.
    /// </summary>
    public sealed class QueueTransport : ITransport
    {
        private readonly System.Collections.Concurrent.BlockingCollection<byte[]> _inbox;
        private readonly System.Collections.Concurrent.BlockingCollection<byte[]> _outbox;

        private QueueTransport(
            System.Collections.Concurrent.BlockingCollection<byte[]> inbox,
            System.Collections.Concurrent.BlockingCollection<byte[]> outbox)
        {
            _inbox = inbox;
            _outbox = outbox;
        }

        public static (QueueTransport, QueueTransport) Pair()
        {
            var a = new System.Collections.Concurrent.BlockingCollection<byte[]>();
            var b = new System.Collections.Concurrent.BlockingCollection<byte[]>();
            return (new QueueTransport(a, b), new QueueTransport(b, a));
        }

        public void Send(byte[] data) => _outbox.Add(data);

        public byte[] Recv()
        {
            try
            {
                return _inbox.Take();
            }
            catch (InvalidOperationException)
            {
                throw new EndOfStreamException("transport closed");
            }
        }

        public void Close() => _outbox.CompleteAdding();
    }

    /// <summary>
    /// Exercises the netstandard2.0 surface end to end: unary call
    /// over a consumer transport, server-streaming via
    /// IAsyncEnumerable (the Bcl.AsyncInterfaces + Channels compat
    /// path), and a Codec headers round-trip (System.Text.Json).
    /// Throws on any mismatch; returns a summary line on success.
    /// </summary>
    public static class ConsumerSmoke
    {
        private static void Check(bool condition, string what)
        {
            if (!condition)
            {
                throw new Exception("consumer smoke failed: " + what);
            }
        }

        public static string Run()
        {
            (QueueTransport a, QueueTransport b) = QueueTransport.Pair();
            var server = new Server();
            EchoGrpcDc.RegisterEchoServer(server, new EchoServiceImpl());
            server.ServeTransport(b);
            var client = new EchoGrpcDc.EchoClient(new Channel(a));

            EchoResponse unary = client.Unary(new EchoRequest("hello", 0, 0));
            Check(unary.Message == "echo: hello" && unary.Index == 0, "unary " + unary);

            List<int> indexes = RunAsyncStream(client).GetAwaiter().GetResult();
            Check(indexes.Count == 3 && indexes[0] == 0 && indexes[1] == 1 && indexes[2] == 2,
                "async stream indexes " + string.Join(",", indexes));

            byte[] headers = Codec.HeadersFrame(7, "/echo.Echo/Unary",
                new Dictionary<string, string> { { "x-smoke", "netstandard2.0" } });
            Codec.Frame frame = Codec.DecodeFrame(headers);
            Codec.Headers parsed = Codec.ParseHeaders(frame.Payload);
            Check(parsed.Path == "/echo.Echo/Unary", "headers path " + parsed.Path);

            a.Close();
            b.Close();
            return "unary+async-stream+codec ok";
        }

        private static async Task<List<int>> RunAsyncStream(EchoGrpcDc.EchoClient client)
        {
            var indexes = new List<int>();
            await foreach (EchoResponse resp in client.ServerStreamAsync(new EchoRequest("tick", 3, 0)))
            {
                Check(resp.Message == "tick", "stream message " + resp);
                indexes.Add(resp.Index);
            }
            return indexes;
        }
    }
}
