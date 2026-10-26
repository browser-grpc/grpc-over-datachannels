#include <cstdio>
#include <cstring>
#include <functional>
#include <thread>
#include <memory>
#include <string>
#include <vector>

#include "examples/empty_messages.hpp"
#include "examples/messages_messages.hpp"
#include "examples/test_grpc_dc.hpp"
#include "examples/stdio_transport.hpp"
#include "grpcdc/channel.hpp"
#include "grpcdc/status.hpp"
#include "interop_cases.hpp"
#include "proc.hpp"
#include "test_util.hpp"

namespace tests {
namespace {

using grpc::testing::EchoStatus;
using grpc::testing::Empty;
using grpc::testing::Payload;
using grpc::testing::ResponseParameters;
using grpc::testing::SimpleRequest;
using grpc::testing::StreamingInputCallRequest;
using grpc::testing::StreamingOutputCallRequest;
using grpc::testing::TestGrpcDc;

Payload MakePayload(int size) {
  Payload p;
  p.body.assign(static_cast<size_t>(size), 0);
  return p;
}

StreamingOutputCallRequest StreamRequest(const std::vector<int>& resp_sizes, int payload_size) {
  StreamingOutputCallRequest req;
  req.payload = MakePayload(payload_size);
  for (int size : resp_sizes) {
    ResponseParameters p;
    p.size = size;
    req.response_parameters.push_back(p);
  }
  return req;
}

void ExpectStatus(int code, const std::string& message, const std::string& what,
                  const std::function<void()>& call) {
  try {
    call();
  } catch (const grpcdc::StatusException& e) {
    Check(e.code() == code, what + ": code mismatch");
    if (!message.empty()) {
      Check(e.message() == message, what + ": message '" + e.message() + "' != '" + message + "'");
    }
    return;
  }
  throw std::runtime_error(what + ": expected status, call succeeded");
}

std::vector<int> Sizes(const int* data, int count) {
  return std::vector<int>(data, data + count);
}

void RunCases(TestGrpcDc::TestServiceClient& client, TestGrpcDc::UnimplementedServiceClient& unimpl) {
  for (const auto& row : kInteropCases) {
    const std::string name = row.name;
    const std::string kind = row.kind;
    const std::vector<int> req_sizes = row.reqSizes;
    const std::vector<int> resp_sizes = row.respSizes;
    if (kind == "EMPTY") {
      client.EmptyCall(Empty{});
    } else if (kind == "LARGE_UNARY") {
      SimpleRequest req;
      req.response_size = resp_sizes[0];
      req.payload = MakePayload(req_sizes[0]);
      auto resp = client.UnaryCall(req);
      Check(resp.payload.has_value() && resp.payload->body.size() == static_cast<size_t>(resp_sizes[0]),
            name + ": body size");
    } else if (kind == "CLIENT_STREAMING") {
      std::vector<StreamingInputCallRequest> reqs;
      int total = 0;
      for (int size : req_sizes) {
        StreamingInputCallRequest r;
        r.payload = MakePayload(size);
        reqs.push_back(r);
        total += size;
      }
      auto resp = client.StreamingInputCall(reqs);
      Check(resp.aggregated_payload_size == total, name + ": aggregated");
    } else if (kind == "SERVER_STREAMING") {
      auto stream = client.StreamingOutputCall(StreamRequest(resp_sizes, 0));
      for (int size : resp_sizes) {
        auto resp = stream.Recv();
        Check(resp.payload.has_value() && resp.payload->body.size() == static_cast<size_t>(size), name + ": body size");
      }
      bool eof = false;
      try {
        stream.Recv();
      } catch (const grpcdc::EndOfStream&) {
        eof = true;
      }
      Check(eof, name + ": expected EOF");
    } else if (kind == "PING_PONG") {
      std::vector<StreamingOutputCallRequest> reqs;
      for (size_t i = 0; i < resp_sizes.size(); ++i) {
        reqs.push_back(StreamRequest({resp_sizes[i]}, req_sizes[i]));
      }
      auto stream = client.FullDuplexCall(reqs);
      for (int size : resp_sizes) {
        auto resp = stream.Recv();
        Check(resp.payload.has_value() && resp.payload->body.size() == static_cast<size_t>(size), name + ": body size");
      }
    } else if (kind == "EMPTY_STREAM") {
      auto stream = client.FullDuplexCall({});
      bool eof = false;
      try {
        stream.Recv();
      } catch (const grpcdc::EndOfStream&) {
        eof = true;
      }
      Check(eof, name + ": expected EOF");
    } else if (kind == "CUSTOM_METADATA") {
      // Upstream custom_metadata, duplex leg (mirrors the Java runner).
      const std::string trailing_bin = "CgsKCwoL";  // base64 of 0a 0b 0a 0b 0a 0b
      grpcdc::Metadata md;
      md["x-grpc-test-echo-initial"] = "test_initial_metadata_value";
      md["x-grpc-test-echo-trailing-bin"] = trailing_bin;
      auto stream = client.FullDuplexCall({StreamRequest({1}, 1)}, &md);
      auto resp = stream.Recv();
      Check(resp.payload.has_value() && resp.payload->body.size() == 1, name + ": body");
      bool eof = false;
      try {
        stream.Recv();
      } catch (const grpcdc::EndOfStream&) {
        eof = true;
      }
      Check(eof, name + ": expected EOF");
      auto initial = stream.Headers().find("x-grpc-test-echo-initial");
      Check(initial != stream.Headers().end() && initial->second == "test_initial_metadata_value", name + ": initial");
      auto trailing = stream.Trailers().find("x-grpc-test-echo-trailing-bin");
      Check(trailing != stream.Trailers().end() && trailing->second == trailing_bin, name + ": trailing");
    } else if (kind == "STATUS_UNARY") {
      SimpleRequest req;
      EchoStatus status;
      status.code = row.statusCode;
      status.message = row.statusMessage;
      req.response_status = status;
      ExpectStatus(row.statusCode, row.statusMessage, name, [&] { client.UnaryCall(req); });
    } else if (kind == "STATUS_DUPLEX") {
      auto req = StreamRequest({0}, 0);
      EchoStatus status;
      status.code = row.statusCode;
      status.message = row.statusMessage;
      req.response_status = status;
      ExpectStatus(row.statusCode, row.statusMessage, name, [&] {
        auto stream = client.FullDuplexCall({req});
        stream.Recv();
      });
    } else if (kind == "UNIMPLEMENTED_METHOD") {
      ExpectStatus(row.statusCode, "", name, [&] { client.UnimplementedCall(Empty{}); });
    } else if (kind == "UNIMPLEMENTED_SERVICE") {
      ExpectStatus(row.statusCode, "", name, [&] { unimpl.UnimplementedCall(Empty{}); });
    } else {
      throw std::runtime_error("unknown interop kind " + kind);
    }
    std::fprintf(stdout, "interop case ok: %s\n", name.c_str());
  }
}

bool TcpConnectable(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return false;
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<uint16_t>(port));
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  bool ok = connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0;
  close(fd);
  return ok;
}

}  // namespace

