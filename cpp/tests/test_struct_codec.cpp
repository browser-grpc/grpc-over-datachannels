#include <memory>
#include <string>
#include <vector>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/echo_struct.hpp"
#include "examples/echo_service_impl.hpp"
#include "grpcdc/channel.hpp"
#include "grpcdc/memory_transport.hpp"
#include "grpcdc/server.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

std::shared_ptr<echo::EchoGrpcDc::EchoClient> SetupStruct(bool client_struct,
                                                          bool server_struct) {
  auto pair = grpcdc::MemoryTransportPair();
  auto server = std::make_shared<grpcdc::Server>();
  server->SetStructCodec(server_struct);
  static echo::EchoServiceImpl impl;
  echo::EchoGrpcDc::RegisterEchoServer(*server, impl);
  server->ServeTransport(pair.second);
  auto channel = std::make_shared<grpcdc::Channel>(pair.first);
  channel->SetStructCodec(client_struct);
  return std::make_shared<echo::EchoGrpcDc::EchoClient>(channel);
}

echo::EchoRequest SReq(const std::string& message, std::int32_t count) {
  echo::EchoRequest r;
  r.message = message;
  r.count = count;
  return r;
}

}  // namespace

/// Struct-codec negotiation: struct<->struct roundtrip, mismatch rejected, plain still works.
void TestStructCodec() {
  auto client = SetupStruct(true, true);

  auto unary = client->Unary(SReq("hello", 0));
  Check(unary.message == "echo: hello", "struct unary");

  auto stream = client->ServerStream(SReq("tick", 3));
  int n = 0;
  while (true) {
    try {
      stream.Recv();
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
    n++;
  }
  Check(n == 3, "struct server-stream count");

  auto joined = client->ClientStream({SReq("a", 0), SReq("b", 0)});
  Check(joined.message == "a+b", "struct client-stream");

  auto bidi = client->Bidi({SReq("x", 0), SReq("y", 0)});
  std::vector<std::string> echoed;
  while (true) {
    try {
      echoed.push_back(bidi.Recv().message);
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
  }
  Check(echoed == std::vector<std::string>({"x", "y"}), "struct bidi");

  auto struct_bytes = SReq("hello", 0).MarshalStruct();
  Check(struct_bytes.size() > 4 && struct_bytes[0] == 'D' &&
            struct_bytes[1] == 'C' && struct_bytes[2] == 'S' &&
            struct_bytes[3] == '1',
        "struct magic");
  echo::EchoRequest back;
  back.UnmarshalStruct(struct_bytes);
  Check(back.message == "hello", "struct roundtrip");

  auto mismatch = SetupStruct(true, false);
  try {
    mismatch->Unary(SReq("hello", 0));
    Check(false, "struct client vs plain server should fail");
  } catch (const grpcdc::StatusException& e) {
    Check(e.code() == grpcdc::wire::kCodeUnimplemented, "mismatch status");
  }

  auto plain = SetupStruct(false, true);
  auto plain_resp = plain->Unary(SReq("hello", 0));
  Check(plain_resp.message == "echo: hello", "plain vs struct server");

  std::printf("TestStructCodec OK\n");
}

}  // namespace tests
