#lang racket

;;; runtime-cpp.rkt — the C++ gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under cpp/grpcdc/ are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)
;;;
;;; C++17, standard library only — no external packages.

(require "spec.rkt")
(provide emit-cpp-runtime-files)

(define cpp-status-body
#<<GRPC_RUNTIME_EOF
#pragma once

#include <exception>
#include <optional>
#include <random>
#include <string>
#include <vector>

#include "grpcdc/wire.hpp"

namespace grpcdc {

/// Thrown at end of a receiving stream (call completed OK).
struct EndOfStream : std::exception {
  const char* what() const noexcept override { return "end of stream"; }
};

/// Homegrown tracing: W3C traceparent propagation with a span
/// observer. Dormant until Tracing::SetTracer registers one;
/// generated code stays dependency-free (sampling and export are
/// the application's problem).
struct Tracing {
  struct Tracer {
    virtual ~Tracer() = default;
    virtual void OnStart(const std::string& kind, const std::string& method,
                         const std::string& trace_id, const std::string& span_id,
                         const std::string& parent_span_id) = 0;
    virtual void OnEnd(const std::string& kind, const std::string& method,
                       const std::string& trace_id, const std::string& span_id,
                       const std::string& status) = 0;
  };

  struct TraceContext {
    std::string trace_id;
    std::string span_id;
    std::string parent_span_id;
  };

  struct Parent {
    std::string trace_id;
    std::string span_id;
  };

  static void SetTracer(Tracer* t) { TracerSlot() = t; }
  static bool Enabled() { return TracerSlot() != nullptr; }

  // Restrict traced methods: ';'-separated paths, a trailing
  // '*' means prefix match ('/echo.Echo/*'). Empty = trace all.
  static void SetTraceFilter(const std::string& patterns) {
    auto& filter = FilterSlot();
    filter.clear();
    size_t start = 0;
    while (start <= patterns.size()) {
      size_t semi = patterns.find(';', start);
      std::string p = patterns.substr(
          start, semi == std::string::npos ? std::string::npos : semi - start);
      if (!p.empty()) filter.push_back(p);
      if (semi == std::string::npos) break;
      start = semi + 1;
    }
  }

  static bool TraceAllowed(const std::string& method) {
    const auto& filter = FilterSlot();
    if (filter.empty()) return true;
    for (const auto& p : filter) {
      if (!p.empty() && p.back() == '*') {
        if (method.compare(0, p.size() - 1, p, 0, p.size() - 1) == 0) return true;
      } else if (method == p) {
        return true;
      }
    }
    return false;
  }

  static std::vector<std::string>& FilterSlot() {
    static std::vector<std::string> filter;
    return filter;
  }

  static std::string FormatTraceparent(const std::string& trace_id,
                                       const std::string& span_id) {
    return "00-" + trace_id + "-" + span_id + "-01";
  }

  static std::optional<Parent> ParseTraceparent(const char* value) {
    if (!value) return std::nullopt;
    std::string v(value);
    std::vector<std::string> parts;
    size_t start = 0;
    while (true) {
      size_t dash = v.find('-', start);
      if (dash == std::string::npos) {
        parts.push_back(v.substr(start));
        break;
      }
      parts.push_back(v.substr(start, dash - start));
      start = dash + 1;
    }
    if (parts.size() != 4 || parts[1].size() != 32 || parts[2].size() != 16) {
      return std::nullopt;
    }
    auto is_hex = [](const std::string& s) {
      for (char c : s) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
      }
      return true;
    };
    if (!is_hex(parts[1]) || !is_hex(parts[2])) return std::nullopt;
    return Parent{parts[1], parts[2]};
  }

  static std::optional<TraceContext> TraceStart(
      const std::string& kind, const std::string& method,
      const std::optional<Parent>& parent) {
    Tracer* t = TracerSlot();
    if (!t || !TraceAllowed(method)) return std::nullopt;
    TraceContext ctx;
    ctx.trace_id = parent ? parent->trace_id : RandomHex(16);
    ctx.span_id = RandomHex(8);
    ctx.parent_span_id = parent ? parent->span_id : "";
    try {
      t->OnStart(kind, method, ctx.trace_id, ctx.span_id, ctx.parent_span_id);
    } catch (...) {
    }
    return ctx;
  }

  static void TraceEnd(const std::string& kind, const std::string& method,
                       const std::optional<TraceContext>& ctx,
                       const std::string& status) {
    Tracer* t = TracerSlot();
    if (!ctx || !t) return;
    try {
      t->OnEnd(kind, method, ctx->trace_id, ctx->span_id, status);
    } catch (...) {
    }
  }

 private:
  static Tracer*& TracerSlot() {
    static Tracer* tracer = nullptr;
    return tracer;
  }

  static std::string RandomHex(int bytes) {
    static std::mt19937_64 rng{std::random_device{}()};
    static const char* digits = "0123456789abcdef";
    std::string out;
    out.reserve(static_cast<size_t>(bytes) * 2);
    for (int i = 0; i < bytes; i++) {
      unsigned int b = static_cast<unsigned int>(rng() & 0xff);
      out += digits[b >> 4];
      out += digits[b & 0xf];
    }
    return out;
  }
};

/// A gRPC status (code + message) carried as an exception.
class StatusException : public std::exception {
 public:
  StatusException(int code, std::string message)
      : code_(code), message_(std::move(message)) {
    text_ = wire::StatusName(code_) + ": " + message_;
  }

  /// Trailing metadata carried by a status frame (empty when none).
  std::map<std::string, std::string> trailers;

  int code() const { return code_; }
  const std::string& message() const { return message_; }
  const char* what() const noexcept override { return text_.c_str(); }

  /// Convert any exception to a StatusException.
  static StatusException ToStatus(const std::exception_ptr& err) {
    if (!err) return StatusException(wire::kCodeOk, "");
    try {
      std::rethrow_exception(err);
    } catch (const StatusException& se) {
      return se;
    } catch (const std::exception& e) {
      return StatusException(wire::kCodeInternal, e.what());
    } catch (...) {
      return StatusException(wire::kCodeInternal, "unknown error");
    }
  }

 private:
  int code_;
  std::string message_;
  std::string text_;
};

}  // namespace grpcdc
GRPC_RUNTIME_EOF
)

(define cpp-codec-body
#<<GRPC_RUNTIME_EOF
#pragma once

#include <chrono>
#include <cstdint>
#include <cstring>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "grpcdc/status.hpp"
#include "grpcdc/wire.hpp"

namespace grpcdc {

using Bytes = std::vector<std::uint8_t>;
using Metadata = std::map<std::string, std::string>;

inline Bytes ToBytes(const std::string& s) { return Bytes(s.begin(), s.end()); }
inline std::string ToString(const Bytes& b) {
  return std::string(b.begin(), b.end());
}

namespace json_detail {

inline std::string Escape(const std::string& s) {
  std::string out;
  for (char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += c;
        }
    }
  }
  return out;
}

/// Minimal JSON object parser: string keys; string, number, or nested
/// object values — exactly the HEADERS/TRAILERS shapes of SPEC.md.
struct Parser {
  const char* p;
  const char* end;

  void SkipWs() {
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) ++p;
  }
  bool Consume(char c) {
    SkipWs();
    if (p < end && *p == c) {
      ++p;
      return true;
    }
    return false;
  }
  std::string ParseString() {
    SkipWs();
    std::string out;
    if (p >= end || *p != '"') return out;
    ++p;
    while (p < end && *p != '"') {
      char c = *p++;
      if (c == '\\' && p < end) {
        char e = *p++;
        switch (e) {
          case 'n': out += '\n'; break;
          case 'r': out += '\r'; break;
          case 't': out += '\t'; break;
          case 'u': {
            unsigned cp = 0;
            for (int i = 0; i < 4 && p < end; ++i) cp = cp * 16 + HexVal(*p++);
            if (cp < 0x80) {
              out += static_cast<char>(cp);
            } else if (cp < 0x800) {
              out += static_cast<char>(0xc0 | (cp >> 6));
              out += static_cast<char>(0x80 | (cp & 0x3f));
            } else {
              out += static_cast<char>(0xe0 | (cp >> 12));
              out += static_cast<char>(0x80 | ((cp >> 6) & 0x3f));
              out += static_cast<char>(0x80 | (cp & 0x3f));
            }
            break;
          }
          default: out += e; break;
        }
      } else {
        out += c;
      }
    }
    if (p < end) ++p;  // closing quote
    return out;
  }
  static int HexVal(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
  }
  std::string ParseScalar() {
    SkipWs();
    const char* start = p;
    while (p < end && *p != ',' && *p != '}' && *p != ' ' && *p != '\t') ++p;
    return std::string(start, p);
  }
  /// Parse an object into (key -> raw string value / string contents).
  std::map<std::string, std::string> ParseObject() {
    std::map<std::string, std::string> out;
    Consume('{');
    while (true) {
      SkipWs();
      if (Consume('}')) break;
      std::string key = ParseString();
      Consume(':');
      SkipWs();
      if (p < end && *p == '"') {
        out[key] = ParseString();
      } else if (p < end && *p == '{') {
        // Nested object (metadata): re-serialize flat string map.
        auto nested = ParseObject();
        std::string flat = "{";
        bool first = true;
        for (auto& kv : nested) {
          if (!first) flat += ",";
          first = false;
          flat += "\"" + Escape(kv.first) + "\":\"" + Escape(kv.second) + "\"";
        }
        flat += "}";
        out[key] = flat;
      } else {
        out[key] = ParseScalar();
      }
      Consume(',');
    }
    return out;
  }
};

}  // namespace json_detail

/// Frame codec for gRPC over WebRTC DataChannels (wire protocol in
/// ../SPEC.md). Frame, status, channel and server semantics mirror the
/// Rust, JavaScript, Go, Python, Java and C# runtimes; the tables in
/// wire.hpp are generated by grpc-dc codegen.
struct Codec {
  static constexpr std::size_t kHeaderLen = 9;
  static constexpr std::size_t kMaxDataPayload = 16 * 1024 * 1024;

  struct Frame {
    int type = 0;
    std::uint32_t stream_id = 0;
    Bytes payload;
  };

  static void PutU32(Bytes& out, std::size_t off, std::uint32_t v) {
    out[off] = static_cast<std::uint8_t>(v >> 24);
    out[off + 1] = static_cast<std::uint8_t>(v >> 16);
    out[off + 2] = static_cast<std::uint8_t>(v >> 8);
    out[off + 3] = static_cast<std::uint8_t>(v);
  }
  static std::uint32_t GetU32(const Bytes& in, std::size_t off) {
    return (static_cast<std::uint32_t>(in[off]) << 24) |
           (static_cast<std::uint32_t>(in[off + 1]) << 16) |
           (static_cast<std::uint32_t>(in[off + 2]) << 8) |
           static_cast<std::uint32_t>(in[off + 3]);
  }

  /// Build one DataChannel message: header + payload.
  static Bytes EncodeFrame(int frame_type, std::uint32_t stream_id,
                           const Bytes& payload) {
    if (!wire::IsFrameType(frame_type)) {
      throw StatusException(wire::kCodeInvalidArgument,
                            "unknown frame type " + std::to_string(frame_type));
    }
    if (frame_type == wire::kFrameData && payload.size() > kMaxDataPayload) {
      throw StatusException(wire::kCodeResourceExhausted,
                            "DATA payload exceeds 16 MiB");
    }
    Bytes out(kHeaderLen + payload.size());
    out[0] = static_cast<std::uint8_t>(frame_type);
    PutU32(out, 1, stream_id);
    PutU32(out, 5, static_cast<std::uint32_t>(payload.size()));
    std::memcpy(out.data() + kHeaderLen, payload.data(), payload.size());
    return out;
  }

