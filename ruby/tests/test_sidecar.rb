# gRPC over WebRTC-Direct via the Rust sidecar, Ruby to Ruby:
# two direct_sidecar processes own the WebRTC stack; the Ruby
# server and client only speak length-prefixed TCP to their
# local sidecar (Grpcdc::SidecarTransport).

require "grpcdc"
require "socket"
require_relative "test_util"

module TestSidecar
  ROOT = File.expand_path("../..", __dir__)
  SIDECAR = File.join(ROOT, "webrtc/rust/target/debug/examples/direct_sidecar")

  def self.free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def self.ensure_sidecar
    return if File.executable?(SIDECAR)

    ok = system("cargo", "build", "--example", "direct_sidecar",
                chdir: File.join(ROOT, "webrtc/rust"), out: File::NULL, err: File::NULL)
    raise "cargo build direct_sidecar failed" unless ok
  end

  def self.read_line(io, needle)
    deadline = Time.now + 30
    while Time.now < deadline
      line = io.gets
      raise "sidecar exited" if line.nil?
      return line.strip if line.include?(needle)
    end
    raise "sidecar did not print #{needle}"
  end

  def self.run
    require "echo_grpc_dc"
    require "echo_pb"
    require "echo_service"
    ensure_sidecar

    lang_port = free_port
    server_sock = TCPServer.new("127.0.0.1", lang_port)
    server = Grpcdc::Server.new
    EchoGrpcDc.register_echo_server(server, EchoService.new)
    server_thread = Thread.new do
      sock = server_sock.accept
      server.serve_transport(Grpcdc::SidecarTransport.from_socket(sock))
    end

    listen_rd, listen_wr = IO.pipe
    listen_pid = spawn(SIDECAR, "listen", "--udp", "127.0.0.1:0", "--tcp", "127.0.0.1:#{lang_port}",
                       out: listen_wr, err: File::NULL)
    listen_wr.close
    multiaddr = read_line(listen_rd, "MULTIADDR").split(" ", 2)[1]
    TestUtil.check(multiaddr.include?("/webrtc-direct/certhash/f"), "multiaddr: #{multiaddr}")

    client_port = free_port
    dial_rd, dial_wr = IO.pipe
    dial_pid = spawn(SIDECAR, "dial", "--multiaddr", multiaddr, "--tcp", "127.0.0.1:#{client_port}",
                     out: dial_wr, err: File::NULL)
    dial_wr.close
    read_line(dial_rd, "TCP")

    begin
      client = EchoGrpcDc::EchoClient.new(
        Grpcdc::Channel.new(Grpcdc::SidecarTransport.connect("127.0.0.1", client_port))
      )
      resp = client.Unary(EchoPb::EchoRequest.new(message: "hello", count: 0))
      TestUtil.assert_eq(resp.message, "echo: hello", "sidecar unary message")
      responses = client.ServerStream(EchoPb::EchoRequest.new(message: "tick", count: 3)).to_a
      TestUtil.assert_eq(responses.map(&:index), [0, 1, 2], "sidecar stream indexes")
      puts "TestSidecar OK"
    ensure
      Process.kill("TERM", dial_pid)
      Process.kill("TERM", listen_pid)
      server_thread.kill
      server_sock.close
    end
  end
end
