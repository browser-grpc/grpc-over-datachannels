// BDD scenarios over the WebRTC-Direct sidecar transport: same
// generated scenario table as test_bdd.cpp, but the C++ client
// and server run over the real WebRTC stack owned by two
// direct_sidecar processes (Rust) -- one listens, one dials by
// multiaddr; C++ only speaks length-prefixed TCP to its local
// sidecar (grpcdc::SidecarTransport).

#include <cstdio>
#include <memory>
#include <string>
#include <thread>

#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_service_impl.hpp"
#include "grpcdc/channel.hpp"
#include "grpcdc/server.hpp"
#include "grpcdc/sidecar_transport.hpp"
#include "tests/bdd_sidecar.hpp"
#include "tests/proc.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

std::string Root() {
  for (const char* start : {".", ".."}) {
    std::string marker = std::string(start) + "/webrtc/rust/Cargo.toml";
    if (FileExists(marker)) {
      char buf[4096];
      std::string path = std::string(start) + "/.";
      if (realpath(path.c_str(), buf)) return buf;
      return start;
    }
  }
  return ".";
}

std::string Sidecar() {
  std::string root = Root();
  std::string bin = root + "/webrtc/rust/target/debug/examples/direct_sidecar";
  if (!FileExists(bin)) {
    std::string cmd = "cd " + root + "/webrtc/rust && cargo build --example direct_sidecar";
    Check(std::system(cmd.c_str()) == 0, "cargo build direct_sidecar");
  }
  return bin;
}

std::string ReadLine(Proc& proc, const std::string& needle) {
  char line[8192];
  for (int i = 0; i < 600; ++i) {
    if (std::fgets(line, sizeof(line), proc.from_stdout)) {
      std::string text = line;
      if (text.find(needle) != std::string::npos) {
        while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) text.pop_back();
        return text;
      }
    } else {
      usleep(50000);
    }
  }
  Check(false, "sidecar did not print " + needle);
  return "";
}

}  // namespace

void TestBddSidecar() {
  std::string bin = Sidecar();
  int lang_port = FreePort();

  int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(static_cast<uint16_t>(lang_port));
  Check(bind(listen_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0, "bind lang port");
  Check(listen(listen_fd, 4) == 0, "listen lang port");

  auto server = std::make_shared<grpcdc::Server>();
  static echo::EchoServiceImpl impl;
  echo::EchoGrpcDc::RegisterEchoServer(*server, impl);
  std::thread server_thread([&] {
    int fd = accept(listen_fd, nullptr, nullptr);
    server->ServeTransport(std::make_shared<grpcdc::SidecarTransport>(fd));
  });
  server_thread.detach();

  Proc listen_proc;
  Check(Spawn({bin, "listen", "--udp", "127.0.0.1:0", "--tcp",
               "127.0.0.1:" + std::to_string(lang_port)}, false, listen_proc),
        "spawn listen sidecar");
  std::string multiaddr_line = ReadLine(listen_proc, "MULTIADDR");
  std::string multiaddr = multiaddr_line.substr(multiaddr_line.find(' ') + 1);

  int client_port = FreePort();
  Proc dial_proc;
  Check(Spawn({bin, "dial", "--multiaddr", multiaddr, "--tcp",
               "127.0.0.1:" + std::to_string(client_port)}, false, dial_proc),
        "spawn dial sidecar");
  ReadLine(dial_proc, "TCP");

  auto channel = std::make_shared<grpcdc::Channel>(
      grpcdc::SidecarTransport::Connect("127.0.0.1", static_cast<uint16_t>(client_port)));
  echo::EchoGrpcDc::EchoClient client(channel);

  RunBddScenarios(channel, client);

  dial_proc.Kill();
  listen_proc.Kill();
  close(listen_fd);
  std::printf("TestBddSidecar OK\n");
}

}  // namespace tests