  /// Parse one DataChannel message.
  static Frame DecodeFrame(const Bytes& data) {
    if (data.size() < kHeaderLen) {
      throw StatusException(wire::kCodeInvalidArgument,
                            "frame shorter than 9-byte header: " +
                                std::to_string(data.size()) + " bytes");
    }
    std::uint32_t length = GetU32(data, 5);
    if (length != data.size() - kHeaderLen) {
      throw StatusException(wire::kCodeInvalidArgument,
                            "payload length " + std::to_string(length) +
                                " does not match message size " +
                                std::to_string(data.size()));
    }
    Frame f;
    f.type = data[0];
    f.stream_id = GetU32(data, 1);
    f.payload.assign(data.begin() + kHeaderLen, data.end());
    return f;
  }

  /// Parsed HEADERS payload: has_path == false means response headers.
  struct Headers {
    bool has_path = false;
    std::string path;
    Metadata metadata;
  };

  static Bytes HeadersFrame(std::uint32_t stream_id, const char* path,
                            const Metadata* metadata) {
    std::string body = "{";
    bool first = true;
    if (path) {
      body += "\"path\":\"" + json_detail::Escape(path) + "\"";
      first = false;
    }
    if (metadata && !metadata->empty()) {
      if (!first) body += ",";
      body += "\"metadata\":{";
      bool mfirst = true;
      for (auto& kv : *metadata) {
        if (!mfirst) body += ",";
        mfirst = false;
        body += "\"" + json_detail::Escape(kv.first) + "\":\"" +
                json_detail::Escape(kv.second) + "\"";
      }
      body += "}";
    }
    body += "}";
    return EncodeFrame(wire::kFrameHeaders, stream_id, ToBytes(body));
  }

  static Headers ParseHeaders(const Bytes& payload) {
    std::string text = ToString(payload);
    json_detail::Parser parser{text.data(), text.data() + text.size()};
    auto obj = parser.ParseObject();
    Headers h;
    auto pit = obj.find("path");
    if (pit != obj.end()) {
      h.has_path = true;
      h.path = pit->second;
    }
    auto mit = obj.find("metadata");
    if (mit != obj.end()) {
      json_detail::Parser mp{mit->second.data(),
                             mit->second.data() + mit->second.size()};
      h.metadata = mp.ParseObject();
    }
    return h;
  }

  /// gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
  /// units H/M/S/m/u/n (at most 8 digits). Encoding uses
  /// milliseconds (seconds past the digit limit), rounded up.
  static std::string EncodeTimeout(std::chrono::milliseconds timeout) {
    long long ms = timeout.count();
    if (ms <= 99999999LL) {
      return std::to_string(ms) + "m";
    }
    return std::to_string((ms + 999) / 1000) + "S";
  }

  /// Decoded grpc-timeout, or nullopt when malformed.
  static std::optional<std::chrono::milliseconds> ParseTimeout(const std::string& text) {
    if (text.size() < 2 || text.size() > 9) return std::nullopt;
    long long n = 0;
    for (size_t i = 0; i + 1 < text.size(); ++i) {
      if (text[i] < '0' || text[i] > '9') return std::nullopt;
      n = n * 10 + (text[i] - '0');
    }
    switch (text.back()) {
      case 'H': return std::chrono::milliseconds(n * 3600000LL);
      case 'M': return std::chrono::milliseconds(n * 60000LL);
      case 'S': return std::chrono::milliseconds(n * 1000LL);
      case 'm': return std::chrono::milliseconds(n);
      case 'u': return std::chrono::milliseconds((n + 999) / 1000);
      case 'n': return std::chrono::milliseconds((n + 999999) / 1000000);
      default: return std::nullopt;
    }
  }

  static Bytes StatusFrame(int frame_type, std::uint32_t stream_id,
                           const StatusException& status) {
    std::string body = "{\"code\":" + std::to_string(status.code()) +
                       ",\"message\":\"" +
                       json_detail::Escape(status.message()) + "\"";
    if (!status.trailers.empty()) {
      body += ",\"metadata\":{";
      bool mfirst = true;
      for (auto& kv : status.trailers) {
        if (!mfirst) body += ",";
        mfirst = false;
        body += "\"" + json_detail::Escape(kv.first) + "\":\"" +
                json_detail::Escape(kv.second) + "\"";
      }
      body += "}";
    }
    body += "}";
    return EncodeFrame(frame_type, stream_id, ToBytes(body));
  }

  static StatusException ParseStatus(const Bytes& payload) {
    try {
      std::string text = ToString(payload);
      json_detail::Parser parser{text.data(), text.data() + text.size()};
      auto obj = parser.ParseObject();
      int code = std::stoi(obj.at("code"));
      std::string message = obj.count("message") ? obj["message"] : "";
      StatusException status(code, message);
      auto mit = obj.find("metadata");
      if (mit != obj.end()) {
        json_detail::Parser mp{mit->second.data(),
                               mit->second.data() + mit->second.size()};
        status.trailers = mp.ParseObject();
      }
      return status;
    } catch (...) {
      return StatusException(wire::kCodeUnknown, "malformed trailers");
    }
  }
};

}  // namespace grpcdc
GRPC_RUNTIME_EOF
)

(define cpp-transport-body
#<<GRPC_RUNTIME_EOF
#pragma once

#include "grpcdc/codec.hpp"

namespace grpcdc {

/// Carries whole DataChannel messages: one Send/Recv is one message,
/// boundaries preserved, ordered and reliable — the contract an
/// RTCDataChannel (or the loopback pair) offers.
class Transport {
 public:
  virtual ~Transport() = default;
  virtual void Send(const Bytes& data) = 0;
  /// Next message; throws EndOfStream when closed.
  virtual Bytes Recv() = 0;
  virtual void Close() {}

  enum class TryRecvResult { kMessage, kWouldBlock, kClosed };

  /// Optional bounded/non-blocking receive for single-threaded
  /// environments (wasm32): kMessage fills out, kWouldBlock when
  /// no message arrived within the transport's short wait,
  /// kClosed when the transport is closed. When a transport
  /// reports HasTryRecv(), the endpoint runs in inline pump
  /// mode — no read or dispatch threads; stream waits pump the
  /// transport through this hook instead of blocking on a
  /// condition variable.
  virtual TryRecvResult TryRecv(Bytes& out) {
    (void)out;
    return TryRecvResult::kWouldBlock;
  }
  virtual bool HasTryRecv() const { return false; }
};

/// Implemented by hand-written protobuf message types.
struct Marshaler {
  virtual ~Marshaler() = default;
  virtual Bytes MarshalDc() const = 0;
};

/// Implemented by hand-written protobuf message types.
struct Unmarshaler {
  virtual ~Unmarshaler() = default;
  virtual void UnmarshalDc(const Bytes& data) = 0;
};

}  // namespace grpcdc
GRPC_RUNTIME_EOF
)

