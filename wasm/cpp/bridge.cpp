#include "bridge.hpp"

#include <cstdlib>
#include <cstring>

#define GRPCDC_WASM_IMPORT(name) \
  __attribute__((import_module("env"), import_name(name)))

extern "C" {
GRPCDC_WASM_IMPORT("js_unary")
void js_unary(std::uint32_t call_id, const char* path_ptr,
              std::size_t path_len, const std::uint8_t* payload_ptr,
              std::size_t payload_len);
GRPCDC_WASM_IMPORT("js_unary_opts")
void js_unary_opts(std::uint32_t call_id, const char* path_ptr,
                   std::size_t path_len, const std::uint8_t* payload_ptr,
                   std::size_t payload_len, const char* opts_ptr,
                   std::size_t opts_len);
GRPCDC_WASM_IMPORT("js_server_stream_cancel")
void js_server_stream_cancel(std::uint32_t call_id, const char* path_ptr,
                             std::size_t path_len,
                             const std::uint8_t* payload_ptr,
                             std::size_t payload_len,
                             std::uint32_t cancel_after);
GRPCDC_WASM_IMPORT("js_server_stream")
void js_server_stream(std::uint32_t call_id, const char* path_ptr,
                      std::size_t path_len,
                      const std::uint8_t* payload_ptr,
                      std::size_t payload_len);
GRPCDC_WASM_IMPORT("js_client_stream")
void js_client_stream(std::uint32_t call_id, const char* path_ptr,
                      std::size_t path_len,
                      const std::uint8_t* packed_ptr,
                      std::size_t packed_len);
GRPCDC_WASM_IMPORT("js_bidi")
void js_bidi(std::uint32_t call_id, const char* path_ptr,
             std::size_t path_len, const std::uint8_t* packed_ptr,
             std::size_t packed_len);
GRPCDC_WASM_IMPORT("js_server_respond")
void js_server_respond(std::uint32_t call_id, const std::uint8_t* ptr,
                       std::size_t len);
GRPCDC_WASM_IMPORT("js_server_send")
void js_server_send(std::uint32_t call_id, const std::uint8_t* ptr,
                    std::size_t len);
GRPCDC_WASM_IMPORT("js_server_complete")
void js_server_complete(std::uint32_t call_id);
GRPCDC_WASM_IMPORT("js_server_fail")
void js_server_fail(std::uint32_t call_id, int code, const char* ptr,
                    std::size_t len);
}

namespace grpcdc_wasm {
namespace {

Bytes Pack(const std::vector<Bytes>& payloads) {
  Bytes out;
  for (const auto& payload : payloads) {
    const auto n = static_cast<std::uint32_t>(payload.size());
    out.push_back(static_cast<std::uint8_t>(n >> 24));
    out.push_back(static_cast<std::uint8_t>(n >> 16));
    out.push_back(static_cast<std::uint8_t>(n >> 8));
    out.push_back(static_cast<std::uint8_t>(n));
    out.insert(out.end(), payload.begin(), payload.end());
  }
  return out;
}

Bytes CopyAndFree(std::uint8_t* ptr, std::size_t len) {
  Bytes out;
  if (len > 0 && ptr != nullptr) out.assign(ptr, ptr + len);
  if (ptr != nullptr) std::free(ptr);
  return out;
}

}  // namespace

Bridge& Bridge::Shared() {
  static Bridge bridge;
  return bridge;
}

std::uint32_t Bridge::Register(Entry entry) {
  const auto id = next_id_++;
  pending_.push_back({id, std::move(entry)});
  return id;
}

bool Bridge::Take(std::uint32_t call_id, Entry* entry) {
  for (auto it = pending_.begin(); it != pending_.end(); ++it) {
    if (it->first == call_id) {
      *entry = std::move(it->second);
      pending_.erase(it);
      return true;
    }
  }
  return false;
}

void Bridge::Unary(const std::string& path, const Bytes& payload,
                   UnaryCallback callback) {
  Entry entry;
  entry.on_unary = std::move(callback);
  entry.unary = true;
  const auto id = Register(std::move(entry));
  js_unary(id, path.data(), path.size(), payload.data(), payload.size());
}

void Bridge::UnaryWithOptions(const std::string& path, const Bytes& payload,
                              const std::string& opts_json,
                              UnaryCallback callback) {
  Entry entry;
  entry.on_unary = std::move(callback);
  entry.unary = true;
  const auto id = Register(std::move(entry));
  js_unary_opts(id, path.data(), path.size(), payload.data(), payload.size(),
                opts_json.data(), opts_json.size());
}

void Bridge::ServerStreamCancelAfter(const std::string& path,
                                     const Bytes& payload,
                                     std::uint32_t cancel_after,
                                     MessageCallback on_message,
                                     DoneCallback on_done) {
  Entry entry;
  entry.on_message = std::move(on_message);
  entry.on_done = std::move(on_done);
  const auto id = Register(std::move(entry));
  js_server_stream_cancel(id, path.data(), path.size(), payload.data(),
                          payload.size(), cancel_after);
}

void Bridge::ServerStream(const std::string& path, const Bytes& payload,
                          MessageCallback on_message,
                          DoneCallback on_done) {
  Entry entry;
  entry.on_message = std::move(on_message);
  entry.on_done = std::move(on_done);
  const auto id = Register(std::move(entry));
  js_server_stream(id, path.data(), path.size(), payload.data(),
                   payload.size());
}

void Bridge::ClientStream(const std::string& path,
                          const std::vector<Bytes>& payloads,
                          UnaryCallback callback) {
  Entry entry;
  entry.on_unary = std::move(callback);
  entry.unary = true;
  const auto id = Register(std::move(entry));
  const Bytes packed = Pack(payloads);
  js_client_stream(id, path.data(), path.size(), packed.data(),
                   packed.size());
}

void Bridge::Bidi(const std::string& path,
                  const std::vector<Bytes>& payloads,
                  MessageCallback on_message, DoneCallback on_done) {
  Entry entry;
  entry.on_message = std::move(on_message);
  entry.on_done = std::move(on_done);
  const auto id = Register(std::move(entry));
  const Bytes packed = Pack(payloads);
  js_bidi(id, path.data(), path.size(), packed.data(), packed.size());
}

void Bridge::HandleMessage(std::uint32_t call_id, Bytes payload) {
  for (const auto& item : pending_) {
    if (item.first == call_id && item.second.on_message) {
      item.second.on_message(payload);
      return;
    }
  }
}

void Bridge::HandleDone(std::uint32_t call_id, const Bytes* payload) {
  Entry entry;
  if (!Take(call_id, &entry)) return;
  if (entry.unary) {
    if (entry.on_unary) entry.on_unary(Status::Ok(), payload);
  } else if (entry.on_done) {
    entry.on_done(Status::Ok());
  }
}

void Bridge::HandleError(std::uint32_t call_id, Status status) {
  Entry entry;
  if (!Take(call_id, &entry)) return;
  if (entry.unary) {
    if (entry.on_unary) entry.on_unary(std::move(status), nullptr);
  } else if (entry.on_done) {
    entry.on_done(std::move(status));
  }
}

}  // namespace grpcdc_wasm

