# Dynamic Echo implementation: the reference Echo semantics built
# purely on the descriptor-driven runtime (no generated stubs).
# Field numbers come from proto/echo.proto: EchoRequest{message=1,
# count=2}, EchoResponse{message=1, index=2}.

require "grpcdc"

# Handler protocol for Grpcdc.register_dynamic_service.
class DynamicEchoService
  def unary(ctx, method, request)
    message = request.get_string(1)
    if message == "fail"
      raise Grpcdc::StatusError.new(Grpcdc::CODE_INVALID_ARGUMENT, "asked to fail")
    end

    suffix = ""
    suffix = " [" + ctx.metadata["x-echo"] + "]" if ctx.metadata["x-echo"]
    response(method, "echo: #{message}#{suffix}", 0)
  end

  def server_stream(_ctx, method, request, send)
    [0, request.get_int(2)].max.times do |i|
      send.call(response(method, request.get_string(1), i))
    end
  end

  def client_stream(_ctx, method, requests)
    parts = requests.map { |req| req.get_string(1) }
    response(method, parts.join("+"), parts.length)
  end

  def bidi(_ctx, method, requests, send)
    requests.each_with_index do |req, index|
      send.call(response(method, req.get_string(1), index))
    end
  end

  private

  def response(method, message, index)
    Grpcdc::GenericMessage.new(method.output).set(1, message).set(2, index)
  end
end
