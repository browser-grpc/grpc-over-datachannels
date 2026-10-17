// Interop harness: the C++ echo client over stdio. Prints one line
// per call shape to stderr (stdout carries frames) and exits non-zero
// on any failure. Mirrors go/examples/echo_client_stdio.
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/stdio_transport.hpp"
#include "grpcdc/channel.hpp"

namespace {

echo::EchoRequest Req(const std::string& message, std::int32_t count) {
  echo::EchoRequest r; r.message = message; r.count = count; return r;
}

std::string Join(const std::vector<std::string>& parts, const char* sep) {
  std::string out;
  for (std::size_t i = 0; i < parts.size(); ++i) {
    if (i) out += sep;
    out += parts[i];
  }
  return out;
}

int Run() {
  auto transport = std::make_shared<echo::StdioTransport>(stdout, stdin);
  auto channel = std::make_shared<grpcdc::Channel>(transport);
  echo::EchoGrpcDc::EchoClient client(channel);

  echo::EchoResponse unary = client.Unary(Req("hello", 0));
  std::fprintf(stderr, "unary=%s\n", unary.message.c_str());

  auto stream = client.ServerStream(Req("tick", 3));
  std::vector<std::string> ticks;
  while (true) {
    echo::EchoResponse resp;
    try {
      resp = stream.Recv();
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
    ticks.push_back(resp.message + "#" + std::to_string(resp.index));
  }
  std::fprintf(stderr, "server_stream=%s\n", Join(ticks, ",").c_str());

  echo::EchoResponse joined =
      client.ClientStream({Req("a", 0), Req("b", 0), Req("c", 0)});
  std::fprintf(stderr, "client_stream=%s\n", joined.message.c_str());

  auto bidi = client.Bidi({Req("x", 0), Req("y", 0)});
  std::vector<std::string> echoed;
  while (true) {
    echo::EchoResponse resp;
    try {
      resp = bidi.Recv();
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
    echoed.push_back(resp.message);
  }
  std::fprintf(stderr, "bidi=%s\n", Join(echoed, ",").c_str());

  {
    std::map<std::string, std::string> md{{"x-echo", "meta"}};
    auto mdResp = client.Unary(Req("hello", 0), &md, std::nullopt);
    std::fprintf(stderr, "metadata=%s\n", mdResp.message.c_str());
  }

  try {
    auto slow = Req("slow", 0);
    slow.delay_ms = 400;
    (void)client.Unary(slow, nullptr, std::chrono::milliseconds(50));
    std::fprintf(stderr, "deadline=no error\n");
  } catch (const grpcdc::StatusException& e) {
    std::fprintf(stderr, "deadline=%d\n", e.code());
  }

  try {
    client.Unary(Req("fail", 0));
    std::fprintf(stderr, "error_case=no error\n");
    return 1;
  } catch (const grpcdc::StatusException& e) {
    std::fprintf(stderr, "error_case=%s\n", e.what());
  }
  return 0;
}

}  // namespace

int main() {
  int rc = 1;
  try {
    rc = Run();
  } catch (const std::exception& e) {
    std::fprintf(stderr, "error: %s\n", e.what());
    rc = 1;
  }
  // quick_exit, not return: the endpoint read thread is blocked in
  // fread(stdin) holding the stdio lock, and exit()'s stream flush
  // would deadlock against it. The harness is done either way.
  std::quick_exit(rc);
}