(define cpp-endpoint-body
#<<GRPC_RUNTIME_EOF
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>

#include "grpcdc/codec.hpp"
#include "grpcdc/status.hpp"
#include "grpcdc/transport.hpp"

namespace grpcdc {

/// Multiplexes grpc-dc streams over one Transport.
class Endpoint : public std::enable_shared_from_this<Endpoint> {
 public:
  enum class EventKind { kHeaders, kData, kHalfClose, kTrailers, kRst };

  struct StreamEvent {
    EventKind kind = EventKind::kData;
    Codec::Headers headers;
    Bytes payload;
    std::shared_ptr<StatusException> status;  // null unless terminal
  };

  /// Receiving queue of one stream; closed after a terminal event.
  class StreamInput {
   public:
    /// Inline (single-threaded) mode: Get/GetFor drive the
    /// endpoint pump instead of waiting on the condition variable.
    void SetPump(Endpoint* endpoint) { pump_endpoint_ = endpoint; }

    void Put(StreamEvent evt) {
      {
        std::lock_guard<std::mutex> lock(mu_);
        queue_.push_back(std::move(evt));
      }
      cv_.notify_all();
    }
    void Close() {
      {
        std::lock_guard<std::mutex> lock(mu_);
        closed_ = true;
      }
      cv_.notify_all();
    }
    /// Next event; returns false once the stream is closed and drained.
    bool Get(StreamEvent& out) {
      while (true) {
        Endpoint* pump = nullptr;
        {
          std::unique_lock<std::mutex> lock(mu_);
          if (!queue_.empty()) {
            out = std::move(queue_.front());
            queue_.pop_front();
            return true;
          }
          if (closed_) return false;
          if (!pump_endpoint_) {
            cv_.wait(lock, [&] { return !queue_.empty() || closed_; });
            continue;
          }
          pump = pump_endpoint_;
        }
        // Inline mode: pump the endpoint (which delivers via
        // Put) instead of waiting. The queue mutex is released
        // first, since Put re-acquires it.
        pump->PollOnce();
      }
    }

    enum class GetResult { kOk, kClosed, kTimeout };

    /// Timed Get: kTimeout when the wait expires with no event.
    GetResult GetFor(StreamEvent& out, std::chrono::milliseconds timeout) {
      const auto deadline = std::chrono::steady_clock::now() + timeout;
      while (true) {
        Endpoint* pump = nullptr;
        {
          std::unique_lock<std::mutex> lock(mu_);
          if (!queue_.empty()) {
            out = std::move(queue_.front());
            queue_.pop_front();
            return GetResult::kOk;
          }
          if (closed_) return GetResult::kClosed;
          if (!pump_endpoint_) {
            auto remaining = deadline - std::chrono::steady_clock::now();
            if (remaining.count() <= 0) return GetResult::kTimeout;
            if (!cv_.wait_for(lock, remaining,
                              [&] { return !queue_.empty() || closed_; })) {
              return GetResult::kTimeout;
            }
            continue;
          }
          pump = pump_endpoint_;
        }
        if (std::chrono::steady_clock::now() >= deadline) {
          return GetResult::kTimeout;
        }
        pump->PollOnce();
      }
    }

   private:
    std::mutex mu_;
    std::condition_variable cv_;
    std::deque<StreamEvent> queue_;
    bool closed_ = false;
    Endpoint* pump_endpoint_ = nullptr;
  };

  /// Response initial/trailing metadata accumulated during one
  /// call; shared (the call plumbing is const-ref throughout).
  struct ResponseMeta {
    Metadata headers;
    Metadata trailers;
    bool headers_sent = false;
  };

  /// Per-call context: metadata sent in HEADERS, plus deadline.
  struct CallContext {
    Metadata metadata;
    std::shared_ptr<ResponseMeta> response = std::make_shared<ResponseMeta>();

    /// Record response initial metadata (sent lazily, before
    /// the first response message).
    void SetHeaders(const Metadata& md) const {
      if (response) {
        for (auto& kv : md) response->headers[kv.first] = kv.second;
      }
    }

    /// Record response trailing metadata (rides the terminal
    /// status frame).
    void SetTrailers(const Metadata& md) const {
      if (response) {
        for (auto& kv : md) response->trailers[kv.first] = kv.second;
      }
    }
    /// Deadline propagated via grpc-timeout, when the client set one.
    std::optional<std::chrono::steady_clock::time_point> deadline;

    /// Time left before the deadline, or nullopt when unbounded.
    std::optional<std::chrono::milliseconds> TimeRemaining() const {
      if (!deadline) return std::nullopt;
      auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
          *deadline - std::chrono::steady_clock::now());
      return left.count() < 0 ? std::chrono::milliseconds(0) : left;
    }

    bool DeadlineExceeded() const {
      auto left = TimeRemaining();
      return left.has_value() && left->count() == 0;
    }
  };

  class ResponseSink {
   public:
    ResponseSink(Endpoint* endpoint, std::uint32_t stream_id)
        : endpoint_(endpoint), stream_id_(stream_id) {}
    // Shared with the CallContext (installed by the endpoint).
    std::shared_ptr<ResponseMeta> response = std::make_shared<ResponseMeta>();
    void Send(const Bytes& payload) {
      // A stream the endpoint has forgotten was RST by the peer
      // (or the channel went away): fail the send so a producing
      // handler stops instead of streaming into the void.
      if (!endpoint_->Stream(stream_id_)) {
        throw StatusException(wire::kCodeCancelled, "call cancelled");
      }
      FlushHeaders();
      endpoint_->SendFrame(Codec::EncodeFrame(wire::kFrameData, stream_id_, payload));
    }
    void FlushHeaders() {
      if (response->headers_sent) return;
      response->headers_sent = true;
      SendHeaders(&response->headers);
    }
    void SendHeaders() { SendHeaders(nullptr); }
    void SendHeaders(const Metadata* metadata) {
      if (!endpoint_->Stream(stream_id_)) {
        throw StatusException(wire::kCodeCancelled, "call cancelled");
      }
      response->headers_sent = true;
      endpoint_->SendFrame(Codec::HeadersFrame(stream_id_, nullptr, metadata));
    }
    void SendTrailers(const StatusException& status) {
      StatusException out = status;
      if (!response->trailers.empty()) {
        Metadata merged = response->trailers;
        for (auto& kv : status.trailers) merged[kv.first] = kv.second;
        out.trailers = std::move(merged);
      }
      endpoint_->SendFrame(Codec::StatusFrame(wire::kFrameTrailers, stream_id_, out));
    }

   private:
    Endpoint* endpoint_;
    std::uint32_t stream_id_;
  };

  /// Server-side call handler installed by Server. Returns the status
  /// that becomes the call's TRAILERS (OK when it returns normally by
  /// value with code OK).
  using Dispatcher = std::function<StatusException(
      const CallContext&, const Codec::Headers&,
      const std::shared_ptr<StreamInput>&, ResponseSink&)>;

  /// The side that created the channel allocates odd stream ids, the
  /// answerer even. The read loop starts on Start() — after any
  /// dispatcher is installed, so an early HEADERS can never race
  /// dispatcher setup.
  Endpoint(std::shared_ptr<Transport> transport, bool creator)
      : transport_(std::move(transport)), next_id_(creator ? 1 : 2) {}

  void Start() {
    {
      std::lock_guard<std::mutex> lock(start_mu_);
      if (started_) return;
      started_ = true;
      // A TryRecv transport runs inline instead of on a read
      // thread: no thread is spawned and stream waits pump the
      // transport (single-threaded environments such as wasm32).
      inline_pump_ = transport_->HasTryRecv();
    }
    if (inline_pump_) return;
    auto self = shared_from_this();
    std::thread([self] { self->ReadLoop(); }).detach();
  }

  /// Whether this endpoint runs in inline pump mode (Start
  /// decided from the transport's HasTryRecv).
  bool inline_pump() const { return inline_pump_; }

  /// Inline mode: receive and dispatch at most one message.
  /// Stream waits call this through StreamInput's pump hook; a
  /// server-only program drives its endpoint by calling it in
  /// a loop.
  void PollOnce() {
    if (closed_) return;
    Bytes data;
    Transport::TryRecvResult result;
    try {
      result = transport_->TryRecv(data);
    } catch (...) {
      FailAll();
      return;
    }
    if (result == Transport::TryRecvResult::kClosed) {
      FailAll();
      return;
    }
    if (result == Transport::TryRecvResult::kMessage && !closed_) {
      OnBytes(data);
    }
  }

  void SetDispatcher(Dispatcher dispatcher) { dispatcher_ = std::move(dispatcher); }

  void SendFrame(const Bytes& frame) {
    std::lock_guard<std::mutex> lock(send_mu_);
    transport_->Send(frame);
  }

  std::pair<std::uint32_t, std::shared_ptr<StreamInput>> OpenStream() {
    std::uint32_t id;
    {
      std::lock_guard<std::mutex> lock(send_mu_);
      id = next_id_;
      next_id_ += 2;
    }
    auto input = std::make_shared<StreamInput>();
    AttachPump(input);
    {
      std::lock_guard<std::mutex> lock(mu_);
      streams_[id] = input;
    }
    return {id, input};
  }

  void CloseStream(std::uint32_t id) {
    std::lock_guard<std::mutex> lock(mu_);
    streams_.erase(id);
  }

  /// Abort one stream: RST towards the peer and wakes any local
  /// thread blocked in Recv with the cancellation status.
  void CancelStream(std::uint32_t id) {
    auto status = std::make_shared<StatusException>(wire::kCodeCancelled,
                                                    "call cancelled");
    std::shared_ptr<StreamInput> input;
    {
      std::lock_guard<std::mutex> lock(mu_);
      auto it = streams_.find(id);
      if (it != streams_.end()) {
        input = it->second;
        streams_.erase(it);
      }
    }
    if (input) {
      StreamEvent evt;
      evt.kind = EventKind::kRst;
      evt.status = status;
      input->Put(std::move(evt));
      input->Close();
    }
    try {
      SendFrame(Codec::StatusFrame(wire::kFrameRst, id, *status));
    } catch (...) {
    }
  }

  void Close() {
    if (closed_.exchange(true)) return;
    try {
      transport_->Close();
    } catch (...) {
    }
    FailAll();
  }

 private:
  void AttachPump(const std::shared_ptr<StreamInput>& input) {
    if (inline_pump_ || transport_->HasTryRecv()) input->SetPump(this);
  }

  std::shared_ptr<StreamInput> Stream(std::uint32_t id) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = streams_.find(id);
    return it == streams_.end() ? nullptr : it->second;
  }

  void FailAll() {
    std::map<std::uint32_t, std::shared_ptr<StreamInput>> streams;
    {
      std::lock_guard<std::mutex> lock(mu_);
      streams = streams_;
      streams_.clear();
    }
    for (auto& kv : streams) {
      StreamEvent evt;
      evt.kind = EventKind::kRst;
      evt.status = std::make_shared<StatusException>(wire::kCodeUnavailable,
                                                     "data channel closed");
      kv.second->Put(std::move(evt));
      kv.second->Close();
    }
  }

  void ReadLoop() {
    while (true) {
      Bytes data;
      try {
        data = transport_->Recv();
      } catch (...) {
        FailAll();
        return;
      }
      if (closed_) return;
      OnBytes(data);
    }
  }

  void OnBytes(const Bytes& data) {
    Codec::Frame frame;
    try {
      frame = Codec::DecodeFrame(data);
    } catch (const StatusException&) {
      return;  // malformed frame: drop, keep the channel up
    }
    int frame_type = frame.type;
    std::uint32_t stream_id = frame.stream_id;
    Bytes payload = frame.payload;
@@FRAME_DISPATCH@@
  }

  void OnTerminal(std::uint32_t stream_id, const Bytes& payload, EventKind kind) {
    auto input = Stream(stream_id);
    if (input) {
      StreamEvent evt;
      evt.kind = kind;
      evt.status =
          std::make_shared<StatusException>(Codec::ParseStatus(payload));
      input->Put(std::move(evt));
      input->Close();
      CloseStream(stream_id);
    }
  }

  void PushEvent(std::uint32_t stream_id, StreamEvent evt) {
    auto input = Stream(stream_id);
    if (input) input->Put(std::move(evt));
  }

  void OnHeaders(std::uint32_t stream_id, const Bytes& payload) {
    Codec::Headers headers;
    try {
      headers = Codec::ParseHeaders(payload);
    } catch (const StatusException& e) {
      try {
        SendFrame(Codec::StatusFrame(wire::kFrameRst, stream_id, e));
      } catch (...) {
      }
      return;
    }
    if (!headers.has_path) {
      // Server response headers for one of our outbound streams.
      auto input = Stream(stream_id);
      if (input) {
        StreamEvent evt;
        evt.kind = EventKind::kHeaders;
        evt.headers = headers;
        input->Put(std::move(evt));
      }
      return;
    }
    if (Stream(stream_id)) {
      try {
        SendFrame(Codec::StatusFrame(
            wire::kFrameRst, stream_id,
            StatusException(wire::kCodeInternal,
                            "HEADERS for stream already in use")));
      } catch (...) {
      }
      return;
    }
    if (!dispatcher_) {
      try {
        SendFrame(Codec::StatusFrame(
            wire::kFrameTrailers, stream_id,
            StatusException(wire::kCodeUnimplemented,
                            "unknown method " + headers.path)));
      } catch (...) {
      }
      return;
    }
    auto stream_input = std::make_shared<StreamInput>();
    AttachPump(stream_input);
    {
      std::lock_guard<std::mutex> lock(mu_);
      streams_[stream_id] = stream_input;
    }
    Dispatcher dispatcher = dispatcher_;
    auto self = shared_from_this();
    (void)self;  // keeps the endpoint alive across the call below
    if (inline_pump_) {
      // Single-threaded mode: run the handler on this pump
      // stack instead of a dispatch thread. Its stream waits
      // re-enter PollOnce through the input's pump hook.
      DispatchCall(stream_id, stream_input, headers, dispatcher);
      return;
    }
    std::thread([self, this, stream_id, stream_input, headers, dispatcher] {
      DispatchCall(stream_id, stream_input, headers, dispatcher);
    }).detach();
  }

  void DispatchCall(std::uint32_t stream_id,
                    const std::shared_ptr<StreamInput>& stream_input,
                    const Codec::Headers& headers,
                    const Dispatcher& dispatcher) {
    ResponseSink sink(this, stream_id);
    try {
      StatusException status(wire::kCodeOk, "");
      try {
        CallContext ctx;
        sink.response = ctx.response;
        ctx.metadata = headers.metadata;
        if (auto it = headers.metadata.find("grpc-timeout");
            it != headers.metadata.end()) {
          if (auto remaining = Codec::ParseTimeout(it->second)) {
            ctx.deadline = std::chrono::steady_clock::now() + *remaining;
          }
        }
        status = dispatcher(ctx, headers, stream_input, sink);
      } catch (...) {
        status = StatusException::ToStatus(std::current_exception());
      }
      // No eager HEADERS: initial metadata flushes lazily via
      // the sink (first DATA, or here on a DATA-less success)
      // so handlers can SetHeaders first. Errors end
      // trailers-only, as gRPC allows.
      if (status.code() == wire::kCodeOk) {
        try {
          sink.FlushHeaders();
        } catch (...) {
        }
      }
      try {
        sink.SendTrailers(status);
      } catch (...) {
      }
    } catch (...) {
    }
    CloseStream(stream_id);
  }

  std::shared_ptr<Transport> transport_;
  Dispatcher dispatcher_;
  std::uint32_t next_id_;
  std::mutex send_mu_;
  std::mutex mu_;
  std::mutex start_mu_;
  std::map<std::uint32_t, std::shared_ptr<StreamInput>> streams_;
  std::atomic<bool> closed_{false};
  bool started_ = false;
  bool inline_pump_ = false;
};

}  // namespace grpcdc
GRPC_RUNTIME_EOF
)

