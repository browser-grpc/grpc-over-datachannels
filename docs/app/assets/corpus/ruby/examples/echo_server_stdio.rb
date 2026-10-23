# Interop harness: the Ruby echo server over stdio. Other
# languages' tests spawn this and drive it with their client.

$LOAD_PATH.unshift(File.expand_path("..", __dir__))
$LOAD_PATH.unshift(__dir__)

require "grpcdc"
require_relative "echo_grpc_dc"
require_relative "echo_service"
require_relative "stdio"

transport = StdioTransport.new($stdout, $stdin)
# Exit when the driver closes our stdin.
transport.on_eof = -> { exit!(0) }
server = Grpcdc::Server.new
EchoGrpcDc.register_echo_server(server, EchoService.new)
server.serve_transport(transport)
sleep
