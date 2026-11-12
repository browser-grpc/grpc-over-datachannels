Gem::Specification.new do |spec|
  spec.name = "grpc-dc"
  spec.version = "0.41.0"
  spec.authors = ["John Davis"]
  spec.email = ["jdavis@pcprogramming.com"]
  spec.summary = "gRPC over WebRTC DataChannels, dependency-free generated Ruby runtime"
  spec.description = "Generated, stdlib-only gRPC clients and servers for Ruby speaking the gRPC wire protocol over a WebRTC DataChannel. No grpc library underneath. Kafka stubs ship separately in the kafka-grpc gem."
  spec.homepage = "https://github.com/browser-grpc/grpc-over-datachannels"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.0"
  spec.metadata = { "homepage_uri" => spec.homepage, "source_code_uri" => "https://github.com/browser-grpc/grpc-over-datachannels/tree/main/packages/grpc-ruby", "changelog_uri" => "https://github.com/browser-grpc/grpc-over-datachannels/blob/main/CHANGELOG.md" }
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
