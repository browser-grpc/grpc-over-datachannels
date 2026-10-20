#lang racket

;;; runtime-csharp.rkt — the C# gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under csharp/grpcdc/ are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)
;;;
;;; .NET 8, base class library only — no external packages.

(require "spec.rkt")
(provide emit-csharp-runtime-files)

(define csharp-status-body
#<<GRPC_RUNTIME_EOF
namespace Grpcdc;

/// <summary>A gRPC status (code + message) carried as an exception.</summary>
public class StatusException : Exception
{
    public int Code { get; }

    public StatusException(int code, string message) : base(message)
    {
        Code = code;
    }

    public override string ToString() => $"{Wire.StatusName(Code)}: {Message}";

    /// <summary>Convert any exception to a StatusException (OK for null).</summary>
    public static StatusException ToStatus(Exception err)
    {
        if (err == null)
        {
            return new StatusException(Wire.CodeOk, "");
        }
        if (err is StatusException se)
        {
            return se;
        }
        return new StatusException(Wire.CodeInternal, err.Message);
    }
}

/// <summary>
/// Homegrown tracing: W3C traceparent propagation with a span
/// observer. Dormant until Tracing.SetTracer registers one;
/// generated code stays dependency-free (sampling and export are
/// the application's problem).
/// </summary>
public static class Tracing
{
    /// <summary>Span observer callbacks (kind is "client" or "server").</summary>
    public interface ITracer
    {
        void OnStart(string kind, string method, string traceId, string spanId, string parentSpanId);
        void OnEnd(string kind, string method, string traceId, string spanId, string status);
    }

    /// <summary>One in-flight span's context.</summary>
    public sealed record TraceContext(string TraceId, string SpanId, string ParentSpanId);

    /// <summary>Parsed traceparent parent.</summary>
    public sealed record Parent(string TraceId, string SpanId);

    private static volatile ITracer _tracer;

    public static void SetTracer(ITracer tracer) => _tracer = tracer;

    private static volatile string[] _traceFilter = new string[0];

    // Restrict traced methods: ';'-separated paths, a trailing
    // '*' means prefix match ('/echo.Echo/*'). Empty = trace all.
    public static void SetTraceFilter(string patterns)
    {
        _traceFilter = patterns.Split(';', System.StringSplitOptions.RemoveEmptyEntries);
    }

    public static bool TraceAllowed(string method)
    {
        foreach (string p in _traceFilter)
        {
            if (p.EndsWith("*"))
            {
                if (method.StartsWith(p.Substring(0, p.Length - 1)))
                {
                    return true;
                }
            }
            else if (method == p)
            {
                return true;
            }
        }
        return _traceFilter.Length == 0;
    }

    public static bool Enabled => _tracer != null;

    public static string FormatTraceparent(string traceId, string spanId) =>
        $"00-{traceId}-{spanId}-01";

    public static Parent ParseTraceparent(string value)
    {
        if (value == null)
        {
            return null;
        }
        string[] parts = value.Split('-');
        if (parts.Length != 4 || parts[1].Length != 32 || parts[2].Length != 16)
        {
            return null;
        }
        foreach (char c in parts[1] + parts[2])
        {
            bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            if (!hex)
            {
                return null;
            }
        }
        return new Parent(parts[1], parts[2]);
    }

    private static string RandomHex(int bytes)
    {
        byte[] buf = new byte[bytes];
        System.Security.Cryptography.RandomNumberGenerator.Fill(buf);
        return Convert.ToHexString(buf).ToLowerInvariant();
    }

    public static TraceContext TraceStart(string kind, string method, Parent parent)
    {
        ITracer tracer = _tracer;
        if (tracer == null || !TraceAllowed(method))
        {
            return null;
        }
        var ctx = new TraceContext(
            parent != null ? parent.TraceId : RandomHex(16),
            RandomHex(8),
            parent != null ? parent.SpanId : "");
        try
        {
            tracer.OnStart(kind, method, ctx.TraceId, ctx.SpanId, ctx.ParentSpanId);
        }
        catch
        {
            // observers must never break the call
        }
        return ctx;
    }

    public static void TraceEnd(string kind, string method, TraceContext ctx, string status)
    {
        ITracer tracer = _tracer;
        if (ctx == null || tracer == null)
        {
            return;
        }
        try
        {
            tracer.OnEnd(kind, method, ctx.TraceId, ctx.SpanId, status);
        }
        catch
        {
            // observers must never break the call
        }
    }
}
GRPC_RUNTIME_EOF
)

(define csharp-codec-body
#<<GRPC_RUNTIME_EOF
using System.Text;
using System.Text.Json;

namespace Grpcdc;

/// <summary>
/// Frame codec for gRPC over WebRTC DataChannels (wire protocol in
/// ../SPEC.md). Frame, status, channel and server semantics mirror the
/// Rust, JavaScript, Go, Python and Java runtimes; the tables in
/// Wire.cs are stamped by the Racket metaprogram.
/// </summary>
public static class Codec
{
    public const int HeaderLen = 9;
    public const int MaxDataPayload = 16 * 1024 * 1024;

    /// <summary>One parsed frame.</summary>
    public sealed class Frame
    {
        public int Type { get; }
        public uint StreamId { get; }
        public byte[] Payload { get; }

        public Frame(int type, uint streamId, byte[] payload)
        {
            Type = type;
            StreamId = streamId;
            Payload = payload;
        }
    }

    /// <summary>Build one DataChannel message: header + payload.</summary>
    public static byte[] EncodeFrame(int frameType, uint streamId, byte[] payload)
    {
        if (!Wire.IsFrameType(frameType))
        {
            throw new StatusException(Wire.CodeInvalidArgument, $"unknown frame type {frameType}");
        }
        if (frameType == Wire.FrameData && payload.Length > MaxDataPayload)
        {
            throw new StatusException(Wire.CodeResourceExhausted, "DATA payload exceeds 16 MiB");
        }
        byte[] output = new byte[HeaderLen + payload.Length];
        output[0] = (byte)frameType;
        PutU32(output, 1, streamId);
        PutU32(output, 5, (uint)payload.Length);
        Array.Copy(payload, 0, output, HeaderLen, payload.Length);
        return output;
    }

    /// <summary>Parse one DataChannel message.</summary>
    public static Frame DecodeFrame(byte[] data)
    {
        if (data.Length < HeaderLen)
        {
            throw new StatusException(Wire.CodeInvalidArgument,
                $"frame shorter than 9-byte header: {data.Length} bytes");
        }
        uint length = GetU32(data, 5);
        if (length != data.Length - HeaderLen)
        {
            throw new StatusException(Wire.CodeInvalidArgument,
                $"payload length {length} does not match message size {data.Length}");
        }
        byte[] payload = new byte[data.Length - HeaderLen];
        Array.Copy(data, HeaderLen, payload, 0, payload.Length);
        return new Frame(data[0], GetU32(data, 1), payload);
    }

    public static void PutU32(byte[] output, int offset, uint value)
    {
        output[offset] = (byte)(value >> 24);
        output[offset + 1] = (byte)(value >> 16);
        output[offset + 2] = (byte)(value >> 8);
        output[offset + 3] = (byte)value;
    }

    public static uint GetU32(byte[] input, int offset)
    {
        return ((uint)input[offset] << 24) | ((uint)input[offset + 1] << 16)
            | ((uint)input[offset + 2] << 8) | input[offset + 3];
    }

    /// <summary>Parsed HEADERS payload: Path == null means response headers.</summary>
    public sealed class Headers
    {
        public string Path { get; }
        public Dictionary<string, string> Metadata { get; }

        public Headers(string path, Dictionary<string, string> metadata)
        {
            Path = path;
            Metadata = metadata ?? new Dictionary<string, string>();
        }
    }

    public static byte[] HeadersFrame(uint streamId, string path, IDictionary<string, string> metadata)
    {
        var body = new Dictionary<string, object>();
        if (path != null)
        {
            body["path"] = path;
        }
        if (metadata != null && metadata.Count > 0)
        {
            body["metadata"] = new Dictionary<string, string>(metadata);
        }
        return EncodeFrame(Wire.FrameHeaders, streamId,
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(body)));
    }

    public static Headers ParseHeaders(byte[] payload)
    {
        try
        {
            using JsonDocument doc = JsonDocument.Parse(payload);
            JsonElement root = doc.RootElement;
            string path = null;
            if (root.TryGetProperty("path", out JsonElement pathEl) && pathEl.ValueKind == JsonValueKind.String)
            {
                path = pathEl.GetString();
            }
            var metadata = new Dictionary<string, string>();
            if (root.TryGetProperty("metadata", out JsonElement mdEl) && mdEl.ValueKind == JsonValueKind.Object)
            {
                foreach (JsonProperty prop in mdEl.EnumerateObject())
                {
                    metadata[prop.Name] = prop.Value.ValueKind == JsonValueKind.String
                        ? prop.Value.GetString()
                        : prop.Value.ToString();
                }
            }
            return new Headers(path, metadata);
        }
        catch (JsonException e)
        {
            throw new StatusException(Wire.CodeInvalidArgument, $"bad HEADERS payload: {e.Message}");
        }
    }

    // gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
    // units H/M/S/m/u/n (at most 8 digits). Encoding uses
    // milliseconds (seconds past the digit limit), rounded up.
    public static string EncodeTimeout(TimeSpan timeout)
    {
        long ms = (long)Math.Ceiling(timeout.TotalMilliseconds);
        if (ms <= 99999999L)
        {
            return ms + "m";
        }
        return (long)Math.Ceiling(timeout.TotalSeconds) + "S";
    }

    /// <summary>Decoded grpc-timeout, or null when malformed/absent.</summary>
    public static TimeSpan? ParseTimeout(string text)
    {
        if (string.IsNullOrEmpty(text) || text.Length < 2 || text.Length > 9)
        {
            return null;
        }
        string digits = text.Substring(0, text.Length - 1);
        foreach (char c in digits)
        {
            if (!char.IsDigit(c))
            {
                return null;
            }
        }
        long n = long.Parse(digits);
        return text[text.Length - 1] switch
        {
            'H' => TimeSpan.FromHours(n),
            'M' => TimeSpan.FromMinutes(n),
            'S' => TimeSpan.FromSeconds(n),
            'm' => TimeSpan.FromMilliseconds(n),
            'u' => TimeSpan.FromTicks(n * 10),
            'n' => TimeSpan.FromTicks((n + 99) / 100),
            _ => null,
        };
    }

    public static byte[] StatusFrame(int frameType, uint streamId, StatusException status)
    {
        var body = new Dictionary<string, object>
        {
            ["code"] = status.Code,
            ["message"] = status.Message,
        };
        return EncodeFrame(frameType, streamId,
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(body)));
    }

    public static StatusException ParseStatus(byte[] payload)
    {
        try
        {
            using JsonDocument doc = JsonDocument.Parse(payload);
            JsonElement root = doc.RootElement;
            int code = root.GetProperty("code").GetInt32();
            string message = root.TryGetProperty("message", out JsonElement msgEl)
                && msgEl.ValueKind == JsonValueKind.String ? msgEl.GetString() : "";
            return new StatusException(code, message ?? "");
        }
        catch (Exception)
        {
            return new StatusException(Wire.CodeUnknown, "malformed trailers");
        }
    }
}
GRPC_RUNTIME_EOF
)

