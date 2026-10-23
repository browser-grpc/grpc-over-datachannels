#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace grpcdc_wasm {

using Bytes = std::vector<std::uint8_t>;

/// Status value passed across the JS callback boundary. The WASM
/// facade is built without C++ exceptions (Zig's wasm32 libc++
/// has no exception runtime), so failures travel as the same
/// code/message pair the native runtime carries in
/// grpcdc::StatusException, but as a plain value.
struct Status {
  int code = 0;
  std::string message;

  bool ok() const { return code == 0; }
  static Status Ok() { return {}; }
};

using MessageCallback = std::function<void(const Bytes&)>;
using UnaryCallback = std::function<void(Status, const Bytes*)>;
using DoneCallback = std::function<void(Status)>;

/// Bridge runtime for generated C++ WASM client facades. It hands
/// protobuf payloads to the page's JS grpc-dc bridge
/// (js/src/wasm_bridge.js) through env imports and receives
/// responses through the exported on_bridge_* hooks in bridge.cpp.
/// The JS implementation owns the wire; this file owns interop.
class Bridge {
 public:
  static Bridge& Shared();

  void Unary(const std::string& path, const Bytes& payload,
             UnaryCallback callback);
  /// Options-aware unary: opts_json is forwarded by the page
  /// to the JS bridge ({metadata, timeout}).
  void UnaryWithOptions(const std::string& path, const Bytes& payload,
                        const std::string& opts_json,
                        UnaryCallback callback);
  void ServerStream(const std::string& path, const Bytes& payload,
                    MessageCallback on_message, DoneCallback on_done);
  /// Server-streaming call torn down after cancel_after
  /// responses; completes normally.
  void ServerStreamCancelAfter(const std::string& path,
                               const Bytes& payload,
                               std::uint32_t cancel_after,
                               MessageCallback on_message,
                               DoneCallback on_done);
  void ClientStream(const std::string& path,
                    const std::vector<Bytes>& payloads,
                    UnaryCallback callback);
  void Bidi(const std::string& path, const std::vector<Bytes>& payloads,
            MessageCallback on_message, DoneCallback on_done);

  void HandleMessage(std::uint32_t call_id, Bytes payload);
  void HandleDone(std::uint32_t call_id, const Bytes* payload);
  void HandleError(std::uint32_t call_id, Status status);

 private:
  struct Entry {
    MessageCallback on_message;
    UnaryCallback on_unary;
    DoneCallback on_done;
    bool unary = false;
  };

  std::uint32_t Register(Entry entry);
  bool Take(std::uint32_t call_id, Entry* entry);

  std::uint32_t next_id_ = 1;
  std::vector<std::pair<std::uint32_t, Entry>> pending_;
};

/// One metadata key/value pair (views into a decoded buffer).
struct MdPair {
  std::string key;
  std::string value;
};

/// Split a u32be length-prefixed packed buffer (copies).
std::vector<Bytes> Unpack(const Bytes& packed);

/// Decode flattened [key, value, ...] packed metadata.
std::vector<MdPair> DecodeMetadata(const Bytes& packed);

/// Look up a metadata key (first match wins).
const std::string* MetadataGet(const std::vector<MdPair>& pairs,
                               const std::string& key);

// Server side: generated serve_* exports report through these
// to the page glue, which owns the JS server bridge.
void ServerRespond(std::uint32_t call_id, const Bytes& payload);
void ServerSend(std::uint32_t call_id, const Bytes& payload);
void ServerComplete(std::uint32_t call_id);
void ServerFail(std::uint32_t call_id, const Status& status);

}  // namespace grpcdc_wasm
