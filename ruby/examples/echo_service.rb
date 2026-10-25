# Reference Echo implementation (mirrors the Rust/JS/Go demos):
# "fail" is rejected, everything else echoes.

require "grpcdc"
require_relative "echo_pb"

class EchoService
  def Unary(ctx, req)
    if req.message == "fail"
      raise Grpcdc::StatusError.new(Grpcdc::CODE_INVALID_ARGUMENT, "asked to fail")
    end
    if req.delay_ms > 0
      sleep(req.delay_ms / 1000.0)
    end

    suffix = ""
    if ctx.metadata["x-echo"]
      suffix = " [" + ctx.metadata["x-echo"] + "]"
    end
    if ctx.metadata["x-echo-trailer"]
      ctx.set_trailers({ "x-echo-trailer" => ctx.metadata["x-echo-trailer"] })
    end
    EchoPb::EchoResponse.new(message: "echo: #{req.message}#{suffix}", index: 0)
  end

  def ServerStream(req, stream)
    if req.message == "fail"
      raise Grpcdc::StatusError.new(Grpcdc::CODE_INVALID_ARGUMENT, "asked to fail")
    end
    [0, req.count].max.times do |i|
      stream.send(EchoPb::EchoResponse.new(message: req.message, index: i))
    end
  end

  def ClientStream(stream)
    parts = []
    begin
      loop do
        req = stream.recv
        parts << req.message
      end
    rescue EOFError
      nil
    end
    stream.send_and_close(
      EchoPb::EchoResponse.new(message: parts.join("+"), index: parts.length)
    )
  end

  def Bidi(stream)
    index = 0
    begin
      loop do
        req = stream.recv
        if req.message == "fail"
          raise Grpcdc::StatusError.new(Grpcdc::CODE_INVALID_ARGUMENT, "asked to fail")
        end
        stream.send(EchoPb::EchoResponse.new(message: req.message, index: index))
        index += 1
      end
    rescue EOFError
      nil
    end
  end
end
