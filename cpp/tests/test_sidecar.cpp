// gRPC over WebRTC-Direct via the Rust sidecar, C++ to C++:
// two direct_sidecar processes own the WebRTC stack; the C++
// server and client only speak length-prefixed TCP to their
// local sidecar (grpcdc::SidecarTransport).

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/echo_service_impl.hpp"
#include "grpcdc/channel.hpp"
#include "grpcdc/server.hpp"
#include "grpcdc/sidecar_transport.hpp"
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

void TestSidecar() {
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
  Check(multiaddr.find("/webrtc-direct/certhash/f") != std::string::npos,
        "multiaddr: " + multiaddr);

  int client_port = FreePort();
  Proc dial_proc;
  Check(Spawn({bin, "dial", "--multiaddr", multiaddr, "--tcp",
               "127.0.0.1:" + std::to_string(client_port)}, false, dial_proc),
        "spawn dial sidecar");
  ReadLine(dial_proc, "TCP");

  auto channel = std::make_shared<grpcdc::Channel>(
      grpcdc::SidecarTransport::Connect("127.0.0.1", static_cast<uint16_t>(client_port)));
  echo::EchoGrpcDc::EchoClient client(channel);

  echo::EchoRequest req;
  req.message = "hello";
  req.count = 0;
  echo::EchoResponse unary = client.Unary(req);
  Check(unary.message == "echo: hello", "unary: " + unary.message);

  echo::EchoRequest stream_req;
  stream_req.message = "tick";
  stream_req.count = 3;
  auto stream = client.ServerStream(stream_req);
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
  Check((indexes == std::vector<std::int32_t>{0, 1, 2}), "stream indexes");

  dial_proc.Kill();
  listen_proc.Kill();
  close(listen_fd);
  std::printf("TestSidecar OK\n");
}

}  // namespace tests