(define csharp-transport-body
#<<GRPC_RUNTIME_EOF
namespace Grpcdc;

/// <summary>
/// Carries whole DataChannel messages: one Send/Recv is one message,
/// boundaries preserved, ordered and reliable — the contract an
/// RTCDataChannel (or the loopback pair) offers.
/// </summary>
public interface ITransport
{
    void Send(byte[] data);

    /// <summary>Next message; throws EndOfStreamException when closed.</summary>
    byte[] Recv();

    void Close() { }
}

/// <summary>Implemented by generated protobuf message types.</summary>
public interface IMarshaler
{
    byte[] MarshalDc();
}

/// <summary>Implemented by generated protobuf message pointer types.</summary>
public interface IUnmarshaler
{
    void UnmarshalDc(byte[] data);
}
GRPC_RUNTIME_EOF
)

(define csharp-endpoint-body
#<<GRPC_RUNTIME_EOF
using System.Collections.Concurrent;

namespace Grpcdc;

/// <summary>Multiplexes grpc-dc streams over one ITransport.</summary>
public class Endpoint
{
    public enum EventKind { Headers, Data, HalfClose, Trailers, Rst }

    public sealed class StreamEvent
    {
        public EventKind Kind { get; }
        public Codec.Headers Headers { get; }
        public byte[] Payload { get; }
        public StatusException Status { get; }

        public StreamEvent(EventKind kind, Codec.Headers headers, byte[] payload, StatusException status)
        {
            Kind = kind;
            Headers = headers;
            Payload = payload;
            Status = status;
        }
    }

    /// <summary>Receiving queue of one stream; closed after a terminal event.</summary>
    public sealed class StreamInput
    {
        private readonly BlockingCollection<object> _events = new();
        private static readonly object Closed = new();

        internal void Put(StreamEvent evt) => _events.Add(evt);

        internal void Close() => _events.Add(Closed);

        /// <summary>Next event, or null once the stream is closed.</summary>
        public StreamEvent Get()
        {
            object item = _events.Take();
            return item == Closed ? null : (StreamEvent)item;
        }

        /// <summary>
        /// Next event within timeout, or null once closed.
        /// Throws TimeoutException on expiry.
        /// </summary>
        public StreamEvent Get(TimeSpan timeout)
        {
            if (!_events.TryTake(out object item, timeout))
            {
                throw new TimeoutException();
            }
            return item == Closed ? null : (StreamEvent)item;
        }
    }

    /// <summary>Per-call context: metadata sent in HEADERS, plus deadline.</summary>
    public sealed class CallContext
    {
        public Dictionary<string, string> Metadata { get; }

        /// <summary>Deadline propagated via grpc-timeout, when set.</summary>
        public DateTimeOffset? Deadline { get; }

        public CallContext(Dictionary<string, string> metadata)
        {
            Metadata = metadata ?? new Dictionary<string, string>();
            TimeSpan? remaining = Metadata.TryGetValue("grpc-timeout", out string text)
                ? Codec.ParseTimeout(text)
                : null;
            Deadline = remaining == null ? null : DateTimeOffset.UtcNow + remaining.Value;
        }

        /// <summary>Time left before the deadline, or null when unbounded.</summary>
        public TimeSpan? TimeRemaining()
        {
            if (Deadline == null)
            {
                return null;
            }
            TimeSpan left = Deadline.Value - DateTimeOffset.UtcNow;
            return left < TimeSpan.Zero ? TimeSpan.Zero : left;
        }

        public bool DeadlineExceeded => TimeRemaining() == TimeSpan.Zero;
    }

    /// <summary>Server-side call handler installed by Server.</summary>
    /// <returns>The status that becomes the call's TRAILERS (null = OK).</returns>
    public delegate StatusException Dispatcher(CallContext ctx, Codec.Headers headers, StreamInput input, ResponseSink sink);

    /// <summary>Sends response payloads of one inbound call.</summary>
    public sealed class ResponseSink
    {
        private readonly Endpoint _endpoint;
        private readonly uint _streamId;

        internal ResponseSink(Endpoint endpoint, uint streamId)
        {
            _endpoint = endpoint;
            _streamId = streamId;
        }

        public void Send(byte[] payload)
        {
            _endpoint.SendFrame(Codec.EncodeFrame(Wire.FrameData, _streamId, payload));
        }

        internal void SendHeaders()
        {
            _endpoint.SendFrame(Codec.HeadersFrame(_streamId, null, null));
        }

        internal void SendTrailers(StatusException status)
        {
            _endpoint.SendFrame(Codec.StatusFrame(Wire.FrameTrailers, _streamId, status));
        }
    }

    private readonly ITransport _transport;
    private volatile Dispatcher _dispatcher;
    private uint _nextId;
    private readonly object _sendLock = new();
    private readonly ConcurrentDictionary<uint, StreamInput> _streams = new();
    private volatile bool _closed;
    private bool _started;
    private readonly object _startLock = new();

    /// <summary>
    /// The side that created the channel allocates odd stream ids, the
    /// answerer even. The read loop starts on Start() — after any
    /// dispatcher is installed, so an early HEADERS can never race
    /// dispatcher setup.
    /// </summary>
    public Endpoint(ITransport transport, bool creator)
    {
        _transport = transport;
        _nextId = creator ? 1u : 2u;
    }

    /// <summary>Start the read loop (idempotent).</summary>
    public void Start()
    {
        lock (_startLock)
        {
            if (_started)
            {
                return;
            }
            _started = true;
        }
        var thread = new Thread(ReadLoop) { IsBackground = true, Name = "grpcdc-endpoint" };
        thread.Start();
    }

    public void SetDispatcher(Dispatcher dispatcher) => _dispatcher = dispatcher;

    public void SendFrame(byte[] frame)
    {
        lock (_sendLock)
        {
            _transport.Send(frame);
        }
    }

    public (uint Id, StreamInput Input) OpenStream()
    {
        uint id;
        lock (_sendLock)
        {
            id = _nextId;
            _nextId += 2;
        }
        var input = new StreamInput();
        _streams[id] = input;
        return (id, input);
    }

    public void CloseStream(uint id) => _streams.TryRemove(id, out _);

    /// <summary>Abort one stream: RST out; a pending Recv wakes with Cancelled.</summary>
    public void CancelStream(uint id)
    {
        if (_streams.TryRemove(id, out StreamInput input))
        {
            input.Put(new StreamEvent(EventKind.Rst, null, null,
                new StatusException(Wire.CodeCancelled, "call cancelled")));
            input.Close();
        }
        try
        {
            SendFrame(Codec.StatusFrame(Wire.FrameRst, id,
                new StatusException(Wire.CodeCancelled, "call cancelled")));
        }
        catch
        {
            // Transport already gone; the local abort still stands.
        }
    }

    private StreamInput Stream(uint id) => _streams.TryGetValue(id, out StreamInput input) ? input : null;

    public void Close()
    {
        if (_closed)
        {
            return;
        }
        _closed = true;
        try { _transport.Close(); } catch (Exception) { /* best effort */ }
        FailAll();
    }

    private void FailAll()
    {
        foreach (KeyValuePair<uint, StreamInput> entry in _streams)
        {
            entry.Value.Put(new StreamEvent(EventKind.Rst, null, null,
                new StatusException(Wire.CodeUnavailable, "data channel closed")));
            entry.Value.Close();
        }
        _streams.Clear();
    }

    private void ReadLoop()
    {
        while (true)
        {
            byte[] data;
            try
            {
                data = _transport.Recv();
            }
            catch (Exception)
            {
                FailAll();
                return;
            }
            if (_closed)
            {
                return;
            }
            OnBytes(data);
        }
    }

    private void OnBytes(byte[] data)
    {
        Codec.Frame frame;
        try
        {
            frame = Codec.DecodeFrame(data);
        }
        catch (StatusException)
        {
            return; // malformed frame: drop, keep the channel up
        }
        int frameType = frame.Type;
        uint streamId = frame.StreamId;
        byte[] payload = frame.Payload;
@@FRAME_DISPATCH@@
    }

    private void OnTerminal(uint streamId, byte[] payload, EventKind kind)
    {
        StreamInput input = Stream(streamId);
        if (input != null)
        {
            input.Put(new StreamEvent(kind, null, null, Codec.ParseStatus(payload)));
            input.Close();
            CloseStream(streamId);
        }
    }

    private void PushEvent(uint streamId, StreamEvent evt)
    {
        StreamInput input = Stream(streamId);
        input?.Put(evt);
    }

    private void OnHeaders(uint streamId, byte[] payload)
    {
        Codec.Headers headers;
        try
        {
            headers = Codec.ParseHeaders(payload);
        }
        catch (StatusException e)
        {
            try { SendFrame(Codec.StatusFrame(Wire.FrameRst, streamId, StatusException.ToStatus(e))); }
            catch (Exception) { /* best effort */ }
            return;
        }
        if (headers.Path == null)
        {
            // Server response headers for one of our outbound streams.
            StreamInput input = Stream(streamId);
            input?.Put(new StreamEvent(EventKind.Headers, headers, null, null));
            return;
        }
        if (Stream(streamId) != null)
        {
            try
            {
                SendFrame(Codec.StatusFrame(Wire.FrameRst, streamId,
                    new StatusException(Wire.CodeInternal, "HEADERS for stream already in use")));
            }
            catch (Exception) { /* best effort */ }
            return;
        }
        if (_dispatcher == null)
        {
            try
            {
                SendFrame(Codec.StatusFrame(Wire.FrameTrailers, streamId,
                    new StatusException(Wire.CodeUnimplemented, $"unknown method {headers.Path}")));
            }
            catch (Exception) { /* best effort */ }
            return;
        }
        var streamInput = new StreamInput();
        _streams[streamId] = streamInput;
        var sink = new ResponseSink(this, streamId);
        var thread = new Thread(() =>
        {
            try
            {
                try { sink.SendHeaders(); }
                catch (Exception) { return; }
                StatusException status = _dispatcher(
                    new CallContext(headers.Metadata), headers, streamInput, sink);
                status ??= new StatusException(Wire.CodeOk, "");
                try { sink.SendTrailers(status); }
                catch (Exception) { /* best effort */ }
            }
            finally
            {
                CloseStream(streamId);
            }
        })
        { IsBackground = true, Name = "grpcdc-call" };
        thread.Start();
    }
}
GRPC_RUNTIME_EOF
)

