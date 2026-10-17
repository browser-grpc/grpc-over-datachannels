#include <csignal>
#include <cstdio>
#include <unistd.h>
#include <cstdlib>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/stdio_transport.hpp"
#include "grpcdc/channel.hpp"
#include "tests/proc.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

bool BuildGo(const std::string& root, const std::string& output,
             const std::string& pkg) {
  std::string cmd = "cd \"" + root + "/go\" && go build -o \"" + output +
                    "\" " + pkg + " 2>/dev/null";
  return std::system(cmd.c_str()) == 0;
}

echo::EchoRequest Req(const std::string& m, std::int32_t c) {
  echo::EchoRequest r; r.message = m; r.count = c; return r;
}

// Raw fd IO, not stdio fread/fwrite: fread would block trying to
// fill the whole 64 KiB buffer on a pipe, stalling frame delivery.
void Pump(FILE* from, FILE* to) {
  int in_fd = fileno(from);
  int out_fd = fileno(to);
  char buf[65536];
  ssize_t n;
  while ((n = read(in_fd, buf, sizeof(buf))) > 0) {
    ssize_t written = 0;
    while (written < n) {
      ssize_t w = write(out_fd, buf + written, n - written);
      if (w <= 0) return;
      written += w;
    }
  }
}

}  // namespace

/// Interop: the C++ runtime against the Go stdio harnesses (cross-
/// language wire compatibility). Skips when Go is unavailable.
/// Mirrors python/tests/test_interop.py.
void TestInterop() {
  std::signal(SIGPIPE, SIG_IGN);  // pump writes may race peer exit
  std::string root = Root();
  std::string tmp = "/tmp/grpcdc_cpp_interop";
  const int mkdir_rc = std::system(("mkdir -p " + tmp).c_str());
  (void)mkdir_rc; // best-effort: the build below fails loudly if the dir is unusable
  std::string server_bin = tmp + "/echo_server_stdio";
  if (!BuildGo(root, server_bin, "./examples/echo_server_stdio")) {
    std::fprintf(stderr, "TestInterop SKIP (no go)\n");
    return;
  }

  {
    Proc server;
    if (!Spawn({server_bin}, false, server)) {
      std::fprintf(stderr, "TestInterop SKIP (spawn failed)\n");
      return;
    }
    auto transport =
        std::make_shared<echo::StdioTransport>(server.to_stdin, server.from_stdout);
    auto channel = std::make_shared<grpcdc::Channel>(transport);
    echo::EchoGrpcDc::EchoClient client(channel);

    echo::EchoResponse unary = client.Unary(Req("hello", 0));
    Check(unary.message == "echo: hello", "unary: " + unary.message);

    auto stream = client.ServerStream(Req("tick", 3));
    std::vector<std::int32_t> indexes;
    while (true) {
      echo::EchoResponse resp;
      try {
        resp = stream.Recv();
      } catch (const grpcdc::EndOfStream&) {
        break;
      }
      indexes.push_back(resp.index);
    }
    Check((indexes == std::vector<std::int32_t>{0, 1, 2}), "server stream");

    echo::EchoResponse joined =
        client.ClientStream({Req("a", 0), Req("b", 0), Req("c", 0)});
    Check(joined.message == "a+b+c", "client stream: " + joined.message);

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
    Check((echoed == std::vector<std::string>{"x", "y"}), "bidi");

    try {
      client.Unary(Req("fail", 0));
      Check(false, "fail should throw");
    } catch (const grpcdc::StatusException& e) {
      Check(e.code() == 3, "fail status");
    }
    server.Kill();
  }

  // Reverse: Go client harness against the C++ stdio server.
  std::string client_bin = tmp + "/echo_client_stdio";
  if (!BuildGo(root, client_bin, "./examples/echo_client_stdio")) {
    std::fprintf(stderr, "TestInterop partial SKIP (client build)\n");
    return;
  }
  std::string cpp_server = root + "/cpp/build/echo_server_stdio";
  if (!FileExists(cpp_server)) {
    std::fprintf(stderr, "TestInterop partial SKIP (cpp server not built)\n");
    return;
  }
  Proc cpp;
  Proc go_client;
  if (!Spawn({cpp_server}, false, cpp) ||
      !Spawn({client_bin}, true, go_client)) {
    std::fprintf(stderr, "TestInterop SKIP (spawn failed)\n");
    return;
  }
  std::thread pump_a([&] { Pump(go_client.from_stdout, cpp.to_stdin); });
  std::thread pump_b([&] { Pump(cpp.from_stdout, go_client.to_stdin); });
  int exit_code = go_client.WaitForExit(60000);
  cpp.Kill();
  pump_a.join();
  pump_b.join();
  Check(exit_code == 0, "go client harness exit");
  std::string stderr_text = ReadAll(go_client.from_stderr);
  go_client.Kill();
  Check(stderr_text.find("unary=echo: hello") != std::string::npos,
        "go client unary: " + stderr_text);
  Check(stderr_text.find("server_stream=tick#0,tick#1,tick#2") !=
            std::string::npos,
        "go client stream: " + stderr_text);
  Check(stderr_text.find("client_stream=a+b+c") != std::string::npos,
        "go client client-stream: " + stderr_text);
  Check(stderr_text.find("bidi=x,y") != std::string::npos,
        "go client bidi: " + stderr_text);

  std::fprintf(stderr, "TestInterop OK\n");
}

}  // namespace tests