(define cpp-channel-body
#<<GRPC_RUNTIME_EOF
#pragma once

#include <chrono>
#include <memory>
#include <optional>
#include <vector>

#include "grpcdc/endpoint.hpp"

namespace grpcdc {

/// Channel: the client side of one Endpoint.
class Channel {
 public:
  /// Wrap a transport, allocating odd stream ids.
  explicit Channel(std::shared_ptr<Transport> transport)
      : endpoint_(std::make_shared<Endpoint>(std::move(transport), true)) {
    endpoint_->Start();
  }

  /// Wrap an existing endpoint (bidirectional use; starts its read loop).
  explicit Channel(std::shared_ptr<Endpoint> endpoint)
      : endpoint_(std::move(endpoint)) {
    endpoint_->Start();
  }

  std::shared_ptr<Endpoint> endpoint() const { return endpoint_; }

  /// Receives response messages of one call.
  class ClientStream {
   public:
    ClientStream(std::uint32_t stream_id,
                 std::shared_ptr<Endpoint::StreamInput> input)
        : stream_id_(stream_id), input_(std::move(input)) {}

    ClientStream(ClientStream&& other) noexcept
        : endpoint_(std::move(other.endpoint_)),
          deadline_(other.deadline_),
          stream_id_(other.stream_id_),
          input_(std::move(other.input_)),
          headers_(std::move(other.headers_)),
          trailers_(std::move(other.trailers_)),
          trace_ctx_(other.trace_ctx_),
          trace_path_(std::move(other.trace_path_)),
          trace_ended_(other.trace_ended_),
          terminated_(other.terminated_) {
      other.terminated_ = true;
    }
    ClientStream& operator=(ClientStream&& other) noexcept {
      if (this != &other) {
        CancelIfLive();
        endpoint_ = std::move(other.endpoint_);
        deadline_ = other.deadline_;
        stream_id_ = other.stream_id_;
        input_ = std::move(other.input_);
        headers_ = std::move(other.headers_);
        trailers_ = std::move(other.trailers_);
        trace_ctx_ = other.trace_ctx_;
        trace_path_ = std::move(other.trace_path_);
        trace_ended_ = other.trace_ended_;
        terminated_ = other.terminated_;
        other.terminated_ = true;
      }
      return *this;
    }
    ClientStream(const ClientStream&) = delete;
    ClientStream& operator=(const ClientStream&) = delete;

    /// Destroying a stream whose call never terminated cancels it
    /// (RST CANCELLED) so the peer stops producing.
    ~ClientStream() { CancelIfLive(); }

    void SetDeadline(std::chrono::steady_clock::time_point deadline) {
      deadline_ = deadline;
    }

    std::uint32_t stream_id() const { return stream_id_; }
    const Codec::Headers& headers() const { return headers_; }
    const Metadata& trailers() const { return trailers_; }

    /// Decode the next response into resp. EndOfStream means the call
    /// completed OK; StatusException reports the trailers status.
    void Recv(Unmarshaler& resp) {
      while (true) {
        Endpoint::StreamEvent evt;
        if (deadline_) {
          auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
              *deadline_ - std::chrono::steady_clock::now());
          auto result = input_->GetFor(
              evt, remaining.count() < 0 ? std::chrono::milliseconds(0) : remaining);
          if (result == Endpoint::StreamInput::GetResult::kTimeout) {
            if (endpoint_) endpoint_->CancelStream(stream_id_);
            terminated_ = true;
            throw StatusException(wire::kCodeDeadlineExceeded, "deadline exceeded");
          }
          if (result == Endpoint::StreamInput::GetResult::kClosed) {
            throw StatusException(wire::kCodeUnavailable, "data channel closed");
          }
        } else if (!input_->Get(evt)) {
          throw StatusException(wire::kCodeUnavailable, "data channel closed");
        }
        switch (evt.kind) {
          case Endpoint::EventKind::kHeaders:
            headers_ = evt.headers;
            break;
          case Endpoint::EventKind::kData:
            resp.UnmarshalDc(evt.payload);
            return;
          case Endpoint::EventKind::kTrailers:
            terminated_ = true;
            if (evt.status) trailers_ = evt.status->trailers;
            EndTrace(wire::StatusName(evt.status ? evt.status->code() : wire::kCodeOk));
            if (evt.status && evt.status->code() != wire::kCodeOk) {
              throw *evt.status;
            }
            throw EndOfStream();
          case Endpoint::EventKind::kRst: {
            terminated_ = true;
            StatusException status = evt.status ? *evt.status
                : StatusException(wire::kCodeUnavailable, "stream reset");
            trailers_ = status.trailers;
            EndTrace(wire::StatusName(status.code()));
            throw status;
          }
          default:
            break;
        }
      }
    }

    void EndTrace(const std::string& status) {
      if (!trace_ended_) {
        trace_ended_ = true;
        Tracing::TraceEnd("client", trace_path_, trace_ctx_, status);
      }
    }

   private:
    void CancelIfLive() noexcept {
      if (!terminated_ && endpoint_) {
        terminated_ = true;
        try {
          endpoint_->CancelStream(stream_id_);
        } catch (...) {
        }
      }
    }

    friend class Channel;
    std::shared_ptr<Endpoint> endpoint_;
    std::optional<std::chrono::steady_clock::time_point> deadline_;
    std::uint32_t stream_id_;
    std::shared_ptr<Endpoint::StreamInput> input_;
    Codec::Headers headers_;
    Metadata trailers_;
    std::optional<Tracing::TraceContext> trace_ctx_;
    std::string trace_path_;
    bool trace_ended_ = false;
    bool terminated_ = false;
  };

  /// Abort an open ClientStream (sends RST, wakes pending Recv).
  void Cancel(ClientStream& stream) {
    endpoint_->CancelStream(stream.stream_id());
    stream.terminated_ = true;
  }

  /// Run a unary call, decoding the single response into resp.
  void Unary(const std::string& path, const Marshaler& req, Unmarshaler& resp,
             const Metadata* metadata = nullptr,
             std::optional<std::chrono::milliseconds> timeout = std::nullopt) {
    ClientStream stream = Open(path, metadata, timeout);
    try {
      SendMessage(stream, req);
      HalfClose(stream);
      bool got = false;
      while (true) {
        try {
          stream.Recv(resp);
        } catch (const EndOfStream&) {
          if (!got) {
            throw StatusException(wire::kCodeInternal,
                                  "call closed with no response");
          }
          return;
        }
        if (got) {
          throw StatusException(
              wire::kCodeInternal, "unary call received more than one response");
        }
        got = true;
      }
    } catch (...) {
      endpoint_->CloseStream(stream.stream_id());
      throw;
    }
  }

  /// Start a server-streaming call.
  ClientStream ServerStream(const std::string& path, const Marshaler& req,
                            const Metadata* metadata = nullptr,
             std::optional<std::chrono::milliseconds> timeout = std::nullopt) {
    ClientStream stream = Open(path, metadata, timeout);
    SendMessage(stream, req);
    HalfClose(stream);
    return stream;
  }

  /// Send all requests, then decode the one response into resp.
  void ClientStreamCall(const std::string& path,
                        const std::vector<const Marshaler*>& reqs,
                        Unmarshaler& resp,
                        const Metadata* metadata = nullptr,
             std::optional<std::chrono::milliseconds> timeout = std::nullopt) {
    ClientStream stream = Open(path, metadata, timeout);
    try {
      SendAll(stream, reqs);
      bool got = false;
      while (true) {
        try {
          stream.Recv(resp);
        } catch (const EndOfStream&) {
          if (!got) {
            throw StatusException(wire::kCodeInternal,
                                  "call closed with no response");
          }
          return;
        }
        if (got) {
          throw StatusException(wire::kCodeInternal,
                                "client-streaming call received more than one "
                                "response");
        }
        got = true;
      }
    } catch (...) {
      endpoint_->CloseStream(stream.stream_id());
      throw;
    }
  }

  /// Start a bidi call with all requests sent up front.
  ClientStream Bidi(const std::string& path,
                    const std::vector<const Marshaler*>& reqs,
                    const Metadata* metadata = nullptr,
             std::optional<std::chrono::milliseconds> timeout = std::nullopt) {
    ClientStream stream = Open(path, metadata, timeout);
    SendAll(stream, reqs);
    return stream;
  }

 private:
  ClientStream Open(const std::string& path, const Metadata* metadata,
                    std::optional<std::chrono::milliseconds> timeout = std::nullopt) {
    Metadata merged;
    const Metadata* md = metadata;
    std::optional<std::chrono::steady_clock::time_point> deadline;
    std::optional<Tracing::TraceContext> trace_ctx;
    if (timeout || Tracing::Enabled()) {
      if (metadata) merged = *metadata;
      if (timeout) {
        deadline = std::chrono::steady_clock::now() + *timeout;
        merged["grpc-timeout"] = Codec::EncodeTimeout(*timeout);
      }
      if (Tracing::Enabled()) {
        auto it = merged.find("traceparent");
        trace_ctx = Tracing::TraceStart(
            "client", path,
            Tracing::ParseTraceparent(it == merged.end() ? nullptr : it->second.c_str()));
        if (trace_ctx) {
          merged["traceparent"] =
              Tracing::FormatTraceparent(trace_ctx->trace_id, trace_ctx->span_id);
        }
      }
      md = &merged;
    }
    auto opened = endpoint_->OpenStream();
    try {
      endpoint_->SendFrame(Codec::HeadersFrame(opened.first, path.c_str(), md));
    } catch (...) {
      endpoint_->CloseStream(opened.first);
      Tracing::TraceEnd("client", path, trace_ctx, "UNAVAILABLE");
      throw;
    }
    ClientStream stream(opened.first, opened.second);
    stream.endpoint_ = endpoint_;
    stream.deadline_ = deadline;
    stream.trace_ctx_ = trace_ctx;
    stream.trace_path_ = path;
    return stream;
  }

  void SendMessage(ClientStream& stream, const Marshaler& msg) {
    endpoint_->SendFrame(
        Codec::EncodeFrame(wire::kFrameData, stream.stream_id(), msg.MarshalDc()));
  }

  void HalfClose(ClientStream& stream) {
    endpoint_->SendFrame(
        Codec::EncodeFrame(wire::kFrameHalfClose, stream.stream_id(), Bytes{}));
  }

  void SendAll(ClientStream& stream, const std::vector<const Marshaler*>& reqs) {
    for (auto* req : reqs) SendMessage(stream, *req);
    HalfClose(stream);
  }

  std::shared_ptr<Endpoint> endpoint_;
};

}  // namespace grpcdc
GRPC_RUNTIME_EOF
)

(define cpp-server-body
#<<GRPC_RUNTIME_EOF
#pragma once

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "grpcdc/endpoint.hpp"

namespace grpcdc {

/// Server: dispatches inbound calls to registered methods.
class Server {
 public:
  static constexpr const char* kKindUnary = "unary";
  static constexpr const char* kKindServerStreaming = "server-streaming";
  static constexpr const char* kKindClientStreaming = "client-streaming";
  static constexpr const char* kKindBidi = "bidi";

  /// Reads request messages of one inbound call.
  class RequestStream {
   public:
    explicit RequestStream(std::shared_ptr<Endpoint::StreamInput> input)
        : input_(std::move(input)) {}

    /// Next request payload; EndOfStream at half-close.
    Bytes RecvRaw() {
      while (true) {
        Endpoint::StreamEvent evt;
        if (!input_->Get(evt)) {
          throw StatusException(wire::kCodeUnavailable, "data channel closed");
        }
        switch (evt.kind) {
          case Endpoint::EventKind::kData:
            return evt.payload;
          case Endpoint::EventKind::kHalfClose:
            throw EndOfStream();
          case Endpoint::EventKind::kTrailers:
          case Endpoint::EventKind::kRst:
            if (evt.status) throw *evt.status;
            throw StatusException(wire::kCodeUnavailable, "stream closed");
          default:
            break;  // ignore HEADERS on the request side
        }
      }
    }

    /// Decode the next request message into req.
    void RecvInto(Unmarshaler& req) { req.UnmarshalDc(RecvRaw()); }

   private:
    std::shared_ptr<Endpoint::StreamInput> input_;
  };

  /// Sends response payloads of one inbound call.
  using ServerSink = std::function<void(const Bytes&)>;

  /// Implements one method against raw payloads; stubs adapt it.
  using MethodHandler =
      std::function<void(const Endpoint::CallContext&, RequestStream&, ServerSink&)>;

  struct Method {
    std::string name;
    std::string path;
    std::string kind;
    MethodHandler handler;
  };

  struct ServiceDesc {
    std::string name;
    std::vector<Method> methods;
  };

  /// Adds a service's methods (generated code calls it).
  void RegisterService(const ServiceDesc& desc) {
    for (auto& method : desc.methods) shared_->methods[method.path] = method;
  }

  /// Attach to a transport (even stream ids); returns the Endpoint.
  std::shared_ptr<Endpoint> ServeTransport(std::shared_ptr<Transport> transport) {
    auto endpoint = std::make_shared<Endpoint>(std::move(transport), false);
    ServeEndpoint(endpoint);
    return endpoint;
  }

  /// Attach to an existing endpoint (starts its read loop).
  void ServeEndpoint(const std::shared_ptr<Endpoint>& endpoint) {
    endpoint_ = endpoint;
    auto shared = shared_;
    endpoint->SetDispatcher(
        [shared](const Endpoint::CallContext& ctx, const Codec::Headers& headers,
                 const std::shared_ptr<Endpoint::StreamInput>& input,
                 Endpoint::ResponseSink& sink) {
          return Dispatch(shared, ctx, headers, input, sink);
        });
    endpoint->Start();
  }

 private:
  /// Method table shared with the dispatcher closure, so registered
  /// handlers stay valid as long as the endpoint lives.
  struct Shared {
    std::map<std::string, Method> methods;
  };

  static StatusException Dispatch(
      const std::shared_ptr<Shared>& shared, const Endpoint::CallContext& ctx,
      const Codec::Headers& headers,
      const std::shared_ptr<Endpoint::StreamInput>& input,
      Endpoint::ResponseSink& sink) {
    auto it = shared->methods.find(headers.path);
    if (it == shared->methods.end()) {
      return StatusException(wire::kCodeUnimplemented,
                             "unknown method " + headers.path);
    }
    auto trace_it = headers.metadata.find("traceparent");
    auto trace_ctx = Tracing::TraceStart(
        "server", headers.path,
        Tracing::ParseTraceparent(trace_it == headers.metadata.end()
                                      ? nullptr
                                      : trace_it->second.c_str()));
    StatusException result(wire::kCodeOk, "");
    try {
      RequestStream reqs(input);
      ServerSink sink_fn = [&sink](const Bytes& payload) { sink.Send(payload); };
      it->second.handler(ctx, reqs, sink_fn);
    } catch (...) {
      result = StatusException::ToStatus(std::current_exception());
    }
    Tracing::TraceEnd("server", headers.path, trace_ctx,
                      wire::StatusName(result.code()));
    return result;
  }

  std::shared_ptr<Shared> shared_ = std::make_shared<Shared>();
  std::shared_ptr<Endpoint> endpoint_;
};

}  // namespace grpcdc
GRPC_RUNTIME_EOF
)

