#lang racket

;;; runtime-php.rkt — the PHP gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under php/grpcdc/ are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)
;;;
;;; PHP >= 8.1, standard library only. PHP CLI has no threads, so
;;; the endpoint is single-threaded and cooperative like the Lua
;;; runtime: Endpoint::pump() processes one inbound message and
;;; client calls loop on pump (peerPump hook for in-process peers).
;;; Deadlines are therefore checked between messages and cannot
;;; preempt a running handler (documented transport caveat).

(require "spec.rkt")
(provide emit-php-runtime-files)

(define php-codec-body
#<<GRPC_RUNTIME_EOF
// Codec + status types for gRPC over WebRTC DataChannels.
//
// Wire protocol in ../SPEC.md. Frame, status, channel and server
// semantics mirror the Lua and Ruby runtimes; the tables in
// wire_gen.php are stamped by the Racket metaprogram.

namespace Grpcdc;

require_once __DIR__ . "/wire_gen.php";

/** A gRPC status (code + message) carried as an exception. */
class StatusError extends \Exception
{
    public int $statusCode;
    public string $statusMessage;

    public function __construct(int $code, string $message = "")
    {
        parent::__construct($message);
        $this->statusCode = $code;
        $this->statusMessage = $message;
    }

    public function __toString(): string
    {
        return Status::name($this->statusCode) . ": " . $this->statusMessage;
    }
}

/** The call completed OK (client-side stream end marker). */
class CallClosed extends \Exception
{
}

/** Canonical status names and conversions. */
final class Status
{
    public static function name(int $code): string
    {
        return Wire::STATUS_NAMES[$code] ?? ("CODE_" . $code);
    }

    /** Convert any throwable to StatusError (OK for null). */
    public static function toStatus(?\Throwable $err): StatusError
    {
        if ($err === null) {
            return new StatusError(Wire::CODE_OK, "");
        }
        if ($err instanceof StatusError) {
            return $err;
        }
        return new StatusError(Wire::CODE_INTERNAL, $err->getMessage());
    }
}

/** A parsed HEADERS payload: path=null marks response headers. */
class Headers
{
    public ?string $path;
    /** @var array<string,string> */
    public array $metadata;

    public function __construct(?string $path = null, array $metadata = [])
    {
        $this->path = $path;
        $this->metadata = $metadata;
    }
}

/** Frame codec (one DataChannel message = one frame). */
final class Codec
{
    public const HEADER_LEN = 9;
    public const MAX_DATA_PAYLOAD = 16 * 1024 * 1024;

    /** Build one DataChannel message: header + payload. */
    public static function encodeFrame(int $frameType, int $streamId, string $payload): string
    {
        if (!in_array($frameType, Wire::FRAME_NAMES, true)) {
            throw new StatusError(Wire::CODE_INVALID_ARGUMENT, "unknown frame type $frameType");
        }
        if ($frameType === Wire::FRAME_DATA && strlen($payload) > self::MAX_DATA_PAYLOAD) {
            throw new StatusError(Wire::CODE_RESOURCE_EXHAUSTED, "DATA payload exceeds 16 MiB");
        }
        return pack("CNN", $frameType, $streamId, strlen($payload)) . $payload;
    }

    /** Parse one DataChannel message -> [frameType, streamId, payload]. */
    public static function decodeFrame(string $data): array
    {
        if (strlen($data) < self::HEADER_LEN) {
            throw new StatusError(
                Wire::CODE_INVALID_ARGUMENT,
                "frame shorter than 9-byte header: " . strlen($data) . " bytes"
            );
        }
        $parts = unpack("Ctype/Nstream/Nlength", substr($data, 0, self::HEADER_LEN));
        $length = $parts["length"];
        if ($length !== strlen($data) - self::HEADER_LEN) {
            throw new StatusError(
                Wire::CODE_INVALID_ARGUMENT,
                "payload length $length does not match message size " . strlen($data)
            );
        }
        return [$parts["type"], $parts["stream"], substr($data, self::HEADER_LEN)];
    }

    public static function headersFrame(int $streamId, ?string $path, ?array $metadata): string
    {
        $body = [];
        if ($path !== null) {
            $body["path"] = $path;
        }
        if ($metadata !== null && count($metadata) > 0) {
            $body["metadata"] = $metadata;
        }
        return self::encodeFrame(Wire::FRAME_HEADERS, $streamId, json_encode((object)$body));
    }

    public static function parseHeaders(string $payload): Headers
    {
        try {
            $body = json_decode($payload, true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            throw new StatusError(Wire::CODE_INVALID_ARGUMENT, "bad HEADERS payload: " . $e->getMessage());
        }
        if (!is_array($body)) {
            throw new StatusError(Wire::CODE_INVALID_ARGUMENT, "HEADERS payload is not an object");
        }
        $metadata = $body["metadata"] ?? [];
        if (!is_array($metadata)) {
            throw new StatusError(Wire::CODE_INVALID_ARGUMENT, "HEADERS metadata is not an object");
        }
        return new Headers($body["path"] ?? null, $metadata);
    }

    // gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
    // units H/M/S/m/u/n (at most 8 digits). Encoding uses
    // milliseconds (seconds past the digit limit), rounded up.
    public static function encodeTimeout(float $seconds): string
    {
        $ms = (int)ceil($seconds * 1000.0);
        if ($ms <= 99999999) {
            return $ms . "m";
        }
        return ((int)ceil($seconds)) . "S";
    }

    /** Decoded grpc-timeout in seconds, or null when malformed. */
    public static function parseTimeout($text): ?float
    {
        if (!is_string($text) || strlen($text) < 2 || strlen($text) > 9) {
            return null;
        }
        $digits = substr($text, 0, -1);
        if (!ctype_digit($digits)) {
            return null;
        }
        $n = (float)$digits;
        switch (substr($text, -1)) {
            case "H":
                return $n * 3600.0;
            case "M":
                return $n * 60.0;
            case "S":
                return $n;
            case "m":
                return $n / 1000.0;
            case "u":
                return $n / 1000000.0;
            case "n":
                return $n / 1000000000.0;
        }
        return null;
    }

    public static function statusFrame(int $frameType, int $streamId, StatusError $status): string
    {
        $body = ["code" => $status->statusCode, "message" => $status->statusMessage];
        return self::encodeFrame($frameType, $streamId, json_encode($body));
    }

    public static function parseStatus(string $payload): StatusError
    {
        try {
            $body = json_decode($payload, true, 512, JSON_THROW_ON_ERROR);
            if (!is_array($body) || !isset($body["code"])) {
                return new StatusError(Wire::CODE_UNKNOWN, "malformed trailers");
            }
            return new StatusError((int)$body["code"], (string)($body["message"] ?? ""));
        } catch (\JsonException $e) {
            return new StatusError(Wire::CODE_UNKNOWN, "malformed trailers");
        }
    }
}
GRPC_RUNTIME_EOF
)

(define php-endpoint-body
#<<GRPC_RUNTIME_EOF
// Endpoint: multiplexes grpc-dc streams over one Transport.
//
// Single-threaded cooperative model (PHP CLI has no threads):
// pump() processes at most one inbound transport message, running
// server handlers inline; client calls loop on pump() — consulting
// the transport's peerPump hook when idle so an in-process loopback
// peer makes progress. Blocking transports (stdio) simply block
// inside recvMessage during pump().

namespace Grpcdc;

require_once __DIR__ . "/codec.php";
require_once __DIR__ . "/wire_gen.php";

/**
 * Carries whole DataChannel messages (boundaries preserved).
 * recvMessage returns one message, or null when nothing is
 * available right now (or the transport is closed).
 */
abstract class Transport
{
    /** @var null|\Closure():bool drives the in-process peer, when any */
    public $peerPump = null;

    /** True once the transport is known closed/EOF (recv can never succeed). */
    public bool $gone = false;

    abstract public function send(string $data): void;

    abstract public function recvMessage(): ?string;

    public function close(): void
    {
    }
}

/** One stream event (headers/data/half_close/trailers/rst). */
class StreamEvent
{
    public string $kind;
    public ?Headers $headers;
    public ?string $payload;
    public ?StatusError $status;

    public function __construct(string $kind, ?Headers $headers = null, ?string $payload = null, ?StatusError $status = null)
    {
        $this->kind = $kind;
        $this->headers = $headers;
        $this->payload = $payload;
        $this->status = $status;
    }
}

/** Receiving queue of one stream; closed after a terminal event. */
class StreamInput
{
    /** @var StreamEvent[] */
    private array $items = [];
    public bool $closedFlag = false;

    public function put(StreamEvent $event): void
    {
        if ($this->closedFlag) {
            return;
        }
        $this->items[] = $event;
    }

    public function close(): void
    {
        $this->closedFlag = true;
    }

    /** Next event, or null when empty. Never blocks. */
    public function get(): ?StreamEvent
    {
        if (count($this->items) > 0) {
            return array_shift($this->items);
        }
        return null;
    }

    public function hasData(): bool
    {
        return count($this->items) > 0;
    }
}

/** Sends response payloads of one inbound call. */
class ResponseSink
{
    private Endpoint $endpoint;
    private int $streamId;

    public function __construct(Endpoint $endpoint, int $streamId)
    {
        $this->endpoint = $endpoint;
        $this->streamId = $streamId;
    }

    public function send(string $payload): void
    {
        $this->endpoint->sendFrame(Codec::encodeFrame(Wire::FRAME_DATA, $this->streamId, $payload));
    }

    public function sendHeaders(): void
    {
        $this->endpoint->sendFrame(Codec::headersFrame($this->streamId, null, null));
    }

    public function sendTrailers(StatusError $status): void
    {
        $this->endpoint->sendFrame(Codec::statusFrame(Wire::FRAME_TRAILERS, $this->streamId, $status));
    }
}

/** Per-call context: metadata sent in HEADERS, plus deadline. */
class CallContext
{
    /** @var array<string,string> */
    public array $metadata;
    public ?float $deadline;

    public function __construct(array $metadata = [])
    {
        $this->metadata = $metadata;
        $remaining = Codec::parseTimeout($metadata["grpc-timeout"] ?? null);
        $this->deadline = $remaining === null ? null : Endpoint::nowSeconds() + $remaining;
    }

    /** Seconds left before the deadline, or null when unbounded. */
    public function timeRemaining(): ?float
    {
        if ($this->deadline === null) {
            return null;
        }
        return max(0.0, $this->deadline - Endpoint::nowSeconds());
    }

    public function deadlineExceeded(): bool
    {
        return $this->timeRemaining() === 0.0;
    }
}

/** Multiplexes grpc-dc streams over one Transport. */
class Endpoint
{
    public Transport $transport;
    /** @var null|\Closure(CallContext, Headers, StreamInput, ResponseSink): ?StatusError */
    public $dispatcher = null;
    private int $nextId;
    /** @var array<int, StreamInput> */
    private array $streams = [];
    public bool $closed = false;

    /** The side that created the channel allocates odd ids, the answerer even. */
    public function __construct(Transport $transport, bool $creator)
    {
        $this->transport = $transport;
        $this->nextId = $creator ? 1 : 2;
    }

    public static function nowSeconds(): float
    {
        return microtime(true);
    }

    public function setDispatcher(\Closure $dispatcher): void
    {
        $this->dispatcher = $dispatcher;
    }

    public function sendFrame(string $frame): void
    {
        $this->transport->send($frame);
    }

    /** @return array{0:int, 1:StreamInput} */
    public function openStream(): array
    {
        $id = $this->nextId;
        $this->nextId += 2;
        $input = new StreamInput();
        $this->streams[$id] = $input;
        return [$id, $input];
    }

    public function closeStream(int $id): void
    {
        unset($this->streams[$id]);
    }

    public function streamInput(int $id): ?StreamInput
    {
        return $this->streams[$id] ?? null;
    }

    /**
     * Abort one stream: RST towards the peer; a pending recv wakes
     * with the cancellation status (the local input is closed with
     * a synthetic RST event).
     */
    public function cancelStream(int $id): void
    {
        $status = new StatusError(Wire::CODE_CANCELLED, "call cancelled");
        $input = $this->streams[$id] ?? null;
        unset($this->streams[$id]);
        if ($input !== null) {
            $input->put(new StreamEvent("rst", null, null, $status));
            $input->close();
        }
        try {
            $this->sendFrame(Codec::statusFrame(Wire::FRAME_RST, $id, $status));
        } catch (\Throwable $ignored) {
        }
    }

    public function close(): void
    {
        if ($this->closed) {
            return;
        }
        $this->closed = true;
        try {
            $this->transport->close();
        } catch (\Throwable $ignored) {
        }
        $this->failAll();
    }

    public function failAll(): void
    {
        $streams = $this->streams;
        $this->streams = [];
        foreach ($streams as $input) {
            $input->put(new StreamEvent("rst", null, null, new StatusError(Wire::CODE_UNAVAILABLE, "data channel closed")));
            $input->close();
        }
    }

    /**
     * Process at most one inbound message; true when one was
     * processed. Server dispatch runs inline (handlers may pump
     * reentrantly to receive their own request stream).
     */
    public function pump(): bool
    {
        if ($this->closed) {
            return false;
        }
        try {
            $data = $this->transport->recvMessage();
        } catch (CallClosed $e) {
            $this->transport->gone = true;
            $this->failAll();
            return false;
        }
        if ($data === null) {
            return false;
        }
        $this->onBytes($data);
        return true;
    }

    /**
     * Pump until $fn() reports progress. Throws UNAVAILABLE when
     * the transport is known gone; otherwise waits briefly and
     * re-checks (a held-back transport must not mask a deadline
     * that $fn observes, mirroring the Lua pump caveat).
     */
    public function pumpWhile(\Closure $fn): void
    {
        while (!$fn()) {
            if ($this->pump()) {
                continue;
            }
            $peerPump = $this->transport->peerPump;
            if ($peerPump !== null && $peerPump()) {
                continue;
            }
            if ($this->transport->gone || $this->closed) {
                throw new StatusError(Wire::CODE_UNAVAILABLE, "data channel closed");
            }
            usleep(200);
        }
    }

    public function onBytes(string $data): void
    {
        if ($this->closed) {
            return;
        }
        try {
            [$frameType, $streamId, $payload] = Codec::decodeFrame($data);
        } catch (StatusError $e) {
            return; // malformed frame: drop, keep the channel up
        }
        switch ($frameType) {
            case Wire::FRAME_HEADERS:
                $this->onHeaders($streamId, $payload);
                break;
            case Wire::FRAME_DATA:
                $input = $this->streamInput($streamId);
                if ($input !== null) {
                    $input->put(new StreamEvent("data", null, $payload));
                }
                break;
            case Wire::FRAME_TRAILERS:
                $this->onTerminal($streamId, $payload, "trailers");
                break;
            case Wire::FRAME_HALF_CLOSE:
                $input = $this->streamInput($streamId);
                if ($input !== null) {
                    $input->put(new StreamEvent("half_close"));
                }
                break;
            case Wire::FRAME_RST:
                $this->onTerminal($streamId, $payload, "rst");
                break;
            default:
                // Unknown frame type: ignore for forward compatibility.
                break;
        }
    }

    private function onTerminal(int $streamId, string $payload, string $kind): void
    {
        $input = $this->streamInput($streamId);
        if ($input !== null) {
            $input->put(new StreamEvent($kind, null, null, Codec::parseStatus($payload)));
            $input->close();
            $this->closeStream($streamId);
        }
    }

    private function onHeaders(int $streamId, string $payload): void
    {
        try {
            $headers = Codec::parseHeaders($payload);
        } catch (StatusError $e) {
            try {
                $this->sendFrame(Codec::statusFrame(Wire::FRAME_RST, $streamId, Status::toStatus($e)));
            } catch (\Throwable $ignored) {
            }
            return;
        }
        if ($headers->path === null) {
            // Server response headers for one of our outbound streams.
            $input = $this->streamInput($streamId);
            if ($input !== null) {
                $input->put(new StreamEvent("headers", $headers));
            }
            return;
        }
        if ($this->streamInput($streamId) !== null) {
            try {
                $this->sendFrame(Codec::statusFrame(
                    Wire::FRAME_RST,
                    $streamId,
                    new StatusError(Wire::CODE_INTERNAL, "HEADERS for stream already in use")
                ));
            } catch (\Throwable $ignored) {
            }
            return;
        }
        if ($this->dispatcher === null) {
            try {
                $this->sendFrame(Codec::statusFrame(
                    Wire::FRAME_TRAILERS,
                    $streamId,
                    new StatusError(Wire::CODE_UNIMPLEMENTED, "unknown method " . $headers->path)
                ));
            } catch (\Throwable $ignored) {
            }
            return;
        }
        $input = new StreamInput();
        $this->streams[$streamId] = $input;
        $sink = new ResponseSink($this, $streamId);
        try {
            $sink->sendHeaders();
        } catch (\Throwable $e) {
            $this->closeStream($streamId);
            return;
        }
        $ctx = new CallContext($headers->metadata);
        try {
            $result = ($this->dispatcher)($ctx, $headers, $input, $sink);
            $status = $result ?? new StatusError(Wire::CODE_OK, "");
        } catch (\Throwable $e) {
            $status = Status::toStatus($e);
        }
        try {
            $sink->sendTrailers($status);
        } catch (\Throwable $ignored) {
        }
        $this->closeStream($streamId);
    }
}
GRPC_RUNTIME_EOF
)

(define php-channel-body
#<<GRPC_RUNTIME_EOF
// Channel: the client side of one Endpoint.

namespace Grpcdc;

require_once __DIR__ . "/endpoint.php";
require_once __DIR__ . "/wire_gen.php";

/** Client side; allocates odd stream ids on a fresh Endpoint. */
class Channel
{
    public Endpoint $endpoint;

    public function __construct(?Transport $transport = null, ?Endpoint $endpoint = null)
    {
        $this->endpoint = $endpoint ?? new Endpoint($transport, true);
    }

    public function unary(string $path, object $req, object $resp, ?array $metadata = null, ?float $timeout = null): object
    {
        $stream = $this->openCall($path, $metadata, $timeout);
        try {
            $this->sendMessage($stream, $req);
            $this->halfClose($stream);
            $got = false;
            while (true) {
                try {
                    $stream->recv($resp);
                } catch (CallClosed $e) {
                    if (!$got) {
                        throw new StatusError(Wire::CODE_INTERNAL, "call closed with no response");
                    }
                    return $resp;
                }
                if ($got) {
                    throw new StatusError(Wire::CODE_INTERNAL, "unary call received more than one response");
                }
                $got = true;
            }
        } finally {
            $this->endpoint->closeStream($stream->streamId);
        }
    }

    public function serverStream(string $path, object $req, ?array $metadata = null, ?float $timeout = null): ClientStream
    {
        $stream = $this->openCall($path, $metadata, $timeout);
        $this->sendMessage($stream, $req);
        $this->halfClose($stream);
        return $stream;
    }

    public function clientStream(string $path, array $reqs, object $resp, ?array $metadata = null, ?float $timeout = null): object
    {
        $stream = $this->openCall($path, $metadata, $timeout);
        try {
            $this->sendAll($stream, $reqs);
            $got = false;
            while (true) {
                try {
                    $stream->recv($resp);
                } catch (CallClosed $e) {
                    if (!$got) {
                        throw new StatusError(Wire::CODE_INTERNAL, "call closed with no response");
                    }
                    return $resp;
                }
                if ($got) {
                    throw new StatusError(Wire::CODE_INTERNAL, "client-streaming call received more than one response");
                }
                $got = true;
            }
        } finally {
            $this->endpoint->closeStream($stream->streamId);
        }
    }

    public function bidi(string $path, array $reqs, ?array $metadata = null, ?float $timeout = null): ClientStream
    {
        $stream = $this->openCall($path, $metadata, $timeout);
        $this->sendAll($stream, $reqs);
        return $stream;
    }

    private function openCall(string $path, ?array $metadata, ?float $timeout): ClientStream
    {
        $deadline = null;
        if ($timeout !== null) {
            $deadline = Endpoint::nowSeconds() + $timeout;
            $metadata = array_merge($metadata ?? [], ["grpc-timeout" => Codec::encodeTimeout($timeout)]);
        }
        [$streamId, $streamInput] = $this->endpoint->openStream();
        try {
            $this->endpoint->sendFrame(Codec::headersFrame($streamId, $path, $metadata));
        } catch (\Throwable $e) {
            $this->endpoint->closeStream($streamId);
            throw $e;
        }
        $stream = new ClientStream($this->endpoint, $streamId, $streamInput);
        $stream->deadline = $deadline;
        return $stream;
    }

    private function sendMessage(ClientStream $stream, object $msg): void
    {
        $this->endpoint->sendFrame(Codec::encodeFrame(Wire::FRAME_DATA, $stream->streamId, $msg->marshalDc()));
    }

    private function halfClose(ClientStream $stream): void
    {
        $this->endpoint->sendFrame(Codec::encodeFrame(Wire::FRAME_HALF_CLOSE, $stream->streamId, ""));
    }

    private function sendAll(ClientStream $stream, array $reqs): void
    {
        foreach ($reqs as $req) {
            $this->sendMessage($stream, $req);
        }
        $this->halfClose($stream);
    }
}

/** Receives response messages of one call. */
class ClientStream
{
    public Endpoint $endpoint;
    public int $streamId;
    public ?Headers $headers = null;
    public ?float $deadline = null;
    private StreamInput $input;

    public function __construct(Endpoint $endpoint, int $streamId, StreamInput $streamInput)
    {
        $this->endpoint = $endpoint;
        $this->streamId = $streamId;
        $this->input = $streamInput;
    }

    /**
     * Decode the next response into $resp (returns $resp).
     * Throws CallClosed when the call completed OK; StatusError
     * reports the trailers status. Deadlines are checked between
     * messages (cooperative runtime: a handler already running is
     * never preempted).
     */
    public function recv(object $resp): object
    {
        while (true) {
            $event = $this->input->get();
            if ($event === null) {
                if ($this->deadline !== null && Endpoint::nowSeconds() >= $this->deadline) {
                    $this->endpoint->cancelStream($this->streamId);
                    throw new StatusError(Wire::CODE_DEADLINE_EXCEEDED, "deadline exceeded");
                }
                if ($this->input->closedFlag) {
                    throw new StatusError(Wire::CODE_UNAVAILABLE, "data channel closed");
                }
                $input = $this->input;
                $deadline = $this->deadline;
                $this->endpoint->pumpWhile(function () use ($input, $deadline) {
                    return $input->hasData() || $input->closedFlag
                        || ($deadline !== null && Endpoint::nowSeconds() >= $deadline);
                });
                continue;
            }
            switch ($event->kind) {
                case "headers":
                    $this->headers = $event->headers;
                    break;
                case "data":
                    return $resp->unmarshalDc($event->payload);
                case "trailers":
                    if ($event->status->statusCode === Wire::CODE_OK) {
                        throw new CallClosed("call completed");
                    }
                    throw $event->status;
                case "rst":
                    throw $event->status;
            }
        }
    }

    /** Abort this stream (sends RST, wakes a pending recv). */
    public function cancel(): void
    {
        $this->endpoint->cancelStream($this->streamId);
    }
}

/**
 * Fiber receiving stream: same recv contract as ClientStream,
 * executed inside a Fiber so calls compose with fiber-per-request
 * servers (suspends/resumes per message; with no scheduler the
 * behavior is identical to the blocking stream).
 */
class FiberClientStream
{
    private ClientStream $stream;

    public function __construct(ClientStream $stream)
    {
        $this->stream = $stream;
    }

    public function streamId(): int
    {
        return $this->stream->streamId;
    }

    public function headers(): ?Headers
    {
        return $this->stream->headers;
    }

    public function recv(object $resp): object
    {
        $fiber = new \Fiber(function () use ($resp) {
            return $this->stream->recv($resp);
        });
        $fiber->start();
        return $fiber->getReturn();
    }

    public function cancel(): void
    {
        $this->stream->cancel();
    }
}

/** Fiber client facade over Channel. Every call runs inside a dedicated Fiber. */
class FiberChannel
{
    public Channel $channel;

    public function __construct($channel = null, ?Transport $transport = null, ?Endpoint $endpoint = null)
    {
        if ($channel instanceof Channel) {
            $this->channel = $channel;
        } elseif ($channel !== null && $transport === null && $endpoint === null) {
            $this->channel = new Channel($channel); // a bare transport
        } else {
            $this->channel = new Channel($transport, $endpoint);
        }
    }

    public function endpoint(): Endpoint
    {
        return $this->channel->endpoint;
    }

    public function unary(string $path, object $req, object $resp, ?array $metadata = null, ?float $timeout = null): object
    {
        $fiber = new \Fiber(function () use ($path, $req, $resp, $metadata, $timeout) {
            return $this->channel->unary($path, $req, $resp, $metadata, $timeout);
        });
        $fiber->start();
        return $fiber->getReturn();
    }

    public function clientStream(string $path, array $reqs, object $resp, ?array $metadata = null, ?float $timeout = null): object
    {
        $fiber = new \Fiber(function () use ($path, $reqs, $resp, $metadata, $timeout) {
            return $this->channel->clientStream($path, $reqs, $resp, $metadata, $timeout);
        });
        $fiber->start();
        return $fiber->getReturn();
    }

    public function serverStream(string $path, object $req, ?array $metadata = null, ?float $timeout = null): FiberClientStream
    {
        return new FiberClientStream($this->channel->serverStream($path, $req, $metadata, $timeout));
    }

    public function bidi(string $path, array $reqs, ?array $metadata = null, ?float $timeout = null): FiberClientStream
    {
        return new FiberClientStream($this->channel->bidi($path, $reqs, $metadata, $timeout));
    }
}
GRPC_RUNTIME_EOF
)

(define php-server-body
#<<GRPC_RUNTIME_EOF
// Server: dispatches inbound calls to registered methods.

namespace Grpcdc;

require_once __DIR__ . "/codec.php";
require_once __DIR__ . "/endpoint.php";
require_once __DIR__ . "/wire_gen.php";

/** Reads request messages of one inbound call. */
class RequestStream
{
    private Endpoint $endpoint;
    private StreamInput $input;

    public function __construct(Endpoint $endpoint, StreamInput $streamInput)
    {
        $this->endpoint = $endpoint;
        $this->input = $streamInput;
    }

    /** Next request payload; CallClosed at half-close. Pumps reentrantly. */
    public function recvRaw(): string
    {
        while (true) {
            $event = $this->input->get();
            if ($event === null) {
                if ($this->input->closedFlag) {
                    throw new StatusError(Wire::CODE_UNAVAILABLE, "data channel closed");
                }
                $input = $this->input;
                $this->endpoint->pumpWhile(function () use ($input) {
                    return $input->hasData() || $input->closedFlag;
                });
                continue;
            }
            switch ($event->kind) {
                case "data":
                    return $event->payload;
                case "half_close":
                    throw new CallClosed("half-close");
                case "trailers":
                case "rst":
                    throw $event->status;
            }
            // headers on the request side: ignore
        }
    }

    public function recvInto(object $req): object
    {
        return $req->unmarshalDc($this->recvRaw());
    }
}

/** One registered method: handler(ctx, RequestStream, sink). */
class Method
{
    public string $name;
    public string $path;
    public string $kind;
    /** @var \Closure(CallContext, RequestStream, ResponseSink): void */
    public \Closure $handler;

    public function __construct(string $name, string $path, string $kind, \Closure $handler)
    {
        $this->name = $name;
        $this->path = $path;
        $this->kind = $kind;
        $this->handler = $handler;
    }
}

class ServiceDesc
{
    public string $name;
    /** @var Method[] */
    public array $methods;

    public function __construct(string $name, array $methods)
    {
        $this->name = $name;
        $this->methods = $methods;
    }
}

/** Dispatches inbound calls to registered methods. */
class Server
{
    public const KIND_UNARY = "unary";
    public const KIND_SERVER_STREAMING = "server-streaming";
    public const KIND_CLIENT_STREAMING = "client-streaming";
    public const KIND_BIDI = "bidi";

    /** @var array<string, Method> */
    private array $methods = [];

    public function registerService(ServiceDesc $desc): void
    {
        foreach ($desc->methods as $method) {
            $this->methods[$method->path] = $method;
        }
    }

    /** Attach to a transport (even stream ids); returns Endpoint. */
    public function serveTransport(Transport $transport): Endpoint
    {
        $endpoint = new Endpoint($transport, false);
        $this->serveEndpoint($endpoint);
        return $endpoint;
    }

    public function serveEndpoint(Endpoint $endpoint): void
    {
        $endpoint->setDispatcher(function (CallContext $ctx, Headers $headers, StreamInput $input, ResponseSink $sink) use ($endpoint) {
            return $this->dispatch($endpoint, $ctx, $headers, $input, $sink);
        });
    }

    /** Serve until the transport closes (blocking transports drive pump). */
    public function serveForever(Endpoint $endpoint): void
    {
        while (!$endpoint->closed) {
            if (!$endpoint->pump()) {
                break;
            }
        }
    }

    private function dispatch(Endpoint $endpoint, CallContext $ctx, Headers $headers, StreamInput $input, ResponseSink $sink): ?StatusError
    {
        $method = $this->methods[$headers->path] ?? null;
        if ($method === null) {
            return new StatusError(Wire::CODE_UNIMPLEMENTED, "unknown method " . $headers->path);
        }
        try {
            ($method->handler)($ctx, new RequestStream($endpoint, $input), $sink);
        } catch (\Throwable $e) {
            return Status::toStatus($e);
        }
        return null;
    }
}
GRPC_RUNTIME_EOF
)

(define php-loopback-body
#<<GRPC_RUNTIME_EOF
// In-memory transport pair for tests (one queue per direction).

namespace Grpcdc;

require_once __DIR__ . "/endpoint.php";

class MemoryTransport extends Transport
{
    /** @var string[] shared inbox (by reference via ArrayObject) */
    private \ArrayObject $inbox;
    private \ArrayObject $outbox;
    private bool $closedFlag = false;

    public function __construct(\ArrayObject $inbox, \ArrayObject $outbox)
    {
        $this->inbox = $inbox;
        $this->outbox = $outbox;
    }

    public function send(string $data): void
    {
        if ($this->closedFlag) {
            throw new CallClosed("transport closed");
        }
        $this->outbox->append($data);
    }

    public function recvMessage(): ?string
    {
        if ($this->inbox->count() > 0) {
            $item = $this->inbox[0];
            $this->inbox->offsetUnset(0);
            // Reindex so count/offset stay consistent.
            $rest = $this->inbox->getArrayCopy();
            $this->inbox->exchangeArray(array_values($rest));
            if ($item === null) {
                $this->gone = true;
                throw new CallClosed("transport closed");
            }
            return $item;
        }
        return null;
    }

    public function close(): void
    {
        $this->closedFlag = true;
        $this->inbox->append(null);
    }
}

/** Two connected in-memory transports. */
function memoryTransportPair(): array
{
    $aToB = new \ArrayObject([]);
    $bToA = new \ArrayObject([]);
    return [new MemoryTransport($bToA, $aToB), new MemoryTransport($aToB, $bToA)];
}
GRPC_RUNTIME_EOF
)

(define php-init-body
#<<GRPC_RUNTIME_EOF
// grpcdc: gRPC over WebRTC DataChannels (generated runtime).

require_once __DIR__ . "/grpcdc/wire_gen.php";
require_once __DIR__ . "/grpcdc/codec.php";
require_once __DIR__ . "/grpcdc/endpoint.php";
require_once __DIR__ . "/grpcdc/channel.php";
require_once __DIR__ . "/grpcdc/server.php";
require_once __DIR__ . "/grpcdc/loopback.php";
require_once __DIR__ . "/grpcdc/dynamic.php";
GRPC_RUNTIME_EOF
)

(define (emit-php-runtime-files)
  (list
   (cons "grpcdc.php" php-init-body)
   (cons "grpcdc/codec.php" php-codec-body)
   (cons "grpcdc/endpoint.php" php-endpoint-body)
   (cons "grpcdc/channel.php" php-channel-body)
   (cons "grpcdc/server.php" php-server-body)
   (cons "grpcdc/loopback.php" php-loopback-body)
   (cons "grpcdc/dynamic.php" php-dynamic-body)))

(define php-dynamic-body
#<<GRPC_RUNTIME_EOF
// Dynamic, descriptor-driven client and server.
//
// Parses a FileDescriptorSet (as produced by
// `protoc --descriptor_set_out`) at runtime and builds clients
// and servers whose messages are generic field maps — no
// generated stubs required. This is the runtime-generation
// counterpart of the protoc-plugin surfaces: schemas arrive as
// data (descriptor.proto), not as code.
//
// Generic values by field type: varint family -> int,
// string -> string, bytes/message -> string / GenericMessage,
// fixed/float -> int / float, bool -> bool. Repeated
// fields are arrays in field-number order.

namespace Grpcdc;

require_once __DIR__ . "/codec.php";
require_once __DIR__ . "/server.php";
require_once __DIR__ . "/wire_gen.php";

/** Minimal protobuf reader over a binary string. */
class PbReader
{
    private string $buf;
    private int $pos = 0;
    public ?string $lastChunk = null;

    public function __construct(string $data)
    {
        $this->buf = $data;
    }

    public function varint(): int
    {
        $result = 0;
        $shift = 0;
        while (true) {
            if ($this->pos >= strlen($this->buf)) {
                throw new \InvalidArgumentException("truncated varint");
            }
            $b = ord($this->buf[$this->pos]);
            $this->pos++;
            if ($shift === 63) {
                if (($b & 1) !== 0) {
                    $result |= PHP_INT_MIN;
                }
            } elseif ($shift < 63) {
                $result |= ($b & 0x7F) << $shift;
            }
            if (($b & 0x80) === 0) {
                return $result;
            }
            $shift += 7;
            if ($shift >= 70) {
                throw new \InvalidArgumentException("varint too long");
            }
        }
    }

    public function bytesField(): string
    {
        $n = $this->varint();
        if ($this->pos + $n > strlen($this->buf)) {
            throw new \InvalidArgumentException("truncated bytes field");
        }
        $out = substr($this->buf, $this->pos, $n);
        $this->pos += $n;
        return $out;
    }

    /**
     * All fields as [number, wireType, value] triples; lastChunk
     * holds the raw bytes of the most recent field (captured
     * before the consumer processes it).
     */
    public function fields(): array
    {
        $out = [];
        while ($this->pos < strlen($this->buf)) {
            $start = $this->pos;
            $tag = $this->varint();
            $number = $tag >> 3;
            $wire = $tag & 7;
            switch ($wire) {
                case 0:
                    $value = $this->varint();
                    break;
                case 2:
                    $value = $this->bytesField();
                    break;
                case 1:
                    if ($this->pos + 8 > strlen($this->buf)) {
                        throw new \InvalidArgumentException("truncated fixed64");
                    }
                    $value = substr($this->buf, $this->pos, 8);
                    $this->pos += 8;
                    break;
                case 5:
                    if ($this->pos + 4 > strlen($this->buf)) {
                        throw new \InvalidArgumentException("truncated fixed32");
                    }
                    $value = substr($this->buf, $this->pos, 4);
                    $this->pos += 4;
                    break;
                default:
                    throw new \InvalidArgumentException("unsupported wire type $wire");
            }
            $this->lastChunk = substr($this->buf, $start, $this->pos - $start);
            $out[] = [$number, $wire, $value, $this->lastChunk];
        }
        return $out;
    }
}

class FieldModel
{
    public int $number;
    public string $name;
    public int $type;
    public bool $repeated;
    public string $typeName;

    public function __construct(int $number, string $name, int $fieldType, int $label, string $typeName)
    {
        $this->number = $number;
        $this->name = $name;
        $this->type = $fieldType;
        $this->repeated = ($label === Dyn::LABEL_REPEATED);
        $this->typeName = $typeName; // for TYPE_MESSAGE, e.g. ".echo.EchoRequest"
    }
}

class MessageModel
{
    public string $fullName;
    /** @var array<int, FieldModel> */
    public array $fields;
    /** @var array<string, FieldModel> */
    public array $byName = [];

    public function __construct(string $fullName, array $fields)
    {
        $this->fullName = $fullName;
        $this->fields = $fields;
        $this->refreshByName();
    }

    public function refreshByName(): void
    {
        $this->byName = [];
        foreach ($this->fields as $f) {
            $this->byName[$f->name] = $f;
        }
    }
}

class MethodModel
{
    public string $name;
    public string $path;
    public string $kind;
    public MessageModel $input;
    public MessageModel $output;

    public function __construct(string $name, string $path, string $kind, MessageModel $input, MessageModel $output)
    {
        $this->name = $name;
        $this->path = $path;
        $this->kind = $kind;
        $this->input = $input;
        $this->output = $output;
    }
}

class ServiceModel
{
    public string $fullName;
    /** @var array<string, MethodModel> */
    public array $methods;

    public function __construct(string $fullName, array $methods)
    {
        $this->fullName = $fullName;
        $this->methods = $methods;
    }
}

/** Parsed descriptor set: messages and services by full name. */
class FileModel
{
    /** @var array<string, MessageModel> ".echo.EchoRequest" -> model */
    public array $messages = [];
    /** @var array<string, ServiceModel> "echo.Echo" -> model */
    public array $services = [];

    public function message(string $fullName): MessageModel
    {
        return $this->messages[$fullName];
    }

    public function service(string $fullName): ServiceModel
    {
        return $this->services[$fullName];
    }
}

/**
 * A message as field number -> list of values (descriptor order).
 *
 * Fields not in the model are retained as raw encoded chunks in
 * `unknown` (protobuf unknown-field retention): a decode ->
 * encode round trip re-emits them after the known fields, so
 * intermediate hops do not strip newer fields.
 */
class GenericMessage
{
    public ?MessageModel $model;
    /** @var array<int, array> */
    public array $values = [];
    /** @var string[] */
    public array $unknown = [];

    public function __construct(?MessageModel $model = null)
    {
        $this->model = $model;
    }

    public function set(int $number, $value): self
    {
        $this->values[$number] = [$value];
        return $this;
    }

    public function add(int $number, $value): self
    {
        $this->values[$number][] = $value;
        return $this;
    }

    public function getAll(int $number): array
    {
        return $this->values[$number] ?? [];
    }

    public function get(int $number, $default = null)
    {
        $items = $this->values[$number] ?? [];
        return count($items) > 0 ? $items[0] : $default;
    }

    public function getString(int $number, string $default = ""): string
    {
        $value = $this->get($number);
        return is_string($value) ? $value : $default;
    }

    public function getInt(int $number, int $default = 0): int
    {
        $value = $this->get($number);
        return is_int($value) ? $value : $default;
    }

    public function equals(?object $other): bool
    {
        return $other instanceof GenericMessage && $this->values === $other->values;
    }
}

/** Descriptor-driven encode/decode and registration (Grpcdc statics). */
final class Dyn
{
    // FieldDescriptorProto.Type values (descriptor.proto).
    public const TYPE_DOUBLE = 1;
    public const TYPE_FLOAT = 2;
    public const TYPE_INT64 = 3;
    public const TYPE_UINT64 = 4;
    public const TYPE_INT32 = 5;
    public const TYPE_FIXED64 = 6;
    public const TYPE_FIXED32 = 7;
    public const TYPE_BOOL = 8;
    public const TYPE_STRING = 9;
    public const TYPE_GROUP = 10;
    public const TYPE_MESSAGE = 11;
    public const TYPE_BYTES = 12;
    public const TYPE_UINT32 = 13;
    public const TYPE_ENUM = 14;
    public const TYPE_SFIXED32 = 15;
    public const TYPE_SFIXED64 = 16;
    public const TYPE_SINT32 = 17;
    public const TYPE_SINT64 = 18;

    public const LABEL_REPEATED = 3;

    private static function wireType(int $fieldType): int
    {
        switch ($fieldType) {
            case self::TYPE_INT64:
            case self::TYPE_UINT64:
            case self::TYPE_INT32:
            case self::TYPE_BOOL:
            case self::TYPE_UINT32:
            case self::TYPE_ENUM:
            case self::TYPE_SINT32:
            case self::TYPE_SINT64:
                return 0;
            case self::TYPE_FIXED64:
            case self::TYPE_SFIXED64:
            case self::TYPE_DOUBLE:
                return 1;
            case self::TYPE_STRING:
            case self::TYPE_BYTES:
            case self::TYPE_MESSAGE:
            case self::TYPE_GROUP:
                return 2;
            default:
                return 5;
        }
    }

    public static function encodeVarint(int $value): string
    {
        $out = "";
        $v = $value;
        while (true) {
            $b = $v & 0x7F;
            // Logical shift right by 7 on the 64-bit pattern.
            $v = ($v >> 7) & 0x01FFFFFFFFFFFFFF;
            if ($v === 0) {
                $out .= chr($b);
                return $out;
            }
            $out .= chr($b | 0x80);
        }
    }

    public static function encodeGeneric(MessageModel $model, GenericMessage $message, FileModel $fileModel): string
    {
        $out = "";
        $numbers = array_keys($message->values);
        sort($numbers);
        foreach ($numbers as $number) {
            $field = $model->fields[$number] ?? null;
            if ($field === null) {
                throw new StatusError(Wire::CODE_INVALID_ARGUMENT, "unknown field $number for " . $model->fullName);
            }
            $values = $message->values[$number];
            if ($field->repeated) {
                foreach ($values as $value) {
                    $out .= self::encodeValue($field, $value, $fileModel);
                }
            } elseif (count($values) > 0) {
                $out .= self::encodeValue($field, $values[0], $fileModel);
            }
        }
        foreach ($message->unknown as $chunk) {
            $out .= $chunk;
        }
        return $out;
    }

    public static function decodeGeneric(MessageModel $model, string $data, FileModel $fileModel): GenericMessage
    {
        $message = new GenericMessage($model);
        $reader = new PbReader($data);
        foreach ($reader->fields() as [$number, $wire, $raw, $chunk]) {
            $field = $model->fields[$number] ?? null;
            if ($field === null) {
                // Unknown field: retain the raw encoded chunk verbatim.
                $message->unknown[] = $chunk;
                continue;
            }
            $message->values[$number][] = self::decodeValue($field, $wire, $raw, $fileModel);
        }
        return $message;
    }

    /** Parse FileDescriptorSet bytes into a FileModel. */
    public static function parseDescriptorSet(string $data): FileModel
    {
        $fileModel = new FileModel();
        $pendingServices = [];
        foreach ((new PbReader($data))->fields() as [$number, $wire, $fileBytes]) {
            if ($number !== 1) {
                continue;
            }
            $package = "";
            $serviceTypes = [];
            $fieldsOfFile = (new PbReader($fileBytes))->fields();
            foreach ($fieldsOfFile as [$fnum, $w, $fval]) {
                if ($fnum === 2) {
                    $package = $fval;
                }
            }
            foreach ($fieldsOfFile as [$fnum, $w, $fval]) {
                if ($fnum === 4) {
                    self::parseMessage($package, $fval, $fileModel);
                } elseif ($fnum === 6) {
                    $serviceTypes[] = [$package, $fval];
                }
            }
            foreach ($serviceTypes as $st) {
                $pendingServices[] = $st;
            }
        }
        foreach ($pendingServices as [$package, $bytes]) {
            self::parseService($package, $bytes, $fileModel);
        }
        return $fileModel;
    }

    /**
     * Register a runtime-built service on a Server.
     *
     * $handler is an object with methods by kind:
     *   unary(ctx, method, request) -> GenericMessage
     *   serverStream(ctx, method, request, send) -> null
     *   clientStream(ctx, method, requestGenerator) -> GenericMessage
     *   bidi(ctx, method, requestGenerator, send) -> null
     * where send is a callable taking a GenericMessage and the
     * request generator yields GenericMessages until half-close.
     */
    public static function registerDynamicService(Server $server, FileModel $fileModel, string $serviceName, object $handler): void
    {
        $service = $fileModel->services[$serviceName];
        $methods = [];
        foreach ($service->methods as $method) {
            $methods[] = new Method($method->name, $method->path, $method->kind, self::makeHandler($handler, $method, $fileModel));
        }
        $server->registerService(new ServiceDesc($service->fullName, $methods));
    }

    private static function toSigned(int $value, int $bits): int
    {
        if ($bits === 32) {
            $v = $value & 0xFFFFFFFF;
            return $v >= 0x80000000 ? $v - 0x100000000 : $v;
        }
        return $value; // PHP ints are signed 64-bit already
    }

    private static function zigzagDecode(int $value): int
    {
        return ($value >> 1) ^ -($value & 1);
    }

    private static function zigzagEncode(int $value): int
    {
        return ($value << 1) ^ ($value >> 63);
    }

    private static function encodeValue(FieldModel $field, $value, FileModel $fileModel): string
    {
        $wire = self::wireType($field->type);
        $out = self::encodeVarint(($field->number << 3) | $wire);
        switch ($wire) {
            case 0:
                if ($field->type === self::TYPE_SINT32 || $field->type === self::TYPE_SINT64) {
                    $bits = $field->type === self::TYPE_SINT32 ? 32 : 64;
                    $enc = self::zigzagEncode((int)$value);
                    if ($bits === 32) {
                        $enc &= 0xFFFFFFFF;
                    }
                    $out .= self::encodeVarint($enc);
                } elseif ($field->type === self::TYPE_BOOL) {
                    $out .= self::encodeVarint($value ? 1 : 0);
                } else {
                    $out .= self::encodeVarint((int)$value);
                }
                break;
            case 1:
                if ($field->type === self::TYPE_DOUBLE) {
                    $out .= pack("e", (float)$value);
                } elseif ($field->type === self::TYPE_SFIXED64) {
                    $out .= pack("q", (int)$value);
                } else {
                    $out .= pack("Q", (int)$value);
                }
                break;
            case 5:
                if ($field->type === self::TYPE_FLOAT) {
                    $out .= pack("g", (float)$value);
                } elseif ($field->type === self::TYPE_SFIXED32) {
                    $v = (int)$value & 0xFFFFFFFF;
                    $out .= pack("V", $v);
                } else {
                    $out .= pack("V", (int)$value & 0xFFFFFFFF);
                }
                break;
            default:
                if ($field->type === self::TYPE_STRING) {
                    $data = (string)$value;
                } elseif ($field->type === self::TYPE_MESSAGE) {
                    $data = self::encodeGeneric($fileModel->messages[$field->typeName], $value, $fileModel);
                } else {
                    $data = (string)$value;
                }
                $out .= self::encodeVarint(strlen($data));
                $out .= $data;
                break;
        }
        return $out;
    }

    private static function decodeValue(FieldModel $field, int $wire, $raw, FileModel $fileModel)
    {
        switch ($wire) {
            case 0:
                switch ($field->type) {
                    case self::TYPE_BOOL:
                        return $raw !== 0;
                    case self::TYPE_SINT32:
                    case self::TYPE_SINT64:
                        return self::zigzagDecode($raw);
                    case self::TYPE_INT32:
                    case self::TYPE_ENUM:
                        return self::toSigned($raw, 32);
                    case self::TYPE_INT64:
                        return self::toSigned($raw, 64);
                    default:
                        return $raw;
                }
            case 1:
                switch ($field->type) {
                    case self::TYPE_DOUBLE:
                        return unpack("e", $raw)[1];
                    case self::TYPE_SFIXED64:
                        return unpack("q", $raw)[1];
                    default:
                        return unpack("Q", $raw)[1];
                }
            case 5:
                switch ($field->type) {
                    case self::TYPE_FLOAT:
                        return unpack("g", $raw)[1];
                    case self::TYPE_SFIXED32:
                        $v = unpack("V", $raw)[1];
                        return $v >= 0x80000000 ? $v - 0x100000000 : $v;
                    default:
                        return unpack("V", $raw)[1];
                }
            default:
                switch ($field->type) {
                    case self::TYPE_STRING:
                        return $raw;
                    case self::TYPE_MESSAGE:
                        return self::decodeGeneric($fileModel->messages[$field->typeName], $raw, $fileModel);
                    default:
                        return $raw;
                }
        }
    }

    private static function parseMessage(string $package, string $data, FileModel $fileModel): MessageModel
    {
        $name = "";
        $rawFields = [];
        $nested = [];
        foreach ((new PbReader($data))->fields() as [$fnum, $w, $fval]) {
            if ($fnum === 1) {
                $name = $fval;
            } elseif ($fnum === 2) {
                $rawFields[] = $fval;
            } elseif ($fnum === 3) {
                $nested[] = $fval;
            }
        }
        $fullName = $package === "" ? $name : $package . "." . $name;
        $fields = [];
        $model = new MessageModel($fullName, $fields);
        $fileModel->messages["." . $fullName] = $model;
        foreach ($nested as $bytes) {
            self::parseNested($package, $name, $bytes, $fileModel);
        }
        foreach ($rawFields as $fieldBytes) {
            $field = self::parseField($fieldBytes);
            $fields[$field->number] = $field;
        }
        $model->fields = $fields;
        $model->refreshByName();
        return $model;
    }

    private static function parseNested(string $package, string $outer, string $data, FileModel $fileModel): MessageModel
    {
        $name = "";
        $rawFields = [];
        foreach ((new PbReader($data))->fields() as [$fnum, $w, $fval]) {
            if ($fnum === 1) {
                $name = $fval;
            } elseif ($fnum === 2) {
                $rawFields[] = $fval;
            }
        }
        $fullName = $package === "" ? $outer . "." . $name : $package . "." . $outer . "." . $name;
        $fields = [];
        $model = new MessageModel($fullName, $fields);
        $fileModel->messages["." . $fullName] = $model;
        foreach ($rawFields as $fieldBytes) {
            $field = self::parseField($fieldBytes);
            $fields[$field->number] = $field;
        }
        $model->fields = $fields;
        $model->refreshByName();
        return $model;
    }

    private static function parseField(string $data): FieldModel
    {
        $name = "";
        $number = 0;
        $label = 1;
        $fieldType = 0;
        $typeName = "";
        foreach ((new PbReader($data))->fields() as [$fnum, $w, $fval]) {
            if ($fnum === 1) {
                $name = $fval;
            } elseif ($fnum === 3) {
                $number = $fval;
            } elseif ($fnum === 4) {
                $label = $fval;
            } elseif ($fnum === 5) {
                $fieldType = $fval;
            } elseif ($fnum === 6) {
                $typeName = $fval;
            }
        }
        return new FieldModel($number, $name, $fieldType, $label, $typeName);
    }

    private static function kindOf(bool $clientStreaming, bool $serverStreaming): string
    {
        if ($clientStreaming && $serverStreaming) {
            return Server::KIND_BIDI;
        } elseif ($serverStreaming) {
            return Server::KIND_SERVER_STREAMING;
        } elseif ($clientStreaming) {
            return Server::KIND_CLIENT_STREAMING;
        }
        return Server::KIND_UNARY;
    }

    private static function parseService(string $package, string $data, FileModel $fileModel): ServiceModel
    {
        $name = "";
        $rawMethods = [];
        foreach ((new PbReader($data))->fields() as [$fnum, $w, $fval]) {
            if ($fnum === 1) {
                $name = $fval;
            } elseif ($fnum === 2) {
                $rawMethods[] = $fval;
            }
        }
        $fullName = $package === "" ? $name : $package . "." . $name;
        $methods = [];
        foreach ($rawMethods as $methodBytes) {
            $mname = "";
            $inputType = "";
            $outputType = "";
            $clientStreaming = false;
            $serverStreaming = false;
            foreach ((new PbReader($methodBytes))->fields() as [$fnum, $w, $fval]) {
                if ($fnum === 1) {
                    $mname = $fval;
                } elseif ($fnum === 2) {
                    $inputType = $fval;
                } elseif ($fnum === 3) {
                    $outputType = $fval;
                } elseif ($fnum === 5) {
                    $clientStreaming = $fval !== 0;
                } elseif ($fnum === 6) {
                    $serverStreaming = $fval !== 0;
                }
            }
            $methods[$mname] = new MethodModel(
                $mname,
                "/" . $fullName . "/" . $mname,
                self::kindOf($clientStreaming, $serverStreaming),
                $fileModel->messages[$inputType],
                $fileModel->messages[$outputType]
            );
        }
        $service = new ServiceModel($fullName, $methods);
        $fileModel->services[$fullName] = $service;
        return $service;
    }

    private static function makeHandler(object $handler, MethodModel $method, FileModel $fileModel): \Closure
    {
        return function (CallContext $ctx, RequestStream $reqs, ResponseSink $sink) use ($handler, $method, $fileModel) {
            $send = function (GenericMessage $generic) use ($sink, $method, $fileModel) {
                $sink->send(Dyn::encodeGeneric($method->output, $generic, $fileModel));
            };
            $requests = (function () use ($reqs, $method, $fileModel) {
                while (true) {
                    try {
                        $payload = $reqs->recvRaw();
                    } catch (CallClosed $e) {
                        return;
                    }
                    yield Dyn::decodeGeneric($method->input, $payload, $fileModel);
                }
            })();
            switch ($method->kind) {
                case Server::KIND_UNARY:
                    $requests->rewind();
                    $send($handler->unary($ctx, $method, $requests->current()));
                    break;
                case Server::KIND_SERVER_STREAMING:
                    $requests->rewind();
                    $handler->serverStream($ctx, $method, $requests->current(), $send);
                    break;
                case Server::KIND_CLIENT_STREAMING:
                    $send($handler->clientStream($ctx, $method, $requests));
                    break;
                default:
                    $handler->bidi($ctx, $method, $requests, $send);
                    break;
            }
        };
    }
}

/** Adapts a (MessageModel, GenericMessage) pair to the Channel marshal/unmarshal contract. */
class BoundMessage
{
    public MessageModel $model;
    public GenericMessage $generic;
    public FileModel $fileModel;

    public function __construct(MessageModel $model, ?GenericMessage $generic, FileModel $fileModel)
    {
        $this->model = $model;
        $this->generic = $generic ?? new GenericMessage($model);
        $this->fileModel = $fileModel;
    }

    public function marshalDc(): string
    {
        return Dyn::encodeGeneric($this->model, $this->generic, $this->fileModel);
    }

    public function unmarshalDc(string $data): self
    {
        $this->generic = Dyn::decodeGeneric($this->model, $data, $this->fileModel);
        return $this;
    }
}

class DynamicRecvStream
{
    private object $stream;
    private MessageModel $model;
    private FileModel $fileModel;

    public function __construct(object $stream, MessageModel $model, FileModel $fileModel)
    {
        $this->stream = $stream;
        $this->model = $model;
        $this->fileModel = $fileModel;
    }

    /** Next response GenericMessage; CallClosed at end. */
    public function recv(): GenericMessage
    {
        return $this->stream->recv(new BoundMessage($this->model, null, $this->fileModel))->generic;
    }

    /** @return \Generator<int, GenericMessage> */
    public function iterate(): \Generator
    {
        try {
            while (true) {
                yield $this->recv();
            }
        } catch (CallClosed $e) {
            return;
        }
    }
}

/** Runtime-built client: methods resolve from the FileModel. */
class DynamicClient
{
    private Channel $channel;
    private FileModel $model;

    public function __construct(Channel $channel, FileModel $fileModel)
    {
        $this->channel = $channel;
        $this->model = $fileModel;
    }

    public function unary(string $serviceName, string $methodName, GenericMessage $request, ?array $metadata = null, ?float $timeout = null): GenericMessage
    {
        $method = $this->resolve($serviceName, $methodName);
        $resp = new BoundMessage($method->output, null, $this->model);
        $this->channel->unary($method->path, new BoundMessage($method->input, $request, $this->model), $resp, $metadata, $timeout);
        return $resp->generic;
    }

    public function serverStream(string $serviceName, string $methodName, GenericMessage $request, ?array $metadata = null, ?float $timeout = null): DynamicRecvStream
    {
        $method = $this->resolve($serviceName, $methodName);
        $stream = $this->channel->serverStream($method->path, new BoundMessage($method->input, $request, $this->model), $metadata, $timeout);
        return new DynamicRecvStream($stream, $method->output, $this->model);
    }

    public function clientStream(string $serviceName, string $methodName, array $requests, ?array $metadata = null, ?float $timeout = null): GenericMessage
    {
        $method = $this->resolve($serviceName, $methodName);
        $resp = new BoundMessage($method->output, null, $this->model);
        $bound = array_map(function ($r) use ($method) {
            return new BoundMessage($method->input, $r, $this->model);
        }, $requests);
        $this->channel->clientStream($method->path, $bound, $resp, $metadata, $timeout);
        return $resp->generic;
    }

    public function bidi(string $serviceName, string $methodName, array $requests, ?array $metadata = null, ?float $timeout = null): DynamicRecvStream
    {
        $method = $this->resolve($serviceName, $methodName);
        $bound = array_map(function ($r) use ($method) {
            return new BoundMessage($method->input, $r, $this->model);
        }, $requests);
        $stream = $this->channel->bidi($method->path, $bound, $metadata, $timeout);
        return new DynamicRecvStream($stream, $method->output, $this->model);
    }

    private function resolve(string $serviceName, string $methodName): MethodModel
    {
        return $this->model->services[$serviceName]->methods[$methodName];
    }
}
GRPC_RUNTIME_EOF
)