extern "C" {

std::uint8_t* wasm_alloc(std::size_t len) {
  return static_cast<std::uint8_t*>(std::malloc(len == 0 ? 1 : len));
}

void wasm_free(std::uint8_t* ptr, std::size_t len) {
  (void)len;
  std::free(ptr);
}

void on_bridge_message(std::uint32_t call_id, std::uint8_t* ptr,
                       std::size_t len) {
  auto payload = grpcdc_wasm::CopyAndFree(ptr, len);
  grpcdc_wasm::Bridge::Shared().HandleMessage(call_id,
                                              std::move(payload));
}

void on_bridge_done(std::uint32_t call_id, std::uint32_t has_payload,
                    std::uint8_t* ptr, std::size_t len) {
  auto payload = grpcdc_wasm::CopyAndFree(ptr, len);
  grpcdc_wasm::Bridge::Shared().HandleDone(
      call_id, has_payload != 0 ? &payload : nullptr);
}

void on_bridge_error(std::uint32_t call_id, std::int32_t code,
                     std::uint8_t* ptr, std::size_t len) {
  auto message = grpcdc_wasm::CopyAndFree(ptr, len);
  grpcdc_wasm::Bridge::Shared().HandleError(
      call_id, {code, std::string(message.begin(), message.end())});
}

}  // extern "C"

namespace grpcdc_wasm {
std::vector<Bytes> Unpack(const Bytes& packed) {
  std::vector<Bytes> out;
  std::size_t pos = 0;
  while (pos + 4 <= packed.size()) {
    const auto n = (static_cast<std::uint32_t>(packed[pos]) << 24) |
                   (static_cast<std::uint32_t>(packed[pos + 1]) << 16) |
                   (static_cast<std::uint32_t>(packed[pos + 2]) << 8) |
                   static_cast<std::uint32_t>(packed[pos + 3]);
    pos += 4;
    if (pos + n > packed.size()) break;
    out.emplace_back(packed.begin() + pos, packed.begin() + pos + n);
    pos += n;
  }
  return out;
}

std::vector<MdPair> DecodeMetadata(const Bytes& packed) {
  const auto flat = Unpack(packed);
  std::vector<MdPair> out;
  for (std::size_t i = 0; i + 1 < flat.size(); i += 2) {
    out.push_back({std::string(flat[i].begin(), flat[i].end()),
                   std::string(flat[i + 1].begin(), flat[i + 1].end())});
  }
  return out;
}

const std::string* MetadataGet(const std::vector<MdPair>& pairs,
                               const std::string& key) {
  for (const auto& pair : pairs) {
    if (pair.key == key) return &pair.value;
  }
  return nullptr;
}

void ServerRespond(std::uint32_t call_id, const Bytes& payload) {
  js_server_respond(call_id, payload.data(), payload.size());
}

void ServerSend(std::uint32_t call_id, const Bytes& payload) {
  js_server_send(call_id, payload.data(), payload.size());
}

void ServerComplete(std::uint32_t call_id) { js_server_complete(call_id); }

void ServerFail(std::uint32_t call_id, const Status& status) {
  js_server_fail(call_id, status.code, status.message.data(),
                 status.message.size());
}
}  // namespace grpcdc_wasm
