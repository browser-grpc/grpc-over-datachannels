// Interop harness: the generated C++ TestService server over
// stdio. Direction-B oracle tests spawn this binary and drive
// it with the official grpc-java / grpc-go interop clients
// through the bridge (oracle/bridge.mjs http2-to-dc).
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <chrono>
#include <thread>

#include "examples/interop_service_impl.hpp"
#include "examples/stdio_transport.hpp"
#include "grpcdc/server.hpp"

int main() {
  auto transport = std::make_shared<echo::StdioTransport>(stdout, stdin);
  grpcdc::Server server;
  grpc::testing::InteropServiceImpl impl;
  grpc::testing::TestGrpcDc::RegisterTestServiceServer(server, impl);
  xds::service::orca::v3::OrcaGrpcDc::RegisterOpenRcaServiceServer(server, impl);
  server.ServeTransport(transport);
  // Exit when the driver closes our stdin (EOF), like the other
  // languages' stdio harnesses.
  while (true) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    if (std::feof(stdin) || std::ferror(stdin)) std::quick_exit(0);
  }
}
