# Gem packaging for the generated Ruby runtime.
# Build from the export root: gem build ruby/grpc-dc.gemspec
Gem::Specification.new do |spec|
  spec.name = "grpc-dc"
  spec.version = "0.37.0"
  spec.authors = ["John Davis"]
  spec.summary = "gRPC over WebRTC DataChannels, dependency-free generated Ruby runtime"
  spec.description = "Generated, stdlib-only gRPC clients and servers for Ruby speaking the gRPC wire protocol over a WebRTC DataChannel, plus generated stubs (incl. grpcdc.kafka.v1). No grpc library underneath."
  spec.homepage = "https://github.com/browser-grpc/grpc-over-datachannels"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.0"
  spec.files = Dir["ruby/grpcdc.rb", "ruby/grpcdc/**/*.rb", "ruby/README.md"]
  spec.require_paths = ["ruby"]
end