(define cpp-loopback-body
#<<GRPC_RUNTIME_EOF
#pragma once

#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <utility>

#include "grpcdc/transport.hpp"

namespace grpcdc {

namespace detail {

struct BlockingQueue {
  void Add(Bytes data) {
    {
      std::lock_guard<std::mutex> lock(mu);
      queue.push_back(std::move(data));
    }
    cv.notify_all();
  }
  Bytes Take() {
    std::unique_lock<std::mutex> lock(mu);
    cv.wait(lock, [&] { return !queue.empty() || closed; });
    if (queue.empty()) throw EndOfStream();
    Bytes out = std::move(queue.front());
    queue.pop_front();
    return out;
  }
  void Close() {
    {
      std::lock_guard<std::mutex> lock(mu);
      closed = true;
    }
    cv.notify_all();
  }
  std::mutex mu;
  std::condition_variable cv;
  std::deque<Bytes> queue;
  bool closed = false;
};

class MemoryTransportImpl : public Transport {
 public:
  MemoryTransportImpl(std::shared_ptr<BlockingQueue> inbox,
                      std::shared_ptr<BlockingQueue> outbox)
      : inbox_(std::move(inbox)), outbox_(std::move(outbox)) {}

  void Send(const Bytes& data) override {
    if (closed_) throw EndOfStream();
    outbox_->Add(data);
  }
  Bytes Recv() override { return inbox_->Take(); }
  void Close() override {
    closed_ = true;
    inbox_->Close();
  }

 private:
  std::shared_ptr<BlockingQueue> inbox_;
  std::shared_ptr<BlockingQueue> outbox_;
  bool closed_ = false;
};

}  // namespace detail

/// In-memory transport pair for tests (one queue per direction).
inline std::pair<std::shared_ptr<Transport>, std::shared_ptr<Transport>>
MemoryTransportPair() {
  auto a_to_b = std::make_shared<detail::BlockingQueue>();
  auto b_to_a = std::make_shared<detail::BlockingQueue>();
  return {std::make_shared<detail::MemoryTransportImpl>(b_to_a, a_to_b),
          std::make_shared<detail::MemoryTransportImpl>(a_to_b, b_to_a)};
}

}  // namespace grpcdc
GRPC_RUNTIME_EOF
)


(define cpp-sidecar-body
#<<GRPC_RUNTIME_EOF
#pragma once

#include <cstdint>
#include <cstring>
#include <memory>
#include <string>

#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include "grpcdc/transport.hpp"

namespace grpcdc {

/// Transport over the Rust WebRTC-Direct sidecar: the sidecar
/// owns DTLS/SCTP/TURN and bridges one datachannel to a local
/// TCP socket using u32 big-endian length-prefixed messages
/// (one prefix per DataChannel message). POSIX sockets only;
/// `host` must be an IP literal (the sidecar is local).
class SidecarTransport : public Transport {
 public:
  explicit SidecarTransport(int fd) : fd_(fd) {}

  ~SidecarTransport() override {
    if (fd_ >= 0) ::close(fd_);
  }

  static std::shared_ptr<SidecarTransport> Connect(const std::string& host,
                                                   uint16_t port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) throw EndOfStream();
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
      ::close(fd);
      throw EndOfStream();
    }
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
      ::close(fd);
      throw EndOfStream();
    }
    return std::make_shared<SidecarTransport>(fd);
  }

  void Send(const Bytes& data) override {
    if (closed_) throw EndOfStream();
    uint32_t len = static_cast<uint32_t>(data.size());
    uint8_t header[4] = {static_cast<uint8_t>(len >> 24),
                         static_cast<uint8_t>(len >> 16),
                         static_cast<uint8_t>(len >> 8),
                         static_cast<uint8_t>(len)};
    WriteAll(header, 4);
    if (!data.empty()) WriteAll(data.data(), data.size());
  }

  Bytes Recv() override {
    uint8_t header[4];
    ReadAll(header, 4);
    uint32_t len = (static_cast<uint32_t>(header[0]) << 24) |
                   (static_cast<uint32_t>(header[1]) << 16) |
                   (static_cast<uint32_t>(header[2]) << 8) | header[3];
    Bytes payload(len);
    if (len > 0) ReadAll(payload.data(), len);
    return payload;
  }

  void Close() override {
    closed_ = true;
    if (fd_ >= 0) {
      ::close(fd_);
      fd_ = -1;
    }
  }

 private:
  void WriteAll(const uint8_t* data, size_t len) {
    size_t off = 0;
    while (off < len) {
      ssize_t n = ::send(fd_, data + off, len - off, 0);
      if (n <= 0) throw EndOfStream();
      off += static_cast<size_t>(n);
    }
  }
  void ReadAll(uint8_t* data, size_t len) {
    size_t off = 0;
    while (off < len) {
      ssize_t n = ::recv(fd_, data + off, len - off, 0);
      if (n <= 0) throw EndOfStream();
      off += static_cast<size_t>(n);
    }
  }

  int fd_;
  bool closed_ = false;
};

}  // namespace grpcdc
GRPC_RUNTIME_EOF
)