(define csharp-channel-body
#<<GRPC_RUNTIME_EOF
namespace Grpcdc;

/// <summary>Channel: the client side of one Endpoint.</summary>
public class Channel
{
    private readonly Endpoint _endpoint;

    /// <summary>Wrap a transport, allocating odd stream ids.</summary>
    public Channel(ITransport transport) : this(new Endpoint(transport, true))
    {
    }

    /// <summary>Wrap an existing endpoint (bidirectional use; starts its read loop).</summary>
    public Channel(Endpoint endpoint)
    {
        _endpoint = endpoint;
        endpoint.Start();
    }

    public Endpoint Endpoint => _endpoint;

    /// <summary>Receives response messages of one call.</summary>
    public sealed class ClientStream
    {
        private readonly Endpoint _endpoint;
        private readonly Endpoint.StreamInput _input;

        public uint StreamId { get; }
        public Codec.Headers Headers { get; private set; }
        internal long DeadlineTimestamp = -1;
        internal Tracing.TraceContext TraceCtx;
        internal string TracePath;
        private bool _traceEnded;

        internal void EndTrace(string status)
        {
            if (!_traceEnded)
            {
                _traceEnded = true;
                Tracing.TraceEnd("client", TracePath, TraceCtx, status);
            }
        }

        internal ClientStream(Endpoint endpoint, uint streamId, Endpoint.StreamInput input)
        {
            _endpoint = endpoint;
            StreamId = streamId;
            _input = input;
        }

        /// <summary>Abort this stream (sends RST, wakes a pending Recv).</summary>
        public void Cancel() => _endpoint.CancelStream(StreamId);

        private Endpoint.StreamEvent NextEvent()
        {
            if (DeadlineTimestamp < 0)
            {
                return _input.Get();
            }
            long remainingTicks = DeadlineTimestamp - System.Diagnostics.Stopwatch.GetTimestamp();
            try
            {
                if (remainingTicks <= 0)
                {
                    throw new TimeoutException();
                }
                return _input.Get(TimeSpan.FromSeconds(
                    (double)remainingTicks / System.Diagnostics.Stopwatch.Frequency));
            }
            catch (TimeoutException)
            {
                _endpoint.CancelStream(StreamId);
                throw new StatusException(Wire.CodeDeadlineExceeded, "deadline exceeded");
            }
        }

        /// <summary>
        /// Decode the next response into resp. EndOfStreamException
        /// means the call completed OK; StatusException reports the
        /// trailers status.
        /// </summary>
        public void Recv(IUnmarshaler resp)
        {
            while (true)
            {
                Endpoint.StreamEvent evt = NextEvent();
                if (evt == null)
                {
                    throw new StatusException(Wire.CodeUnavailable, "data channel closed");
                }
                switch (evt.Kind)
                {
                    case Endpoint.EventKind.Headers:
                        Headers = evt.Headers;
                        break;
                    case Endpoint.EventKind.Data:
                        resp.UnmarshalDc(evt.Payload);
                        return;
                    case Endpoint.EventKind.Trailers:
                        EndTrace(Wire.StatusName(evt.Status.Code));
                        if (evt.Status.Code != Wire.CodeOk)
                        {
                            throw evt.Status;
                        }
                        throw new EndOfStreamException("call completed");
                    case Endpoint.EventKind.Rst:
                        EndTrace(Wire.StatusName(evt.Status.Code));
                        throw evt.Status;
                    default:
                        break;
                }
            }
        }
    }

    private ClientStream Open(string path, IDictionary<string, string> metadata, TimeSpan? timeout = null)
    {
        long deadline = -1;
        Tracing.TraceContext traceCtx = null;
        if (timeout != null || Tracing.Enabled)
        {
            var merged = metadata == null
                ? new Dictionary<string, string>()
                : new Dictionary<string, string>(metadata);
            if (timeout != null)
            {
                deadline = System.Diagnostics.Stopwatch.GetTimestamp()
                    + (long)(timeout.Value.TotalSeconds * System.Diagnostics.Stopwatch.Frequency);
                merged["grpc-timeout"] = Codec.EncodeTimeout(timeout.Value);
            }
            if (Tracing.Enabled)
            {
                traceCtx = Tracing.TraceStart("client", path,
                    Tracing.ParseTraceparent(merged.TryGetValue("traceparent", out string tp) ? tp : null));
                if (traceCtx != null)
                {
                    merged["traceparent"] = Tracing.FormatTraceparent(traceCtx.TraceId, traceCtx.SpanId);
                }
            }
            metadata = merged;
        }
        (uint id, Endpoint.StreamInput input) = _endpoint.OpenStream();
        try
        {
            _endpoint.SendFrame(Codec.HeadersFrame(id, path, metadata));
        }
        catch
        {
            _endpoint.CloseStream(id);
            Tracing.TraceEnd("client", path, traceCtx, "UNAVAILABLE");
            throw;
        }
        return new ClientStream(_endpoint, id, input)
        {
            DeadlineTimestamp = deadline,
            TraceCtx = traceCtx,
            TracePath = path,
        };
    }

    private void SendMessage(ClientStream stream, IMarshaler msg)
    {
        _endpoint.SendFrame(Codec.EncodeFrame(Wire.FrameData, stream.StreamId, msg.MarshalDc()));
    }

    private void HalfClose(ClientStream stream)
    {
        _endpoint.SendFrame(Codec.EncodeFrame(Wire.FrameHalfClose, stream.StreamId, Array.Empty<byte>()));
    }

    private void SendAll(ClientStream stream, IEnumerable<IMarshaler> reqs)
    {
        foreach (IMarshaler req in reqs)
        {
            SendMessage(stream, req);
        }
        HalfClose(stream);
    }

    /// <summary>Run a unary call, decoding the single response into resp.</summary>
    public void Unary(string path, IMarshaler req, IUnmarshaler resp, IDictionary<string, string> metadata = null, TimeSpan? timeout = null)
    {
        ClientStream stream = Open(path, metadata, timeout);
        try
        {
            SendMessage(stream, req);
            HalfClose(stream);
            bool got = false;
            while (true)
            {
                try
                {
                    stream.Recv(resp);
                }
                catch (EndOfStreamException)
                {
                    if (!got)
                    {
                        throw new StatusException(Wire.CodeInternal, "call closed with no response");
                    }
                    return;
                }
                if (got)
                {
                    throw new StatusException(Wire.CodeInternal, "unary call received more than one response");
                }
                got = true;
            }
        }
        finally
        {
            _endpoint.CloseStream(stream.StreamId);
        }
    }

    /// <summary>Start a server-streaming call.</summary>
    public ClientStream ServerStream(string path, IMarshaler req, IDictionary<string, string> metadata = null, TimeSpan? timeout = null)
    {
        ClientStream stream = Open(path, metadata, timeout);
        SendMessage(stream, req);
        HalfClose(stream);
        return stream;
    }

    /// <summary>Send all requests, then decode the one response into resp.</summary>
    public void ClientStreamCall(string path, IEnumerable<IMarshaler> reqs, IUnmarshaler resp,
        IDictionary<string, string> metadata = null, TimeSpan? timeout = null)
    {
        ClientStream stream = Open(path, metadata, timeout);
        try
        {
            SendAll(stream, reqs);
            bool got = false;
            while (true)
            {
                try
                {
                    stream.Recv(resp);
                }
                catch (EndOfStreamException)
                {
                    if (!got)
                    {
                        throw new StatusException(Wire.CodeInternal, "call closed with no response");
                    }
                    return;
                }
                if (got)
                {
                    throw new StatusException(Wire.CodeInternal,
                        "client-streaming call received more than one response");
                }
                got = true;
            }
        }
        finally
        {
            _endpoint.CloseStream(stream.StreamId);
        }
    }

    /// <summary>Start a bidi call with all requests sent up front.</summary>
    public ClientStream Bidi(string path, IEnumerable<IMarshaler> reqs, IDictionary<string, string> metadata = null, TimeSpan? timeout = null)
    {
        ClientStream stream = Open(path, metadata, timeout);
        SendAll(stream, reqs);
        return stream;
    }
}
GRPC_RUNTIME_EOF
)

