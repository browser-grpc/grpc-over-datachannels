#include <string>

#include "examples/echo_messages.hpp"
#include "grpcdc/codec.hpp"
#include "tests/fixtures.hpp"
#include "tests/test_util.hpp"

namespace tests {

/// Golden-vector codec tests (Fixtures stamped by the metaprogram).
void TestCodec() {
  for (auto& v : FrameVectors()) {
    grpcdc::Bytes raw = FromHex(v.frame_hex);
    grpcdc::Codec::Frame frame = grpcdc::Codec::DecodeFrame(raw);
    Check(frame.type == v.type, std::string(v.name) + ": type");
    Check(frame.stream_id == v.stream_id, std::string(v.name) + ": stream");
    Check(ToHex(grpcdc::Codec::EncodeFrame(frame.type, frame.stream_id,
                                           frame.payload)) == v.frame_hex,
          std::string(v.name) + ": re-encode");
    Check(ToHex(frame.payload) == v.payload_hex,
          std::string(v.name) + ": payload");
  }

  echo::EchoRequest req; req.message = "hi"; req.count = 2;
  Check(ToHex(req.MarshalDc()) == ProtoHex(), "protobuf encode");
  echo::EchoRequest decoded;
  decoded.UnmarshalDc(FromHex(ProtoHex()));
  Check(decoded.message == "hi" && decoded.count == 2, "protobuf decode");

  Check(grpcdc::wire::StatusName(0) == "OK", "status 0");
  Check(grpcdc::wire::StatusName(3) == "INVALID-ARGUMENT", "status 3");
  Check(grpcdc::wire::StatusName(999) == "CODE_999", "status 999");
  std::fprintf(stderr, "TestCodec OK\n");
}

}  // namespace tests