(define cpp-dynamic-body
#<<GRPC_RUNTIME_EOF
#pragma once

#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <variant>
#include <vector>

#include "grpcdc/channel.hpp"
#include "grpcdc/server.hpp"

namespace grpcdc {
namespace dynamic {

// FieldDescriptorProto.Type values (descriptor.proto).
constexpr int kTypeDouble = 1;
constexpr int kTypeFloat = 2;
constexpr int kTypeInt64 = 3;
constexpr int kTypeUint64 = 4;
constexpr int kTypeInt32 = 5;
constexpr int kTypeFixed64 = 6;
constexpr int kTypeFixed32 = 7;
constexpr int kTypeBool = 8;
constexpr int kTypeString = 9;
constexpr int kTypeGroup = 10;
constexpr int kTypeMessage = 11;
constexpr int kTypeBytes = 12;
constexpr int kTypeUint32 = 13;
constexpr int kTypeEnum = 14;
constexpr int kTypeSfixed32 = 15;
constexpr int kTypeSfixed64 = 16;
constexpr int kTypeSint32 = 17;
constexpr int kTypeSint64 = 18;

constexpr int kLabelRepeated = 3;

struct FieldModel {
  int number = 0;
  std::string name;
  int type = 0;
  bool repeated = false;
  std::string type_name;  // for kTypeMessage, e.g. ".echo.EchoRequest"
};

struct MessageModel {
  std::string full_name;
  std::map<int, FieldModel> fields;       // by number
  std::map<std::string, int> by_name;
  const FieldModel* field(int number) const {
    auto it = fields.find(number);
    return it == fields.end() ? nullptr : &it->second;
  }
};

struct MethodModel {
  std::string name;
  std::string path;
  std::string kind;  // Server::kKind* values
  std::shared_ptr<MessageModel> input;
  std::shared_ptr<MessageModel> output;
};

struct ServiceModel {
  std::string full_name;
  std::map<std::string, std::shared_ptr<MethodModel>> methods;
};

/// Parsed descriptor set: messages and services by full name.
/// Message keys carry the leading dot (".echo.EchoRequest"), matching
/// FieldDescriptorProto.type_name; service keys do not ("echo.Echo").
struct FileModel {
  std::map<std::string, std::shared_ptr<MessageModel>> messages;
  std::map<std::string, std::shared_ptr<ServiceModel>> services;
  std::shared_ptr<MessageModel> message(const std::string& full_name) const {
    auto it = messages.find(full_name);
    if (it == messages.end()) {
      throw StatusException(wire::kCodeInvalidArgument,
                            "unknown message " + full_name);
    }
    return it->second;
  }
  std::shared_ptr<ServiceModel> service(const std::string& full_name) const {
    auto it = services.find(full_name);
    if (it == services.end()) {
      throw StatusException(wire::kCodeInvalidArgument,
                            "unknown service " + full_name);
    }
    return it->second;
  }
};

struct GenericMessage;
using GenericValue = std::variant<std::int64_t, std::uint64_t, bool, double,
                                  std::string, Bytes,
                                  std::shared_ptr<GenericMessage>>;

/// A message as field number -> list of values (descriptor order).
///
/// Fields not in the model are retained as raw encoded chunks in
/// `unknown` (protobuf unknown-field retention): a decode -> encode
/// round trip re-emits them after the known fields, so intermediate
/// hops do not strip newer fields.
struct GenericMessage {
  std::shared_ptr<MessageModel> model;
  std::map<int, std::vector<GenericValue>> values;
  std::vector<Bytes> unknown;

  GenericMessage() = default;
  explicit GenericMessage(std::shared_ptr<MessageModel> m) : model(std::move(m)) {}

  GenericMessage& Set(int number, GenericValue value) {
    values[number] = {std::move(value)};
    return *this;
  }
  GenericMessage& Add(int number, GenericValue value) {
    values[number].push_back(std::move(value));
    return *this;
  }
  const GenericValue* Get(int number) const {
    auto it = values.find(number);
    if (it == values.end() || it->second.empty()) return nullptr;
    return &it->second.front();
  }
  std::string GetString(int number) const {
    auto* v = Get(number);
    if (v && std::holds_alternative<std::string>(*v)) {
      return std::get<std::string>(*v);
    }
    return "";
  }
  std::int64_t GetInt(int number) const {
    auto* v = Get(number);
    if (!v) return 0;
    if (auto* i = std::get_if<std::int64_t>(v)) return *i;
    if (auto* u = std::get_if<std::uint64_t>(v)) return static_cast<std::int64_t>(*u);
    if (auto* b = std::get_if<bool>(v)) return *b ? 1 : 0;
    return 0;
  }
};

// ---------------------------------------------------------------------------
// Generic protobuf codec
// ---------------------------------------------------------------------------

namespace detail {

struct PbReader {
  const std::uint8_t* buf;
  std::size_t size;
  std::size_t pos = 0;

  std::uint64_t Varint() {
    std::uint64_t result = 0;
    int shift = 0;
    while (true) {
      if (pos >= size) {
        throw StatusException(wire::kCodeInvalidArgument, "truncated varint");
      }
      std::uint8_t b = buf[pos++];
      result |= static_cast<std::uint64_t>(b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 70) {
        throw StatusException(wire::kCodeInvalidArgument, "varint too long");
      }
    }
  }
  Bytes LenBytes() {
    std::size_t n = static_cast<std::size_t>(Varint());
    if (pos + n > size) {
      throw StatusException(wire::kCodeInvalidArgument, "truncated bytes field");
    }
    Bytes out(buf + pos, buf + pos + n);
    pos += n;
    return out;
  }
  struct Field {
    int number;
    int wire;
    std::uint64_t varint = 0;
    Bytes bytes;
    Bytes chunk;  // raw encoded field (unknown-field retention)
  };
  bool Next(Field& field) {
    if (pos >= size) return false;
    std::size_t start = pos;
    std::uint64_t tag = Varint();
    field = Field{};
    field.number = static_cast<int>(tag >> 3);
    field.wire = static_cast<int>(tag & 7);
    switch (field.wire) {
      case 0:
        field.varint = Varint();
        break;
      case 2:
        field.bytes = LenBytes();
        break;
      case 1:
        if (pos + 8 > size) {
          throw StatusException(wire::kCodeInvalidArgument, "truncated fixed64");
        }
        field.bytes.assign(buf + pos, buf + pos + 8);
        pos += 8;
        break;
      case 5:
        if (pos + 4 > size) {
          throw StatusException(wire::kCodeInvalidArgument, "truncated fixed32");
        }
        field.bytes.assign(buf + pos, buf + pos + 4);
        pos += 4;
        break;
      default:
        throw StatusException(wire::kCodeInvalidArgument,
                              "unsupported wire type " + std::to_string(field.wire));
    }
    field.chunk.assign(buf + start, buf + pos);
    return true;
  }
};

inline std::string AsString(const PbReader::Field& f) {
  return std::string(f.bytes.begin(), f.bytes.end());
}

inline int WireType(int type) {
  switch (type) {
    case kTypeInt64: case kTypeUint64: case kTypeInt32: case kTypeBool:
    case kTypeUint32: case kTypeEnum: case kTypeSint32: case kTypeSint64:
      return 0;
    case kTypeFixed64: case kTypeSfixed64: case kTypeDouble:
      return 1;
    case kTypeString: case kTypeBytes: case kTypeMessage: case kTypeGroup:
      return 2;
    case kTypeFixed32: case kTypeSfixed32: case kTypeFloat:
      return 5;
    default:
      return -1;
  }
}

inline void EncodeVarint(Bytes& out, std::uint64_t v) {
  while (v > 0x7f) {
    out.push_back(static_cast<std::uint8_t>((v & 0x7f) | 0x80));
    v >>= 7;
  }
  out.push_back(static_cast<std::uint8_t>(v));
}

inline std::uint64_t ZigzagEncode(std::int64_t v) {
  return static_cast<std::uint64_t>((v << 1) ^ (v >> 63));
}
inline std::int64_t ZigzagDecode(std::uint64_t v) {
  return static_cast<std::int64_t>(v >> 1) ^ -static_cast<std::int64_t>(v & 1);
}

inline std::int64_t ValueAsI64(const GenericValue& value) {
  if (auto* i = std::get_if<std::int64_t>(&value)) return *i;
  if (auto* u = std::get_if<std::uint64_t>(&value)) return static_cast<std::int64_t>(*u);
  if (auto* b = std::get_if<bool>(&value)) return *b ? 1 : 0;
  return 0;
}
inline std::uint64_t ValueAsU64(const GenericValue& value) {
  if (auto* u = std::get_if<std::uint64_t>(&value)) return *u;
  if (auto* i = std::get_if<std::int64_t>(&value)) return static_cast<std::uint64_t>(*i);
  if (auto* b = std::get_if<bool>(&value)) return *b ? 1 : 0;
  return 0;
}

}  // namespace detail

inline Bytes EncodeGeneric(const MessageModel& model, const GenericMessage& message,
                           const FileModel& file);
inline GenericMessage DecodeGeneric(const MessageModel& model, const Bytes& data,
                                    const FileModel& file);

namespace detail {

inline void EncodeValue(Bytes& out, const FieldModel& field,
                        const GenericValue& value, const FileModel& file) {
  int wire = WireType(field.type);
  if (wire < 0) {
    throw StatusException(wire::kCodeInvalidArgument,
                          "unsupported field type " + std::to_string(field.type));
  }
  EncodeVarint(out, (static_cast<std::uint64_t>(field.number) << 3) |
                        static_cast<std::uint64_t>(wire));
  switch (wire) {
    case 0: {
      std::uint64_t v;
      if (field.type == kTypeSint32 || field.type == kTypeSint64) {
        v = ZigzagEncode(ValueAsI64(value));
        if (field.type == kTypeSint32) v &= 0xffffffffULL;
      } else if (field.type == kTypeBool) {
        v = ValueAsI64(value) != 0 ? 1 : 0;
      } else {
        v = ValueAsU64(value);
      }
      EncodeVarint(out, v);
      break;
    }
    case 1: {
      std::uint64_t v;
      if (field.type == kTypeDouble) {
        double d = 0;
        if (auto* f = std::get_if<double>(&value)) {
          d = *f;
        } else {
          d = static_cast<double>(ValueAsI64(value));
        }
        std::memcpy(&v, &d, 8);
      } else {
        v = ValueAsU64(value);
      }
      for (int i = 0; i < 8; ++i) out.push_back(static_cast<std::uint8_t>(v >> (8 * i)));
      break;
    }
    case 5: {
      std::uint32_t v;
      if (field.type == kTypeFloat) {
        float f = 0;
        if (auto* d = std::get_if<double>(&value)) {
          f = static_cast<float>(*d);
        } else {
          f = static_cast<float>(ValueAsI64(value));
        }
        std::memcpy(&v, &f, 4);
      } else {
        v = static_cast<std::uint32_t>(ValueAsU64(value));
      }
      for (int i = 0; i < 4; ++i) out.push_back(static_cast<std::uint8_t>(v >> (8 * i)));
      break;
    }
    default: {
      Bytes data;
      if (field.type == kTypeString) {
        auto* s = std::get_if<std::string>(&value);
        if (!s) {
          throw StatusException(wire::kCodeInvalidArgument,
                                "value does not match field " + field.name);
        }
        data.assign(s->begin(), s->end());
      } else if (field.type == kTypeMessage) {
        auto* m = std::get_if<std::shared_ptr<GenericMessage>>(&value);
        if (!m || !*m) {
          throw StatusException(wire::kCodeInvalidArgument,
                                "value does not match field " + field.name);
        }
        data = EncodeGeneric(*file.message(field.type_name), **m, file);
      } else if (auto* b = std::get_if<Bytes>(&value)) {
        data = *b;
      } else if (auto* s = std::get_if<std::string>(&value)) {
        data.assign(s->begin(), s->end());
      } else {
        throw StatusException(wire::kCodeInvalidArgument,
                              "value does not match field " + field.name);
      }
      EncodeVarint(out, data.size());
      out.insert(out.end(), data.begin(), data.end());
      break;
    }
  }
}

inline GenericValue DecodeValue(const FieldModel& field, const PbReader::Field& raw,
                                const FileModel& file) {
  switch (raw.wire) {
    case 0:
      if (field.type == kTypeBool) return GenericValue(raw.varint != 0);
      if (field.type == kTypeSint32 || field.type == kTypeSint64) {
        return GenericValue(ZigzagDecode(raw.varint));
      }
      if (field.type == kTypeInt32 || field.type == kTypeEnum) {
        return GenericValue(static_cast<std::int64_t>(
            static_cast<std::int32_t>(static_cast<std::uint32_t>(raw.varint))));
      }
      if (field.type == kTypeInt64) {
        return GenericValue(static_cast<std::int64_t>(raw.varint));
      }
      return GenericValue(raw.varint);
    case 1: {
      std::uint64_t v = 0;
      for (int i = 0; i < 8; ++i) v |= static_cast<std::uint64_t>(raw.bytes[i]) << (8 * i);
      if (field.type == kTypeDouble) {
        double d;
        std::memcpy(&d, &v, 8);
        return GenericValue(d);
      }
      if (field.type == kTypeSfixed64) {
        return GenericValue(static_cast<std::int64_t>(v));
      }
      return GenericValue(v);
    }
    case 5: {
      std::uint32_t v = 0;
      for (int i = 0; i < 4; ++i) v |= static_cast<std::uint32_t>(raw.bytes[i]) << (8 * i);
      if (field.type == kTypeFloat) {
        float f;
        std::memcpy(&f, &v, 4);
        return GenericValue(static_cast<double>(f));
      }
      if (field.type == kTypeSfixed32) {
        return GenericValue(static_cast<std::int64_t>(static_cast<std::int32_t>(v)));
      }
      return GenericValue(static_cast<std::uint64_t>(v));
    }
    default:
      if (field.type == kTypeString) {
        return GenericValue(std::string(raw.bytes.begin(), raw.bytes.end()));
      }
      if (field.type == kTypeMessage) {
        auto nested = file.message(field.type_name);
        return GenericValue(std::make_shared<GenericMessage>(
            DecodeGeneric(*nested, raw.bytes, file)));
      }
      return GenericValue(raw.bytes);
  }
}

}  // namespace detail

inline Bytes EncodeGeneric(const MessageModel& model, const GenericMessage& message,
                           const FileModel& file) {
  Bytes out;
  for (auto& kv : message.values) {
    const FieldModel* field = model.field(kv.first);
    if (!field) {
      throw StatusException(wire::kCodeInvalidArgument,
                            "unknown field " + std::to_string(kv.first) + " for " +
                                model.full_name);
    }
    if (field->repeated) {
      for (auto& value : kv.second) detail::EncodeValue(out, *field, value, file);
    } else if (!kv.second.empty()) {
      detail::EncodeValue(out, *field, kv.second.front(), file);
    }
  }
  for (auto& chunk : message.unknown) {
    out.insert(out.end(), chunk.begin(), chunk.end());
  }
  return out;
}

inline GenericMessage DecodeGeneric(const MessageModel& model, const Bytes& data,
                                    const FileModel& file) {
  GenericMessage message;
  message.model = std::make_shared<MessageModel>(model);
  detail::PbReader reader{data.data(), data.size(), 0};
  detail::PbReader::Field raw;
  while (reader.Next(raw)) {
    const FieldModel* field = model.field(raw.number);
    if (!field) {
      // Unknown field: retain the raw encoded chunk verbatim.
      message.unknown.push_back(raw.chunk);
      continue;
    }
    message.values[raw.number].push_back(detail::DecodeValue(*field, raw, file));
  }
  return message;
}

// ---------------------------------------------------------------------------
// Descriptor set parsing
// ---------------------------------------------------------------------------

namespace detail {

inline FieldModel ParseField(const Bytes& data) {
  FieldModel field;
  PbReader reader{data.data(), data.size(), 0};
  PbReader::Field f;
  while (reader.Next(f)) {
    switch (f.number) {
      case 1: field.name = AsString(f); break;
      case 3: field.number = static_cast<int>(f.varint); break;
      case 4: field.repeated = static_cast<int>(f.varint) == kLabelRepeated; break;
      case 5: field.type = static_cast<int>(f.varint); break;
      case 6: field.type_name = AsString(f); break;
      default: break;
    }
  }
  return field;
}

inline void ParseMessage(const std::string& prefix, const Bytes& data,
                         FileModel& file) {
  std::string name;
  std::vector<Bytes> raw_fields;
  std::vector<Bytes> nested;
  PbReader reader{data.data(), data.size(), 0};
  PbReader::Field f;
  while (reader.Next(f)) {
    switch (f.number) {
      case 1: name = AsString(f); break;
      case 2: raw_fields.push_back(f.bytes); break;
      case 3: nested.push_back(f.bytes); break;
      default: break;
    }
  }
  std::string full_name = prefix.empty() ? name : prefix + "." + name;
  auto model = std::make_shared<MessageModel>();
  model->full_name = full_name;
  for (auto& field_bytes : raw_fields) {
    FieldModel field = ParseField(field_bytes);
    model->by_name[field.name] = field.number;
    model->fields[field.number] = field;
  }
  file.messages["." + full_name] = model;
  for (auto& nested_bytes : nested) ParseMessage(full_name, nested_bytes, file);
}

inline std::string KindOf(bool client_streaming, bool server_streaming) {
  if (client_streaming && server_streaming) return Server::kKindBidi;
  if (server_streaming) return Server::kKindServerStreaming;
  if (client_streaming) return Server::kKindClientStreaming;
  return Server::kKindUnary;
}

inline void ParseService(const std::string& package, const Bytes& data,
                         FileModel& file) {
  std::string name;
  std::vector<Bytes> raw_methods;
  PbReader reader{data.data(), data.size(), 0};
  PbReader::Field f;
  while (reader.Next(f)) {
    switch (f.number) {
      case 1: name = AsString(f); break;
      case 2: raw_methods.push_back(f.bytes); break;
      default: break;
    }
  }
  std::string full_name = package.empty() ? name : package + "." + name;
  auto service = std::make_shared<ServiceModel>();
  service->full_name = full_name;
  for (auto& method_bytes : raw_methods) {
    std::string mname, input_type, output_type;
    bool client_streaming = false, server_streaming = false;
    PbReader mr{method_bytes.data(), method_bytes.size(), 0};
    PbReader::Field mf;
    while (mr.Next(mf)) {
      switch (mf.number) {
        case 1: mname = AsString(mf); break;
        case 2: input_type = AsString(mf); break;
        case 3: output_type = AsString(mf); break;
        case 5: client_streaming = mf.varint != 0; break;
        case 6: server_streaming = mf.varint != 0; break;
        default: break;
      }
    }
    auto method = std::make_shared<MethodModel>();
    method->name = mname;
    method->path = "/" + full_name + "/" + mname;
    method->kind = KindOf(client_streaming, server_streaming);
    method->input = file.message(input_type);
    method->output = file.message(output_type);
    service->methods[mname] = method;
  }
  file.services[full_name] = service;
}

}  // namespace detail

/// Parse FileDescriptorSet bytes into a FileModel.
inline FileModel ParseDescriptorSet(const Bytes& data) {
  FileModel file;
  std::vector<std::pair<std::string, Bytes>> pending_services;
  detail::PbReader reader{data.data(), data.size(), 0};
  detail::PbReader::Field f;
  while (reader.Next(f)) {
    if (f.number != 1) continue;
    std::string package;
    std::vector<Bytes> message_types, service_types;
    detail::PbReader fr{f.bytes.data(), f.bytes.size(), 0};
    detail::PbReader::Field ff;
    while (fr.Next(ff)) {
      switch (ff.number) {
        case 2: package = detail::AsString(ff); break;
        case 4: message_types.push_back(ff.bytes); break;
        case 6: service_types.push_back(ff.bytes); break;
        default: break;
      }
    }
    for (auto& m : message_types) detail::ParseMessage(package, m, file);
    for (auto& s : service_types) pending_services.push_back({package, s});
  }
  for (auto& ps : pending_services) detail::ParseService(ps.first, ps.second, file);
  return file;
}

// ---------------------------------------------------------------------------
// Client / server surfaces
// ---------------------------------------------------------------------------

namespace detail {

/// Adapts a (MessageModel, GenericMessage) pair to the Channel
/// marshal/unmarshal contract.
class BoundMessage : public Marshaler, public Unmarshaler {
 public:
  BoundMessage(std::shared_ptr<MessageModel> model, GenericMessage generic,
               const FileModel* file)
      : model_(std::move(model)), generic(std::move(generic)), file_(file) {}

  Bytes MarshalDc() const override {
    return EncodeGeneric(*model_, generic, *file_);
  }
  void UnmarshalDc(const Bytes& data) override {
    generic = DecodeGeneric(*model_, data, *file_);
  }

  GenericMessage generic;

 private:
  std::shared_ptr<MessageModel> model_;
  const FileModel* file_;
};

}  // namespace detail

/// Runtime-built client: methods resolve from the FileModel.
class DynamicClient {
 public:
  DynamicClient(std::shared_ptr<Channel> channel,
                std::shared_ptr<FileModel> model)
      : channel_(std::move(channel)), model_(std::move(model)) {}

  GenericMessage Unary(const std::string& service, const std::string& method,
                       GenericMessage req, const Metadata* metadata = nullptr) {
    auto m = Method(service, method);
    detail::BoundMessage bound_req(m->input, std::move(req), model_.get());
    detail::BoundMessage resp(m->output, GenericMessage(m->output), model_.get());
    channel_->Unary(m->path, bound_req, resp, metadata);
    return resp.generic;
  }

  /// Receiving stream of generic responses.
  class DynamicStream {
   public:
    DynamicStream(Channel::ClientStream stream,
                  std::shared_ptr<MessageModel> output, const FileModel* file)
        : stream_(std::move(stream)), output_(std::move(output)), file_(file) {}
    /// Next response; EndOfStream at end.
    GenericMessage Recv() {
      detail::BoundMessage resp(output_, GenericMessage(output_), file_);
      stream_.Recv(resp);
      return resp.generic;
    }

   private:
    Channel::ClientStream stream_;
    std::shared_ptr<MessageModel> output_;
    const FileModel* file_;
  };

  DynamicStream ServerStream(const std::string& service,
                             const std::string& method, GenericMessage req,
                             const Metadata* metadata = nullptr) {
    auto m = Method(service, method);
    detail::BoundMessage bound_req(m->input, std::move(req), model_.get());
    return DynamicStream(channel_->ServerStream(m->path, bound_req, metadata),
                         m->output, model_.get());
  }

  GenericMessage ClientStream(const std::string& service,
                              const std::string& method,
                              std::vector<GenericMessage> reqs,
                              const Metadata* metadata = nullptr) {
    auto m = Method(service, method);
    std::vector<std::unique_ptr<detail::BoundMessage>> bound;
    std::vector<const Marshaler*> ptrs;
    for (auto& r : reqs) {
      bound.push_back(std::make_unique<detail::BoundMessage>(m->input, std::move(r),
                                                             model_.get()));
      ptrs.push_back(bound.back().get());
    }
    detail::BoundMessage resp(m->output, GenericMessage(m->output), model_.get());
    channel_->ClientStreamCall(m->path, ptrs, resp, metadata);
    return resp.generic;
  }

  DynamicStream Bidi(const std::string& service, const std::string& method,
                     std::vector<GenericMessage> reqs,
                     const Metadata* metadata = nullptr) {
    auto m = Method(service, method);
    // Requests are encoded eagerly by Channel::Bidi before returning,
    // so the bound messages only need to live until the call returns.
    std::vector<std::unique_ptr<detail::BoundMessage>> bound;
    std::vector<const Marshaler*> ptrs;
    for (auto& r : reqs) {
      bound.push_back(std::make_unique<detail::BoundMessage>(m->input, std::move(r),
                                                             model_.get()));
      ptrs.push_back(bound.back().get());
    }
    return DynamicStream(channel_->Bidi(m->path, ptrs, metadata), m->output,
                         model_.get());
  }

 private:
  std::shared_ptr<MethodModel> Method(const std::string& service,
                                      const std::string& method) {
    auto svc = model_->service(service);
    auto it = svc->methods.find(method);
    if (it == svc->methods.end()) {
      throw StatusException(wire::kCodeInvalidArgument,
                            "unknown method " + service + "/" + method);
    }
    return it->second;
  }

  std::shared_ptr<Channel> channel_;
  std::shared_ptr<FileModel> model_;
};

/// Receives generic requests; EndOfStream at half-close.
using RecvFn = std::function<GenericMessage()>;
/// Sends one generic response.
using SendFn = std::function<void(GenericMessage)>;

/// Implements a service with generic messages.
struct DynamicHandler {
  virtual ~DynamicHandler() = default;
  virtual GenericMessage Unary(Endpoint::CallContext& ctx,
                               const MethodModel& method, GenericMessage req) = 0;
  virtual void ServerStream(Endpoint::CallContext& ctx, const MethodModel& method,
                            GenericMessage req, SendFn& send) = 0;
  virtual GenericMessage ClientStream(Endpoint::CallContext& ctx,
                                      const MethodModel& method, RecvFn& recv) = 0;
  virtual void Bidi(Endpoint::CallContext& ctx, const MethodModel& method,
                    RecvFn& recv, SendFn& send) = 0;
};

/// Register a runtime-built service on a Server.
inline void RegisterDynamicService(Server& server, const FileModel& file_model,
                                   const std::string& service_name,
                                   DynamicHandler& handler) {
  auto service = file_model.service(service_name);
  Server::ServiceDesc desc;
  desc.name = service->full_name;
  for (auto& kv : service->methods) {
    auto m = kv.second;
    desc.methods.push_back(Server::Method{
        m->name, m->path, m->kind,
        [&handler, m, &file_model](const Endpoint::CallContext& ctx,
                                   Server::RequestStream& reqs,
                                   Server::ServerSink& sink) {
          auto mutable_ctx = const_cast<Endpoint::CallContext&>(ctx);
          RecvFn recv = [&reqs, m, &file_model] {
            return DecodeGeneric(*m->input, reqs.RecvRaw(), file_model);
          };
          SendFn send = [&sink, m, &file_model](GenericMessage resp) {
            sink(EncodeGeneric(*m->output, resp, file_model));
          };
          if (m->kind == Server::kKindUnary) {
            send(handler.Unary(mutable_ctx, *m, recv()));
          } else if (m->kind == Server::kKindServerStreaming) {
            handler.ServerStream(mutable_ctx, *m, recv(), send);
          } else if (m->kind == Server::kKindClientStreaming) {
            send(handler.ClientStream(mutable_ctx, *m, recv));
          } else {
            handler.Bidi(mutable_ctx, *m, recv, send);
          }
        }});
  }
  server.RegisterService(desc);
}

}  // namespace dynamic
}  // namespace grpcdc
GRPC_RUNTIME_EOF
)