(define csharp-server-body
#<<GRPC_RUNTIME_EOF
namespace Grpcdc;

/// <summary>Server: dispatches inbound calls to registered methods.</summary>
public class Server
{
    public const string KindUnary = "unary";
    public const string KindServerStreaming = "server-streaming";
    public const string KindClientStreaming = "client-streaming";
    public const string KindBidi = "bidi";

    /// <summary>Reads request messages of one inbound call.</summary>
    public sealed class RequestStream
    {
        private readonly Endpoint.StreamInput _input;

        public RequestStream(Endpoint.StreamInput input)
        {
            _input = input;
        }

        /// <summary>Next request payload; EndOfStreamException at half-close.</summary>
        public byte[] RecvRaw()
        {
            while (true)
            {
                Endpoint.StreamEvent evt = _input.Get();
                if (evt == null)
                {
                    throw new StatusException(Wire.CodeUnavailable, "data channel closed");
                }
                switch (evt.Kind)
                {
                    case Endpoint.EventKind.Data:
                        return evt.Payload;
                    case Endpoint.EventKind.HalfClose:
                        throw new EndOfStreamException("half-close");
                    case Endpoint.EventKind.Trailers:
                    case Endpoint.EventKind.Rst:
                        throw evt.Status;
                    default:
                        break; // ignore HEADERS on the request side
                }
            }
        }

        /// <summary>Decode the next request message into req.</summary>
        public void RecvInto(IUnmarshaler req) => req.UnmarshalDc(RecvRaw());
    }

    /// <summary>Sends response payloads of one inbound call.</summary>
    public delegate void ServerSink(byte[] payload);

    /// <summary>Implements one method against raw payloads; stubs adapt it.</summary>
    public delegate void MethodHandler(Endpoint.CallContext ctx, RequestStream reqs, ServerSink sink);

    /// <summary>One entry of a ServiceDesc.</summary>
    public sealed record Method(string Name, string Path, string Kind, MethodHandler Handler);

    /// <summary>Describes a service for RegisterService.</summary>
    public sealed record ServiceDesc(string Name, List<Method> Methods);

    private readonly Dictionary<string, Method> _methods = new();

    /// <summary>Adds a service's methods (generated code calls it).</summary>
    public void RegisterService(ServiceDesc desc)
    {
        foreach (Method method in desc.Methods)
        {
            _methods[method.Path] = method;
        }
    }

    /// <summary>Attach to a transport (even stream ids); returns the Endpoint.</summary>
    public Endpoint ServeTransport(ITransport transport)
    {
        var endpoint = new Endpoint(transport, false);
        ServeEndpoint(endpoint);
        return endpoint;
    }

    /// <summary>Attach to an existing endpoint (starts its read loop).</summary>
    public void ServeEndpoint(Endpoint endpoint)
    {
        endpoint.SetDispatcher(Dispatch);
        endpoint.Start();
    }

    private StatusException Dispatch(Endpoint.CallContext ctx, Codec.Headers headers,
        Endpoint.StreamInput input, Endpoint.ResponseSink sink)
    {
        if (!_methods.TryGetValue(headers.Path, out Method method))
        {
            return new StatusException(Wire.CodeUnimplemented, $"unknown method {headers.Path}");
        }
        Tracing.TraceContext traceCtx = Tracing.TraceStart("server", headers.Path,
            Tracing.ParseTraceparent(headers.Metadata.TryGetValue("traceparent", out string tp) ? tp : null));
        StatusException result = null;
        try
        {
            method.Handler(ctx, new RequestStream(input), payload => sink.Send(payload));
        }
        catch (Exception e)
        {
            result = StatusException.ToStatus(e);
        }
        Tracing.TraceEnd("server", headers.Path, traceCtx,
            result == null ? "OK" : Wire.StatusName(result.Code));
        return result;
    }
}
GRPC_RUNTIME_EOF
)

