// Interop harness: the C++ echo server over stdio. Other languages'
// tests spawn this binary and drive it with their clients, proving
// the runtimes interoperate on the same frames.
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <chrono>
#include <thread>

#include "examples/echo_service_impl.hpp"
#include "examples/stdio_transport.hpp"
#include "grpcdc/server.hpp"

int main() {
  auto transport = std::make_shared<echo::StdioTransport>(stdout, stdin);
  grpcdc::Server server;
  echo::EchoServiceImpl impl;
  echo::EchoGrpcDc::RegisterEchoServer(server, impl);
  server.ServeTransport(transport);
  // Exit when the driver closes our stdin (EOF), like the other
  // languages' stdio harnesses.
  while (true) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    if (std::feof(stdin) || std::ferror(stdin)) std::quick_exit(0);
  }
}