(define cpp-dispatch-arms
  '((HEADERS    . "OnHeaders(stream_id, payload);")
    (DATA       . "{ StreamEvent evt; evt.kind = EventKind::kData; evt.payload = payload; PushEvent(stream_id, std::move(evt)); }")
    (HALF-CLOSE . "{ StreamEvent evt; evt.kind = EventKind::kHalfClose; PushEvent(stream_id, std::move(evt)); }")
    (TRAILERS   . "OnTerminal(stream_id, payload, EventKind::kTrailers);")
    (RST        . "OnTerminal(stream_id, payload, EventKind::kRst);")))

(define (screaming-name sym)
  (string-replace (symbol->string sym) "-" "_"))

(define (emit-cpp-dispatch)
  (string-append
   "    switch (frame_type) {\n"
   (apply string-append
          (for/list ([e (in-list frame-table)])
            (define arm (assoc (first e) cpp-dispatch-arms))
            (unless arm (error 'runtime-cpp "no C++ dispatch arm for ~a" (first e)))
            (format "      case wire::kFrame~a: ~a break;\n"
                    (pascal-cpp (first e)) (cdr arm))))
   "      default: break;  // Unknown frame type: ignore for forward compatibility.\n    }"))

(define (pascal-cpp sym) ; HALF-CLOSE -> HalfClose
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "-"))])
           (string-append (string (char-upcase (string-ref part 0)))
                          (string-downcase (substring part 1))))))

