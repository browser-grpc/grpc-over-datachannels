// Browser test entry point (native runtime): runs the four
// Echo call shapes with the *native* generated C++ client
// (cpp/examples/echo_grpc_dc.hpp) over the real grpcdc
// channel/endpoint runtime on a DataChannel transport, in a
// Web Worker. The endpoint runs in inline pump mode (TryRecv
// transport), so the ordinary blocking client code below
// drives itself. Mirrors wasm/zig/native's echo client.

#include <chrono>
#include <cstdint>
#include <exception>
#include <memory>
#include <string>
#include <vector>

#include "dc_transport.hpp"
#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"

#define GRPCDC_WASM_IMPORT(name) \
  __attribute__((import_module("env"), import_name(name)))

extern "C" {
GRPCDC_WASM_IMPORT("on_result")
void on_result(const char* ptr, std::size_t len);
GRPCDC_WASM_IMPORT("on_error")
void on_error(const char* ptr, std::size_t len);
}

namespace {

echo::EchoRequest Req(const char* message, std::int32_t count) {
  echo::EchoRequest req;
  req.message = message;
  req.count = count;
  return req;
}

[[noreturn]] void Fail(const std::string& message) {
  on_error(message.data(), message.size());
  __builtin_trap();
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

void Run() {
  auto transport = std::make_shared<DcTransport>();
  auto channel = std::make_shared<grpcdc::Channel>(transport);
  echo::EchoGrpcDc::EchoClient client(channel);

  echo::EchoResponse unary = client.Unary(Req("hello", 0));

  auto stream = client.ServerStream(Req("tick", 3));
  std::vector<std::int32_t> ticks;
  while (true) {
    try {
      ticks.push_back(stream.Recv().index);
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
  }

  echo::EchoResponse joined = client.ClientStream({Req("a", 0), Req("b", 0)});

  auto bidi = client.Bidi({Req("x", 0), Req("y", 0)});
  std::vector<std::string> echoed;
  while (true) {
    try {
      echoed.push_back(bidi.Recv().message);
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
  }

  echo::EchoRequest slow = Req("slow", 0);
  slow.delay_ms = 400;
  int deadline_code = 0;
  try {
    (void)client.Unary(slow, nullptr, std::chrono::milliseconds(50));
  } catch (const grpcdc::StatusException& e) {
    deadline_code = e.code();
  }

  std::string json = "{\"unary\":\"" + JsonEscape(unary.message) +
                     "\",\"ticks\":[";
  for (std::size_t i = 0; i < ticks.size(); ++i) {
    if (i) json += ",";
    json += std::to_string(ticks[i]);
  }
  json += "],\"joined\":\"" + JsonEscape(joined.message) + "\",\"echoed\":[";
  for (std::size_t i = 0; i < echoed.size(); ++i) {
    if (i) json += ",";
    json += "\"" + JsonEscape(echoed[i]) + "\"";
  }
  json += "],\"deadlineCode\":" + std::to_string(deadline_code) + "}";
  on_result(json.data(), json.size());
}

}  // namespace

extern "C" void run_echo_client() {
  try {
    Run();
  } catch (const grpcdc::StatusException& e) {
    Fail("grpc status " + std::to_string(e.code()) + ": " + e.message());
  } catch (const std::exception& e) {
    Fail(std::string("error: ") + e.what());
  } catch (...) {
    Fail("unknown error");
  }
}
