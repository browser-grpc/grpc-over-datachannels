# Interop harness: the dynamic (descriptor-driven) Ruby echo
# server over stdio. Loads fixtures/echo_descriptor_set.bin at
# runtime — no generated stubs involved. Used by the oracle tests.

$LOAD_PATH.unshift(File.expand_path("..", __dir__))
$LOAD_PATH.unshift(__dir__)

require "grpcdc"
require_relative "dynamic_echo"
require_relative "stdio"

ROOT = File.expand_path("../..", __dir__)

model = Grpcdc.parse_descriptor_set(File.binread(File.join(ROOT, "fixtures", "echo_descriptor_set.bin")))
transport = StdioTransport.new($stdout, $stdin)
transport.on_eof = -> { exit!(0) }
server = Grpcdc::Server.new
Grpcdc.register_dynamic_service(server, model, "echo.Echo", DynamicEchoService.new)
server.serve_transport(transport)
sleep
