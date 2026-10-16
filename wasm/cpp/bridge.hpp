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
  void ServerStream(const std::string& path, const Bytes& payload,
                    MessageCallback on_message, DoneCallback on_done);
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

}  // namespace grpcdc_wasm
