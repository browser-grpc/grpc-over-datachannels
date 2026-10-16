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
