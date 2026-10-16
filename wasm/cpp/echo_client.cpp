// Browser test entry point: runs the four Echo call shapes
// through the generated C++ WASM facade (echo_wasm_dc.hpp)
// over the JS grpc-dc bridge, then reports a JSON summary via
// the on_result import. Callback-chained throughout — the
// WASI reactor runs on the browser's single thread.

#include <cstdint>
#include <string>
#include <vector>

#include "echo_wasm_dc.hpp"

#define GRPCDC_WASM_IMPORT(name) \
  __attribute__((import_module("env"), import_name(name)))

extern "C" {
GRPCDC_WASM_IMPORT("on_result")
void on_result(const char* ptr, std::size_t len);
GRPCDC_WASM_IMPORT("on_error")
void on_error(const char* ptr, std::size_t len);
}

namespace {

using Client = echo::EchoWasmGrpcDc::EchoClient;

Client* g_client = nullptr;
std::string g_unary;
std::vector<std::int32_t> g_ticks;
std::string g_joined;
std::vector<std::string> g_echoed;

[[noreturn]] void Fail(const grpcdc_wasm::Status& st) {
  const std::string msg =
      "grpc status " + std::to_string(st.code) + ": " + st.message;
  on_error(msg.data(), msg.size());
  __builtin_trap();
}

void Check(const grpcdc_wasm::Status& st) {
  if (!st.ok()) Fail(st);
}

std::string JsonEscape(const std::string& s) {
  std::string out;
  for (char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default: out += c; break;
    }
  }
  return out;
}

void Finish() {
  std::string json = "{\"unary\":\"" + JsonEscape(g_unary) + "\",\"ticks\":[";
  for (std::size_t i = 0; i < g_ticks.size(); ++i) {
    if (i) json += ",";
    json += std::to_string(g_ticks[i]);
  }
  json += "],\"joined\":\"" + JsonEscape(g_joined) + "\",\"echoed\":[";
  for (std::size_t i = 0; i < g_echoed.size(); ++i) {
    if (i) json += ",";
    json += "\"" + JsonEscape(g_echoed[i]) + "\"";
  }
  json += "]}";
  on_result(json.data(), json.size());
}

echo::EchoRequest Req(const char* message, std::int32_t count) {
  return echo::EchoRequest(message, count);
}

void StartBidi() {
  g_client->Bidi(
      {Req("x", 0), Req("y", 0)},
      [](echo::EchoResponse resp) { g_echoed.push_back(resp.message); },
      [](grpcdc_wasm::Status st) {
        Check(st);
        Finish();
      });
}

void StartClientStream() {
  g_client->ClientStream(
      {Req("a", 0), Req("b", 0)},
      [](grpcdc_wasm::Status st, std::optional<echo::EchoResponse> resp) {
        Check(st);
        g_joined = resp->message;
        StartBidi();
      });
}

void StartServerStream() {
  g_client->ServerStream(
      Req("tick", 3),
      [](echo::EchoResponse resp) { g_ticks.push_back(resp.index); },
      [](grpcdc_wasm::Status st) {
        Check(st);
        StartClientStream();
      });
}

}  // namespace

extern "C" void run_echo_client() {
  static Client client;
  g_client = &client;
  client.Unary(Req("hello", 0),
               [](grpcdc_wasm::Status st,
                  std::optional<echo::EchoResponse> resp) {
                 Check(st);
                 g_unary = resp->message;
                 StartServerStream();
               });
}
