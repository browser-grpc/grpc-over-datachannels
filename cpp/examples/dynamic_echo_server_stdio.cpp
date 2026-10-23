// Interop harness: the dynamic (descriptor-driven) C++ echo server
// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
// no generated stubs involved. Used by the oracle tests.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <thread>

#include "examples/dynamic_echo_service.hpp"
#include "examples/stdio_transport.hpp"
#include "grpcdc/dynamic.hpp"
#include "grpcdc/server.hpp"

namespace {

std::filesystem::path LocateFixtures() {
  std::filesystem::path dir = std::filesystem::current_path();
  for (int i = 0; i < 8; ++i) {
    auto direct = dir / "fixtures" / "echo_descriptor_set.bin";
    if (std::filesystem::exists(direct)) return direct;
    auto nested =
        dir / "grpc-over-datachannels" / "fixtures" / "echo_descriptor_set.bin";
    if (std::filesystem::exists(nested)) return nested;
    if (!dir.has_parent_path() || dir.parent_path() == dir) break;
    dir = dir.parent_path();
  }
  throw std::runtime_error("fixtures/echo_descriptor_set.bin not found");
}

grpcdc::Bytes ReadFile(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  return grpcdc::Bytes(std::istreambuf_iterator<char>(in),
                       std::istreambuf_iterator<char>());
}

}  // namespace

int main() {
  auto model = std::make_shared<grpcdc::dynamic::FileModel>(
      grpcdc::dynamic::ParseDescriptorSet(ReadFile(LocateFixtures())));
  auto transport = std::make_shared<echo::StdioTransport>(stdout, stdin);
  grpcdc::Server server;
  echo::DynamicEchoService impl;
  grpcdc::dynamic::RegisterDynamicService(server, *model, "echo.Echo", impl);
  server.ServeTransport(transport);
  // Exit when the driver closes our stdin (EOF), like the other
  // languages' stdio harnesses.
  while (true) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    if (std::feof(stdin) || std::ferror(stdin)) std::quick_exit(0);
  }
}