/// Interop client grading: the generated C++ TestService client
/// runs the canonical grpc interop cases (generated table:
/// interop_cases.hpp) against the official grpc-go
/// TestServiceServer, through the bridge (dc-to-http2, stdio =
/// DataChannel). Mirrors the Java/C#/Kotlin/Scala/Dart interop
/// oracle suites. Skips when the oracle server binary is not
/// built (Dockerfile.ci builds it).
void TestInteropOracle() {
  const std::string root = Root();
  const std::string server_bin = root + "/oracle/go-interop/interop-server";
  if (!FileExists(server_bin)) {
    std::fprintf(stderr, "TestInteropOracle SKIP (go interop server not built)\n");
    return;
  }
  const int port = FreePort();
  Proc server;
  if (!Spawn({server_bin, "-port", std::to_string(port)}, true, server)) {
    std::fprintf(stderr, "TestInteropOracle SKIP (spawn go server)\n");
    return;
  }
  // Drain stderr so the pipe never blocks.
  std::thread drain([](FILE* f) { ReadAll(f); }, server.from_stderr);
  drain.detach();

  bool ready = false;
  for (int i = 0; i < 300 && !ready; ++i) {
    if (TcpConnectable(port)) {
      ready = true;
    } else {
      usleep(100 * 1000);
    }
  }
  Check(ready, "go interop server did not start");

  Proc bridge;
  if (!Spawn({"node", root + "/oracle/bridge.mjs", "dc-to-http2", "--grpc",
              "127.0.0.1:" + std::to_string(port)},
             false, bridge)) {
    std::fprintf(stderr, "TestInteropOracle SKIP (spawn bridge)\n");
    server.Kill();
    return;
  }
  {
    auto transport = std::make_shared<echo::StdioTransport>(bridge.to_stdin, bridge.from_stdout);
    auto channel = std::make_shared<grpcdc::Channel>(transport);
    TestGrpcDc::TestServiceClient client(channel);
    TestGrpcDc::UnimplementedServiceClient unimpl(channel);
    RunCases(client, unimpl);
  }
  bridge.Kill();
  server.Kill();
  std::fprintf(stdout, "TestInteropOracle OK\n");
}

}  // namespace tests
