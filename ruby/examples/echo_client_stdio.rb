# Interop harness: the Ruby echo client over stdio. Prints one line
# per call shape to stderr (stdout carries frames) and exits non-zero
# on any failure. Mirrors go/examples/echo_client_stdio.

$LOAD_PATH.unshift(File.expand_path("..", __dir__))
$LOAD_PATH.unshift(__dir__)

require "grpcdc"
require_relative "echo_grpc_dc"
require_relative "echo_pb"
require_relative "stdio"

def req(message, count = 0)
  EchoPb::EchoRequest.new(message: message, count: count)
end

transport = StdioTransport.new($stdout, $stdin)
client = EchoGrpcDc::EchoClient.new(Grpcdc::Channel.new(transport))

unary = client.Unary(req("hello"))
warn "unary=#{unary.message}"

ticks = client.ServerStream(req("tick", 3)).map { |r| "#{r.message}##{r.index}" }
warn "server_stream=#{ticks.join(',')}"

joined = client.ClientStream([req("a"), req("b"), req("c")])
warn "client_stream=#{joined.message}"

echoed = client.Bidi([req("x"), req("y")]).map(&:message)
warn "bidi=#{echoed.join(',')}"

md = client.Unary(req("hello", 0), { "x-echo" => "meta" })
warn "metadata=#{md.message}"

begin
  client.Unary(EchoPb::EchoRequest.new(message: "slow", count: 0, delay_ms: 400), nil, timeout: 0.05)
  warn "deadline=no error"
rescue Grpcdc::StatusError => e
  warn "deadline=#{e.code}"
end

begin
  client.Unary(req("fail"))
  warn "error_case=no error"
  exit(1)
rescue Grpcdc::StatusError => e
  warn "error_case=#{e}"
end