(define csharp-loopback-body
#<<GRPC_RUNTIME_EOF
using System.Collections.Concurrent;

namespace Grpcdc;

/// <summary>In-memory transport pair for tests (one queue per direction).</summary>
public static class MemoryTransport
{
    private sealed class Impl : ITransport
    {
        private readonly BlockingCollection<byte[]> _inbox;
        private readonly BlockingCollection<byte[]> _outbox;
        private volatile bool _closed;

        internal Impl(BlockingCollection<byte[]> inbox, BlockingCollection<byte[]> outbox)
        {
            _inbox = inbox;
            _outbox = outbox;
        }

        public void Send(byte[] data)
        {
            if (_closed)
            {
                throw new EndOfStreamException("transport closed");
            }
            _outbox.Add((byte[])data.Clone());
        }

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

        public void Close()
        {
            _closed = true;
            _inbox.CompleteAdding();
        }
    }

    /// <summary>Two connected in-memory transports.</summary>
    public static (ITransport, ITransport) Pair()
    {
        var aToB = new BlockingCollection<byte[]>();
        var bToA = new BlockingCollection<byte[]>();
        return (new Impl(bToA, aToB), new Impl(aToB, bToA));
    }
}
GRPC_RUNTIME_EOF
)


(define csharp-sidecar-body
#<<GRPC_RUNTIME_EOF
using System.Net.Sockets;

namespace Grpcdc;

/// <summary>
/// Transport over the Rust WebRTC-Direct sidecar: the sidecar
/// owns DTLS/SCTP/TURN and bridges one datachannel to a local
/// TCP socket using u32 big-endian length-prefixed messages
/// (one prefix per DataChannel message). BCL only.
/// </summary>
public sealed class SidecarTransport : ITransport
{
    private readonly TcpClient _client;
    private readonly NetworkStream _stream;
    private volatile bool _closed;

    public SidecarTransport(TcpClient client)
    {
        _client = client;
        _stream = client.GetStream();
    }

    public static SidecarTransport Connect(string host, int port)
    {
        return new SidecarTransport(new TcpClient(host, port));
    }

    public void Send(byte[] data)
    {
        if (_closed)
        {
            throw new EndOfStreamException("transport closed");
        }
        var header = new byte[4];
        header[0] = (byte)(data.Length >> 24);
        header[1] = (byte)(data.Length >> 16);
        header[2] = (byte)(data.Length >> 8);
        header[3] = (byte)data.Length;
        lock (_stream)
        {
            _stream.Write(header, 0, header.Length);
            _stream.Write(data, 0, data.Length);
            _stream.Flush();
        }
    }

    public byte[] Recv()
    {
        var header = ReadExact(4);
        int length = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
        return ReadExact(length);
    }

    private byte[] ReadExact(int count)
    {
        var buf = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int n = _stream.Read(buf, offset, count - offset);
            if (n == 0)
            {
                throw new EndOfStreamException("transport closed");
            }
            offset += n;
        }
        return buf;
    }

    public void Close()
    {
        _closed = true;
        _client.Close();
    }
}
GRPC_RUNTIME_EOF
)

(define csharp-dispatch-arms
  '((HEADERS    . "OnHeaders(streamId, payload);")
    (DATA       . "PushEvent(streamId, new StreamEvent(EventKind.Data, null, payload, null));")
    (HALF-CLOSE . "PushEvent(streamId, new StreamEvent(EventKind.HalfClose, null, null, null));")
    (TRAILERS   . "OnTerminal(streamId, payload, EventKind.Trailers);")
    (RST        . "OnTerminal(streamId, payload, EventKind.Rst);")))

(define (screaming-name sym)
  (string-replace (symbol->string sym) "-" "_"))

(define (emit-csharp-dispatch)
  (string-append
   "        switch (frameType)\n        {\n"
   (apply string-append
          (for/list ([e (in-list frame-table)])
            (define arm (assoc (first e) csharp-dispatch-arms))
            (unless arm (error 'runtime-csharp "no C# dispatch arm for ~a" (first e)))
            (format "            case Wire.Frame~a: ~a break;\n"
                    (pascal-csharp (first e)) (cdr arm))))
   "            default: break; // Unknown frame type: ignore for forward compatibility.\n        }"))

(define (pascal-csharp sym) ; HALF-CLOSE -> HalfClose
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "-"))])
           (string-append (string (char-upcase (string-ref part 0)))
                          (string-downcase (substring part 1))))))

(define (emit-csharp-runtime-files)
  (list
   (cons "grpcdc/StatusException.cs" csharp-status-body)
   (cons "grpcdc/Codec.cs" csharp-codec-body)
   (cons "grpcdc/Transport.cs" csharp-transport-body)
   (cons "grpcdc/Endpoint.cs"
         (string-replace csharp-endpoint-body "@@FRAME_DISPATCH@@" (emit-csharp-dispatch)))
   (cons "grpcdc/Channel.cs" csharp-channel-body)
   (cons "grpcdc/Server.cs" csharp-server-body)
   (cons "grpcdc/MemoryTransport.cs" csharp-loopback-body)
   (cons "grpcdc/SidecarTransport.cs" csharp-sidecar-body)
   (cons "grpcdc/AsyncPump.cs" csharp-async-body)
   (cons "grpcdc/Dynamic.cs" csharp-dynamic-body)))

