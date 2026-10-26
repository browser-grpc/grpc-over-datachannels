# Interop harness: the generated Ruby TestService server over
# stdio. Direction-B oracle tests spawn this and drive it with
# the official grpc-java / grpc-go interop clients through the
# bridge (oracle/bridge.mjs http2-to-dc).

$LOAD_PATH.unshift(File.expand_path("..", __dir__))
$LOAD_PATH.unshift(__dir__)
$LOAD_PATH.unshift(File.join(__dir__, "interop"))

require "grpcdc"
require_relative "interop/test_grpc_dc"
require_relative "interop/orca_grpc_dc"
require_relative "interop_service_impl"
require_relative "stdio"

transport = StdioTransport.new($stdout, $stdin)
# Exit when the driver closes our stdin.
transport.on_eof = -> { exit!(0) }
server = Grpcdc::Server.new
TestGrpcDc.register_test_service_server(server, InteropServiceImpl.new)
OrcaGrpcDc.register_open_rca_service_server(server, InteropServiceImpl.new)
server.serve_transport(transport)
sleep