(define cpp-async-body
#<<GRPC_RUNTIME_EOF
#pragma once

// C++20 coroutine surface over the blocking Channel: Task<T>,
// SyncWait, and AsyncChannel. Blocking waits run on detached
// offload threads so co_await never stalls the resuming thread;
// the endpoint's own reader thread does the actual pumping.
// Compiled only under C++20; the rest of the runtime is C++17.
#if __cplusplus >= 202002L

#include <condition_variable>
#include <coroutine>
#include <cstdint>
#include <exception>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>

#include "grpcdc/channel.hpp"

namespace grpcdc {

/// Minimal lazy coroutine task (symmetric transfer).
template <typename T>
class Task {
 public:
  struct promise_type {
    std::optional<T> value;
    std::exception_ptr error;
    std::coroutine_handle<> continuation;

    Task get_return_object() {
      return Task{std::coroutine_handle<promise_type>::from_promise(*this)};
    }
    std::suspend_always initial_suspend() noexcept { return {}; }
    struct FinalAwaiter {
      bool await_ready() noexcept { return false; }
      std::coroutine_handle<> await_suspend(
          std::coroutine_handle<promise_type> h) noexcept {
        auto cont = h.promise().continuation;
        return cont ? cont : std::noop_coroutine();
      }
      void await_resume() noexcept {}
    };
    FinalAwaiter final_suspend() noexcept { return {}; }
    template <typename U>
    void return_value(U&& v) {
      // emplace, not assignment: co_return std::nullopt for a
      // Task<std::optional<T>> must store a disengaged *inner*
      // optional, not disengage the promise's own storage.
      value.emplace(std::forward<U>(v));
    }
    void unhandled_exception() { error = std::current_exception(); }
  };

  using Handle = std::coroutine_handle<promise_type>;
  explicit Task(Handle h) : handle_(h) {}
  Task(Task&& other) noexcept : handle_(std::exchange(other.handle_, {})) {}
  Task& operator=(Task&& other) noexcept {
    if (this != &other) {
      if (handle_) handle_.destroy();
      handle_ = std::exchange(other.handle_, {});
    }
    return *this;
  }
  Task(const Task&) = delete;
  Task& operator=(const Task&) = delete;
  ~Task() {
    if (handle_) handle_.destroy();
  }

  struct Awaiter {
    Handle h;
    bool await_ready() const noexcept { return !h || h.done(); }
    std::coroutine_handle<> await_suspend(std::coroutine_handle<> cont) {
      h.promise().continuation = cont;
      return h;
    }
    T await_resume() {
      auto& p = h.promise();
      if (p.error) std::rethrow_exception(p.error);
      return std::move(*p.value);
    }
  };
  Awaiter operator co_await() && { return Awaiter{handle_}; }

 private:
  Handle handle_;
};

/// Void specialization of Task.
template <>
class Task<void> {
 public:
  struct promise_type {
    std::exception_ptr error;
    std::coroutine_handle<> continuation;

    Task get_return_object() {
      return Task{std::coroutine_handle<promise_type>::from_promise(*this)};
    }
    std::suspend_always initial_suspend() noexcept { return {}; }
    struct FinalAwaiter {
      bool await_ready() noexcept { return false; }
      std::coroutine_handle<> await_suspend(
          std::coroutine_handle<promise_type> h) noexcept {
        auto cont = h.promise().continuation;
        return cont ? cont : std::noop_coroutine();
      }
      void await_resume() noexcept {}
    };
    FinalAwaiter final_suspend() noexcept { return {}; }
    void return_void() noexcept {}
    void unhandled_exception() { error = std::current_exception(); }
  };

  using Handle = std::coroutine_handle<promise_type>;
  explicit Task(Handle h) : handle_(h) {}
  Task(Task&& other) noexcept : handle_(std::exchange(other.handle_, {})) {}
  Task& operator=(Task&& other) noexcept {
    if (this != &other) {
      if (handle_) handle_.destroy();
      handle_ = std::exchange(other.handle_, {});
    }
    return *this;
  }
  Task(const Task&) = delete;
  Task& operator=(const Task&) = delete;
  ~Task() {
    if (handle_) handle_.destroy();
  }

  struct Awaiter {
    Handle h;
    bool await_ready() const noexcept { return !h || h.done(); }
    std::coroutine_handle<> await_suspend(std::coroutine_handle<> cont) {
      h.promise().continuation = cont;
      return h;
    }
    void await_resume() {
      auto& p = h.promise();
      if (p.error) std::rethrow_exception(p.error);
    }
  };
  Awaiter operator co_await() && { return Awaiter{handle_}; }

 private:
  Handle handle_;
};

namespace detail {

struct SyncEvent {
  std::mutex mu;
  std::condition_variable cv;
  bool done = false;
  void Set() {
    {
      std::lock_guard<std::mutex> lock(mu);
      done = true;
    }
    cv.notify_all();
  }
  void Wait() {
    std::unique_lock<std::mutex> lock(mu);
    cv.wait(lock, [this] { return done; });
  }
};

struct SyncWaitTask {
  struct promise_type {
    SyncWaitTask get_return_object() { return {}; }
    std::suspend_never initial_suspend() noexcept { return {}; }
    std::suspend_never final_suspend() noexcept { return {}; }
    void return_void() noexcept {}
    void unhandled_exception() { std::terminate(); }
  };
};

template <typename T>
SyncWaitTask RunSync(Task<T> task, std::optional<T>* out,
                     std::exception_ptr* error, SyncEvent* event) {
  try {
    *out = co_await std::move(task);
  } catch (...) {
    *error = std::current_exception();
  }
  event->Set();
}

inline SyncWaitTask RunSyncVoid(Task<void> task, std::exception_ptr* error,
                                SyncEvent* event) {
  try {
    co_await std::move(task);
  } catch (...) {
    *error = std::current_exception();
  }
  event->Set();
}

/// Awaiter running a blocking callable on a fresh thread.
template <typename F>
struct OffloadAwaiter {
  using R = std::invoke_result_t<F>;
  F fn;
  std::conditional_t<std::is_void_v<R>, std::monostate, std::optional<R>>
      value{};
  std::exception_ptr error;

  bool await_ready() const noexcept { return false; }
  void await_suspend(std::coroutine_handle<> h) {
    std::thread([this, h] {
      try {
        if constexpr (std::is_void_v<R>) {
          fn();
        } else {
          value = fn();
        }
      } catch (...) {
        error = std::current_exception();
      }
      h.resume();
    }).detach();
  }
  R await_resume() {
    if (error) std::rethrow_exception(error);
    if constexpr (!std::is_void_v<R>) {
      return std::move(*value);
    }
  }
};

}  // namespace detail

/// Run a blocking callable off the coroutine thread: co_await Offload(f).
template <typename F>
detail::OffloadAwaiter<std::decay_t<F>> Offload(F&& fn) {
  return detail::OffloadAwaiter<std::decay_t<F>>{std::forward<F>(fn)};
}

/// Drive a Task to completion from blocking code.
template <typename T>
T SyncWait(Task<T>&& task) {
  std::optional<T> out;
  std::exception_ptr error;
  detail::SyncEvent event;
  detail::RunSync(std::move(task), &out, &error, &event);
  event.Wait();
  if (error) std::rethrow_exception(error);
  return std::move(*out);
}

inline void SyncWait(Task<void>&& task) {
  std::exception_ptr error;
  detail::SyncEvent event;
  detail::RunSyncVoid(std::move(task), &error, &event);
  event.Wait();
  if (error) std::rethrow_exception(error);
}

/// Coroutine receiving stream over one call.
class AsyncClientStream {
  struct State {
    State(std::shared_ptr<Channel> ch, Channel::ClientStream s)
        : channel(std::move(ch)), stream(std::move(s)) {}
    std::shared_ptr<Channel> channel;
    Channel::ClientStream stream;
    std::mutex mu;
  };

 public:
  AsyncClientStream(std::shared_ptr<Channel> channel,
                    Channel::ClientStream stream)
      : state_(std::make_shared<State>(std::move(channel),
                                       std::move(stream))) {}

  std::uint32_t stream_id() const { return state_->stream.stream_id(); }

  /// Decode the next response; EndOfStream/StatusException as in Recv.
  Task<void> Recv(Unmarshaler& resp) {
    auto state = state_;
    co_await Offload([state, &resp] {
      std::lock_guard<std::mutex> lock(state->mu);
      state->stream.Recv(resp);
    });
  }

  /// Abort the stream (sends RST, wakes a pending Recv).
  void Cancel() {
    auto state = state_;
    state->channel->Cancel(state->stream);
  }

 private:
  std::shared_ptr<State> state_;
};

/// Coroutine client facade over a (shared) blocking Channel.
class AsyncChannel {
 public:
  explicit AsyncChannel(std::shared_ptr<Channel> channel)
      : channel_(std::move(channel)) {}
  explicit AsyncChannel(std::shared_ptr<Transport> transport)
      : channel_(std::make_shared<Channel>(std::move(transport))) {}

  std::shared_ptr<Channel> channel() const { return channel_; }

  Task<void> Unary(const std::string& path, const Marshaler& req,
                   Unmarshaler& resp, const Metadata* metadata = nullptr,
                   std::optional<std::chrono::milliseconds> timeout = std::nullopt) {
    auto channel = channel_;
    co_await Offload([channel, path, &req, &resp, metadata, timeout] {
      channel->Unary(path, req, resp, metadata, timeout);
    });
  }

  Task<AsyncClientStream> ServerStream(
      const std::string& path, const Marshaler& req,
      const Metadata* metadata = nullptr,
      std::optional<std::chrono::milliseconds> timeout = std::nullopt) {
    auto channel = channel_;
    auto stream = co_await Offload([channel, path, &req, metadata, timeout] {
      return channel->ServerStream(path, req, metadata, timeout);
    });
    co_return AsyncClientStream(channel, std::move(stream));
  }

  Task<void> ClientStreamCall(
      const std::string& path, std::vector<const Marshaler*> reqs,
      Unmarshaler& resp, const Metadata* metadata = nullptr,
      std::optional<std::chrono::milliseconds> timeout = std::nullopt) {
    auto channel = channel_;
    co_await Offload([channel, path, reqs = std::move(reqs), &resp,
                      metadata, timeout] {
      channel->ClientStreamCall(path, reqs, resp, metadata, timeout);
    });
  }

  Task<AsyncClientStream> Bidi(
      const std::string& path, std::vector<const Marshaler*> reqs,
      const Metadata* metadata = nullptr,
      std::optional<std::chrono::milliseconds> timeout = std::nullopt) {
    auto channel = channel_;
    auto stream = co_await Offload(
        [channel, path, reqs = std::move(reqs), metadata, timeout] {
          return channel->Bidi(path, reqs, metadata, timeout);
        });
    co_return AsyncClientStream(channel, std::move(stream));
  }

 private:
  std::shared_ptr<Channel> channel_;
};

}  // namespace grpcdc

#endif  // __cplusplus >= 202002L
GRPC_RUNTIME_EOF
)

(define (emit-cpp-runtime-files)
  (list
   (cons "grpcdc/status.hpp" cpp-status-body)
   (cons "grpcdc/codec.hpp" cpp-codec-body)
   (cons "grpcdc/transport.hpp" cpp-transport-body)
   (cons "grpcdc/endpoint.hpp"
         (string-replace cpp-endpoint-body "@@FRAME_DISPATCH@@" (emit-cpp-dispatch)))
   (cons "grpcdc/channel.hpp" cpp-channel-body)
   (cons "grpcdc/async.hpp" cpp-async-body)
   (cons "grpcdc/server.hpp" cpp-server-body)
   (cons "grpcdc/memory_transport.hpp" cpp-loopback-body)
   (cons "grpcdc/sidecar_transport.hpp" cpp-sidecar-body)
   (cons "grpcdc/dynamic.hpp" cpp-dynamic-body)))