(define csharp-async-body
#<<GRPC_RUNTIME_EOF
using System.Runtime.CompilerServices;
using System.Threading.Channels;

namespace Grpcdc;

/// <summary>
/// Async helpers backing the generated Task/IAsyncEnumerable stub
/// surface. The core runtime is blocking (thread-backed queues);
/// async methods pump blocking Recv calls onto the thread pool and
/// stream results through a Channel, so cancellation and backpressure
/// behave like idiomatic .NET async code.
/// </summary>
public static class AsyncPump
{
    /// <summary>Run a blocking call as a Task.</summary>
    public static Task<T> Run<T>(Func<T> blocking, CancellationToken cancellationToken)
    {
        return Task.Run(blocking, cancellationToken);
    }

    /// <summary>Run a blocking action as a Task.</summary>
    public static Task Run(Action blocking, CancellationToken cancellationToken)
    {
        return Task.Run(blocking, cancellationToken);
    }

    /// <summary>
    /// Adapt a blocking receive loop to IAsyncEnumerable. recv returns
    /// the next item and throws EndOfStreamException at the end;
    /// StatusException propagates as the stream's error.
    /// </summary>
    public static async IAsyncEnumerable<T> Stream<T>(
        Func<T> recv,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var channel = System.Threading.Channels.Channel.CreateBounded<T>(new BoundedChannelOptions(16)
        {
            FullMode = BoundedChannelFullMode.Wait,
        });
        var pump = Task.Run(() =>
        {
            try
            {
                while (true)
                {
                    T item = recv();
                    channel.Writer.WriteAsync(item).AsTask().GetAwaiter().GetResult();
                }
            }
            catch (EndOfStreamException)
            {
                channel.Writer.TryComplete();
            }
            catch (Exception e)
            {
                channel.Writer.TryComplete(e);
            }
        }, cancellationToken);
        try
        {
            await foreach (T item in channel.Reader.ReadAllAsync(cancellationToken))
            {
                yield return item;
            }
        }
        finally
        {
            _ = pump.ContinueWith(t => { _ = t.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
        }
    }
}
GRPC_RUNTIME_EOF
)

(define csharp-dynamic-body
#<<GRPC_RUNTIME_EOF
namespace Grpcdc;

/// <summary>
/// Dynamic, descriptor-driven client and server.
///
/// Parses a FileDescriptorSet (as produced by
/// <c>protoc --descriptor_set_out</c>) at runtime and builds clients
/// and servers whose messages are generic field maps — no generated
/// stubs required. Schemas arrive as data (descriptor.proto), not as
/// code.
///
/// Generic values by field type: varint family -&gt; long,
/// string -&gt; string, bytes -&gt; byte[], message -&gt;
/// GenericMessage, fixed/float -&gt; long/double/float, bool -&gt; bool.
/// </summary>
public static class Dynamic
{
    // FieldDescriptorProto.Type values (descriptor.proto).
    public const int TypeDouble = 1;
    public const int TypeFloat = 2;
    public const int TypeInt64 = 3;
    public const int TypeUint64 = 4;
    public const int TypeInt32 = 5;
    public const int TypeFixed64 = 6;
    public const int TypeFixed32 = 7;
    public const int TypeBool = 8;
    public const int TypeString = 9;
    public const int TypeGroup = 10;
    public const int TypeMessage = 11;
    public const int TypeBytes = 12;
    public const int TypeUint32 = 13;
    public const int TypeEnum = 14;
    public const int TypeSfixed32 = 15;
    public const int TypeSfixed64 = 16;
    public const int TypeSint32 = 17;
    public const int TypeSint64 = 18;

    private const int LabelRepeated = 3;

    /// <summary>One field of a message descriptor.</summary>
    public sealed class FieldModel
    {
        public int Number { get; }
        public string Name { get; }
        public int Type { get; }
        public bool Repeated { get; }
        public string TypeName { get; }

        internal FieldModel(int number, string name, int type, bool repeated, string typeName)
        {
            Number = number;
            Name = name;
            Type = type;
            Repeated = repeated;
            TypeName = typeName;
        }
    }

    /// <summary>One message descriptor.</summary>
    public sealed class MessageModel
    {
        public string FullName { get; }
        public Dictionary<int, FieldModel> Fields { get; } = new();

        internal MessageModel(string fullName)
        {
            FullName = fullName;
        }
    }

    /// <summary>One method descriptor.</summary>
    public sealed class MethodModel
    {
        public string Name { get; }
        public string Path { get; }
        public string Kind { get; }
        public MessageModel Input { get; }
        public MessageModel Output { get; }

        internal MethodModel(string name, string path, string kind, MessageModel input, MessageModel output)
        {
            Name = name;
            Path = path;
            Kind = kind;
            Input = input;
            Output = output;
        }
    }

    /// <summary>One service descriptor.</summary>
    public sealed class ServiceModel
    {
        public string FullName { get; }
        public Dictionary<string, MethodModel> Methods { get; } = new();

        internal ServiceModel(string fullName)
        {
            FullName = fullName;
        }
    }

    /// <summary>A parsed FileDescriptorSet: messages and services by full name.</summary>
    public sealed class FileModel
    {
        public Dictionary<string, MessageModel> Messages { get; } = new(); // ".echo.EchoRequest"
        public Dictionary<string, ServiceModel> Services { get; } = new(); // "echo.Echo"
    }

    /// <summary>
    /// A message as field number -> values (descriptor order). Fields
    /// not in the model are retained as raw encoded chunks in
    /// Unknown (protobuf unknown-field retention); a decode -> encode
    /// round trip re-emits them after the known fields.
    /// </summary>
    public sealed class GenericMessage
    {
        public MessageModel Model { get; }
        public SortedDictionary<int, List<object>> Values { get; } = new();
        public List<byte[]> Unknown { get; } = new();

        public GenericMessage(MessageModel model)
        {
            Model = model;
        }

        public GenericMessage Set(int number, object value)
        {
            Values[number] = new List<object> { value };
            return this;
        }

        public GenericMessage Add(int number, object value)
        {
            if (!Values.TryGetValue(number, out List<object> list))
            {
                list = new List<object>();
                Values[number] = list;
            }
            list.Add(value);
            return this;
        }

        public object Get(int number)
        {
            return Values.TryGetValue(number, out List<object> list) && list.Count > 0 ? list[0] : null;
        }

        public string GetString(int number)
        {
            return Get(number) is string s ? s : "";
        }

        public long GetInt(int number)
        {
            return Get(number) switch
            {
                long l => l,
                int i => i,
                bool b => b ? 1 : 0,
                _ => 0,
            };
        }

        public override string ToString() => $"GenericMessage({Values.Count} fields)";
    }

    // -- protobuf wire reading (descriptor + generic payloads) --

    private sealed class PbReader
    {
        private readonly byte[] _buf;
        private int _pos;

        internal PbReader(byte[] buf)
        {
            _buf = buf;
        }

        internal long Varint()
        {
            long result = 0;
            int shift = 0;
            while (true)
            {
                if (_pos >= _buf.Length)
                {
                    throw new ArgumentException("truncated varint");
                }
                int b = _buf[_pos++];
                result |= (long)(b & 0x7f) << shift;
                if ((b & 0x80) == 0)
                {
                    return result;
                }
                shift += 7;
                if (shift >= 70)
                {
                    throw new ArgumentException("varint too long");
                }
            }
        }

        internal byte[] BytesField()
        {
            int n = (int)Varint();
            if (_pos + n > _buf.Length)
            {
                throw new ArgumentException("truncated bytes field");
            }
            var output = new byte[n];
            Array.Copy(_buf, _pos, output, 0, n);
            _pos += n;
            return output;
        }

        internal sealed record Field(int Number, int Wire, long VarintValue, byte[] Bytes, byte[] Raw);

        internal List<Field> All()
        {
            var output = new List<Field>();
            while (_pos < _buf.Length)
            {
                int start = _pos;
                long tag = Varint();
                int number = (int)(tag >> 3);
                int wire = (int)(tag & 7);
                Field field;
                switch (wire)
                {
                    case 0:
                        field = new Field(number, wire, Varint(), null, null);
                        break;
                    case 2:
                        field = new Field(number, wire, 0, BytesField(), null);
                        break;
                    case 1:
                    {
                        if (_pos + 8 > _buf.Length)
                        {
                            throw new ArgumentException("truncated fixed64");
                        }
                        var value = new byte[8];
                        Array.Copy(_buf, _pos, value, 0, 8);
                        _pos += 8;
                        field = new Field(number, wire, 0, value, null);
                        break;
                    }
                    case 5:
                    {
                        if (_pos + 4 > _buf.Length)
                        {
                            throw new ArgumentException("truncated fixed32");
                        }
                        var value = new byte[4];
                        Array.Copy(_buf, _pos, value, 0, 4);
                        _pos += 4;
                        field = new Field(number, wire, 0, value, null);
                        break;
                    }
                    default:
                        throw new ArgumentException($"unsupported wire type {wire}");
                }
                var raw = new byte[_pos - start];
                Array.Copy(_buf, start, raw, 0, raw.Length);
                output.Add(field with { Raw = raw });
            }
            return output;
        }
    }

    private static string PbString(List<PbReader.Field> fields, int number)
    {
        foreach (PbReader.Field f in fields)
        {
            if (f.Number == number)
            {
                return System.Text.Encoding.UTF8.GetString(f.Bytes);
            }
        }
        return "";
    }

    private static long PbUint(List<PbReader.Field> fields, int number)
    {
        foreach (PbReader.Field f in fields)
        {
            if (f.Number == number)
            {
                return f.VarintValue;
            }
        }
        return 0;
    }

    /// <summary>Parse FileDescriptorSet bytes into a FileModel.</summary>
    public static FileModel ParseDescriptorSet(byte[] data)
    {
        var model = new FileModel();
        var pending = new List<(string, byte[])>();
        foreach (PbReader.Field fileField in new PbReader(data).All())
        {
            if (fileField.Number != 1)
            {
                continue;
            }
            var fields = new PbReader(fileField.Bytes).All();
            string pkg = PbString(fields, 2);
            foreach (PbReader.Field f in fields)
            {
                if (f.Number == 4)
                {
                    ParseMessage(pkg, "", f.Bytes, model);
                }
                else if (f.Number == 6)
                {
                    pending.Add((pkg, f.Bytes));
                }
            }
        }
        foreach ((string pkg, byte[] svc) in pending)
        {
            ParseService(pkg, svc, model);
        }
        return model;
    }

    private static void ParseMessage(string pkg, string outer, byte[] data, FileModel model)
    {
        var fields = new PbReader(data).All();
        string name = PbString(fields, 1);
        string full = (pkg.Length > 0 ? pkg + "." : "") + (outer.Length > 0 ? outer + "." : "") + name;
        var msg = new MessageModel(full);
        model.Messages["." + full] = msg;
        foreach (PbReader.Field f in fields)
        {
            if (f.Number == 2)
            {
                FieldModel field = ParseField(f.Bytes);
                msg.Fields[field.Number] = field;
            }
            else if (f.Number == 3)
            {
                string innerOuter = pkg.Length > 0 ? full.Substring(pkg.Length + 1) : full;
                ParseMessage(pkg, innerOuter, f.Bytes, model);
            }
        }
    }

    private static FieldModel ParseField(byte[] data)
    {
        var fields = new PbReader(data).All();
        return new FieldModel(
            (int)PbUint(fields, 3),
            PbString(fields, 1),
            (int)PbUint(fields, 5),
            PbUint(fields, 4) == LabelRepeated,
            PbString(fields, 6));
    }

    private static string MethodKind(bool clientStreaming, bool serverStreaming)
    {
        if (clientStreaming && serverStreaming)
        {
            return Server.KindBidi;
        }
        if (serverStreaming)
        {
            return Server.KindServerStreaming;
        }
        if (clientStreaming)
        {
            return Server.KindClientStreaming;
        }
        return Server.KindUnary;
    }

    private static void ParseService(string pkg, byte[] data, FileModel model)
    {
        var fields = new PbReader(data).All();
        string name = PbString(fields, 1);
        string full = pkg.Length > 0 ? pkg + "." + name : name;
        var service = new ServiceModel(full);
        model.Services[full] = service;
        foreach (PbReader.Field f in fields)
        {
            if (f.Number != 2)
            {
                continue;
            }
            var mf = new PbReader(f.Bytes).All();
            string mname = PbString(mf, 1);
            service.Methods[mname] = new MethodModel(
                mname, "/" + full + "/" + mname,
                MethodKind(PbUint(mf, 5) != 0, PbUint(mf, 6) != 0),
                model.Messages[PbString(mf, 2)],
                model.Messages[PbString(mf, 3)]);
        }
    }

    // -- generic message encoding --

    private static int WireTypeOf(int fieldType)
    {
        return fieldType switch
        {
            TypeInt64 or TypeUint64 or TypeInt32 or TypeBool or TypeUint32
                or TypeEnum or TypeSint32 or TypeSint64 => 0,
            TypeFixed64 or TypeSfixed64 or TypeDouble => 1,
            TypeString or TypeBytes or TypeMessage or TypeGroup => 2,
            _ => 5,
        };
    }

    private static void PutVarint(MemoryStream output, long value)
    {
        ulong v = (ulong)value;
        while ((v & ~0x7fUL) != 0)
        {
            output.WriteByte((byte)((v & 0x7f) | 0x80));
            v >>= 7;
        }
        output.WriteByte((byte)v);
    }

    /// <summary>Serialize a generic message per its model.</summary>
    public static byte[] EncodeGeneric(MessageModel msgModel, GenericMessage msg, FileModel fileModel)
    {
        var output = new MemoryStream();
        foreach (KeyValuePair<int, List<object>> entry in msg.Values)
        {
            if (!msgModel.Fields.TryGetValue(entry.Key, out FieldModel field))
            {
                throw new StatusException(Wire.CodeInvalidArgument,
                    $"unknown field {entry.Key} for {msgModel.FullName}");
            }
            List<object> values = entry.Value;
            if (field.Repeated)
            {
                foreach (object value in values)
                {
                    EncodeValue(output, field, value, fileModel);
                }
            }
            else if (values.Count > 0)
            {
                EncodeValue(output, field, values[0], fileModel);
            }
        }
        foreach (byte[] chunk in msg.Unknown)
        {
            output.Write(chunk, 0, chunk.Length);
        }
        return output.ToArray();
    }

    private static void EncodeValue(MemoryStream output, FieldModel field, object value, FileModel fileModel)
    {
        PutVarint(output, ((long)field.Number << 3) | (uint)WireTypeOf(field.Type));
        switch (WireTypeOf(field.Type))
        {
            case 0:
                if (field.Type == TypeSint32 || field.Type == TypeSint64)
                {
                    long v = Convert.ToInt64(value);
                    PutVarint(output, (v << 1) ^ (v >> 63));
                }
                else if (field.Type == TypeBool)
                {
                    PutVarint(output, (bool)value ? 1 : 0);
                }
                else
                {
                    PutVarint(output, Convert.ToInt64(value));
                }
                break;
            case 1:
            {
                long bits = field.Type == TypeDouble
                    ? BitConverter.DoubleToInt64Bits(Convert.ToDouble(value))
                    : Convert.ToInt64(value);
                for (int i = 0; i < 8; i++)
                {
                    output.WriteByte((byte)(bits >> (8 * i)));
                }
                break;
            }
            case 5:
            {
                int bits = field.Type == TypeFloat
                    ? BitConverter.SingleToInt32Bits(Convert.ToSingle(value))
                    : Convert.ToInt32(value);
                for (int i = 0; i < 4; i++)
                {
                    output.WriteByte((byte)(bits >> (8 * i)));
                }
                break;
            }
            case 2:
            {
                byte[] data;
                if (field.Type == TypeString)
                {
                    data = System.Text.Encoding.UTF8.GetBytes((string)value);
                }
                else if (field.Type == TypeMessage)
                {
                    data = EncodeGeneric(fileModel.Messages[field.TypeName], (GenericMessage)value, fileModel);
                }
                else
                {
                    data = (byte[])value;
                }
                PutVarint(output, data.Length);
                output.Write(data, 0, data.Length);
                break;
            }
        }
    }

    /// <summary>Parse bytes into a generic message per its model.</summary>
    public static GenericMessage DecodeGeneric(MessageModel msgModel, byte[] data, FileModel fileModel)
    {
        var msg = new GenericMessage(msgModel);
        foreach (PbReader.Field f in new PbReader(data).All())
        {
            if (!msgModel.Fields.TryGetValue(f.Number, out FieldModel field))
            {
                // Unknown field: retain the raw encoded chunk verbatim.
                msg.Unknown.Add(f.Raw);
                continue;
            }
            if (!msg.Values.TryGetValue(f.Number, out List<object> list))
            {
                list = new List<object>();
                msg.Values[f.Number] = list;
            }
            list.Add(DecodeValue(field, f, fileModel));
        }
        return msg;
    }

    private static object DecodeValue(FieldModel field, PbReader.Field f, FileModel fileModel)
    {
        switch (f.Wire)
        {
            case 0:
                if (field.Type == TypeBool)
                {
                    return f.VarintValue != 0;
                }
                if (field.Type == TypeSint32 || field.Type == TypeSint64)
                {
                    return (f.VarintValue >> 1) ^ -(f.VarintValue & 1);
                }
                if (field.Type == TypeInt32 || field.Type == TypeEnum)
                {
                    return (long)(int)f.VarintValue;
                }
                return f.VarintValue;
            case 1:
            {
                long bits = 0;
                for (int i = 0; i < 8; i++)
                {
                    bits |= (long)f.Bytes[i] << (8 * i);
                }
                if (field.Type == TypeDouble)
                {
                    return BitConverter.Int64BitsToDouble(bits);
                }
                return bits;
            }
            case 5:
            {
                int bits = 0;
                for (int i = 0; i < 4; i++)
                {
                    bits |= f.Bytes[i] << (8 * i);
                }
                if (field.Type == TypeFloat)
                {
                    return BitConverter.Int32BitsToSingle(bits);
                }
                return (long)(uint)bits;
            }
            default:
                if (field.Type == TypeString)
                {
                    return System.Text.Encoding.UTF8.GetString(f.Bytes);
                }
                if (field.Type == TypeMessage)
                {
                    return DecodeGeneric(fileModel.Messages[field.TypeName], f.Bytes, fileModel);
                }
                return f.Bytes;
        }
    }

    // -- client / server surfaces --

    private sealed class BoundMessage : IMarshaler, IUnmarshaler
    {
        private readonly MessageModel _model;
        private readonly FileModel _file;

        public GenericMessage Generic { get; set; }

        internal BoundMessage(MessageModel model, GenericMessage generic, FileModel file)
        {
            _model = model;
            Generic = generic;
            _file = file;
        }

        public byte[] MarshalDc() => EncodeGeneric(_model, Generic, _file);

        public void UnmarshalDc(byte[] data) => Generic = DecodeGeneric(_model, data, _file);
    }

    /// <summary>Runtime-built client: methods resolve from the FileModel.</summary>
    public sealed class DynamicClient
    {
        private readonly Channel _channel;
        private readonly FileModel _model;

        public DynamicClient(Channel channel, FileModel model)
        {
            _channel = channel;
            _model = model;
        }

        private MethodModel Method(string service, string method)
        {
            if (!_model.Services.TryGetValue(service, out ServiceModel svc))
            {
                throw new StatusException(Wire.CodeInvalidArgument, $"unknown service {service}");
            }
            if (!svc.Methods.TryGetValue(method, out MethodModel m))
            {
                throw new StatusException(Wire.CodeInvalidArgument, $"unknown method {method}");
            }
            return m;
        }

        public GenericMessage Unary(string service, string method, GenericMessage req,
            IDictionary<string, string> metadata = null)
        {
            MethodModel m = Method(service, method);
            var resp = new BoundMessage(m.Output, new GenericMessage(m.Output), _model);
            _channel.Unary(m.Path, new BoundMessage(m.Input, req, _model), resp, metadata);
            return resp.Generic;
        }

        /// <summary>Receiving stream of generic responses.</summary>
        public sealed class DynamicStream
        {
            private readonly Channel.ClientStream _stream;
            private readonly MessageModel _output;
            private readonly FileModel _file;

            internal DynamicStream(Channel.ClientStream stream, MessageModel output, FileModel file)
            {
                _stream = stream;
                _output = output;
                _file = file;
            }

            /// <summary>Next response; EndOfStreamException at end.</summary>
            public GenericMessage Recv()
            {
                var resp = new BoundMessage(_output, new GenericMessage(_output), _file);
                _stream.Recv(resp);
                return resp.Generic;
            }
        }

        public DynamicStream ServerStream(string service, string method, GenericMessage req,
            IDictionary<string, string> metadata = null)
        {
            MethodModel m = Method(service, method);
            return new DynamicStream(
                _channel.ServerStream(m.Path, new BoundMessage(m.Input, req, _model), metadata),
                m.Output, _model);
        }

        public GenericMessage ClientStream(string service, string method, IEnumerable<GenericMessage> reqs,
            IDictionary<string, string> metadata = null)
        {
            MethodModel m = Method(service, method);
            var bound = reqs.Select(r => new BoundMessage(m.Input, r, _model)).ToList();
            var resp = new BoundMessage(m.Output, new GenericMessage(m.Output), _model);
            _channel.ClientStreamCall(m.Path, bound, resp, metadata);
            return resp.Generic;
        }

        public DynamicStream Bidi(string service, string method, IEnumerable<GenericMessage> reqs,
            IDictionary<string, string> metadata = null)
        {
            MethodModel m = Method(service, method);
            var bound = reqs.Select(r => new BoundMessage(m.Input, r, _model)).ToList();
            return new DynamicStream(_channel.Bidi(m.Path, bound, metadata), m.Output, _model);
        }
    }

    /// <summary>Receives generic requests; EndOfStreamException at half-close.</summary>
    public delegate GenericMessage RecvFn();

    /// <summary>Sends one generic response.</summary>
    public delegate void SendFn(GenericMessage resp);

    /// <summary>Implements a service with generic messages.</summary>
    public interface IDynamicHandler
    {
        GenericMessage Unary(Endpoint.CallContext ctx, MethodModel method, GenericMessage req);

        void ServerStream(Endpoint.CallContext ctx, MethodModel method, GenericMessage req, SendFn send);

        GenericMessage ClientStream(Endpoint.CallContext ctx, MethodModel method, RecvFn recv);

        void Bidi(Endpoint.CallContext ctx, MethodModel method, RecvFn recv, SendFn send);
    }

    /// <summary>Register a runtime-built service on a Server.</summary>
    public static void RegisterDynamicService(Server server, FileModel fileModel, string serviceName,
        IDynamicHandler handler)
    {
        if (!fileModel.Services.TryGetValue(serviceName, out ServiceModel service))
        {
            throw new StatusException(Wire.CodeInvalidArgument, $"unknown service {serviceName}");
        }
        var methods = new List<Server.Method>();
        foreach (MethodModel method in service.Methods.Values)
        {
            MethodModel m = method;
            methods.Add(new Server.Method(m.Name, m.Path, m.Kind, (ctx, reqs, sink) =>
            {
                GenericMessage Recv() => DecodeGeneric(m.Input, reqs.RecvRaw(), fileModel);
                void Send(GenericMessage resp) => sink(EncodeGeneric(m.Output, resp, fileModel));
                switch (m.Kind)
                {
                    case Server.KindUnary:
                        Send(handler.Unary(ctx, m, Recv()));
                        break;
                    case Server.KindServerStreaming:
                        handler.ServerStream(ctx, m, Recv(), Send);
                        break;
                    case Server.KindClientStreaming:
                        Send(handler.ClientStream(ctx, m, Recv));
                        break;
                    default:
                        handler.Bidi(ctx, m, Recv, Send);
                        break;
                }
            }));
        }
        server.RegisterService(new Server.ServiceDesc(service.FullName, methods));
    }
}
GRPC_RUNTIME_EOF
)
