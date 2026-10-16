# Golden-vector codec tests: byte-exact frames from
# fixtures/vectors.json (stamped by the Racket metaprogram).

require "json"
require "grpcdc"
require_relative "test_util"

module TestCodec
  def self.run
    root = TestUtil.root
    vectors = JSON.parse(File.read(File.join(root, "fixtures", "vectors.json")))

    vectors.fetch("frames").each do |vector|
      raw = [vector.fetch("hex")].pack("H*")
      frame_type, stream_id, payload = Grpcdc.decode_frame(raw)
      TestUtil.assert_eq(frame_type, vector.fetch("type"), "#{vector['name']}: type")
      TestUtil.assert_eq(
        Grpcdc.encode_frame(frame_type, stream_id, payload), raw, "#{vector['name']}: re-encode"
      )
    end

    require "echo_pb"
    vector = vectors.fetch("protobuf").fetch("echo_request")
    req = EchoPb::EchoRequest.new(message: vector.fetch("message"), count: vector.fetch("count"))
    TestUtil.assert_eq(req.marshal_dc.unpack1("H*"), vector.fetch("hex"), "protobuf encode")
    decoded = EchoPb::EchoRequest.new
    decoded.unmarshal_dc([vector.fetch("hex")].pack("H*"))
    TestUtil.assert_eq(decoded.message, vector.fetch("message"), "protobuf message")
    TestUtil.assert_eq(decoded.count, vector.fetch("count"), "protobuf count")

    TestUtil.assert_eq(Grpcdc.status_name(0), "OK")
    TestUtil.assert_eq(Grpcdc.status_name(3), "INVALID-ARGUMENT")
    TestUtil.assert_eq(Grpcdc.status_name(999), "CODE_999")
    err = Grpcdc::StatusError.new(5, "gone")
    TestUtil.assert_eq(err.code, 5)
    TestUtil.assert_includes(err.to_s, "NOT-FOUND")
  end
end
