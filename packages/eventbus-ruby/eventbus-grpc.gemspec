Gem::Specification.new do |spec|
  spec.name = "eventbus-grpc"
  spec.version = "0.38.0"
  spec.authors = ["John Davis"]
  spec.email = ["jdavis@pcprogramming.com"]
  spec.summary = "Event bus over gRPC — generated grpcdc.events.v1 Ruby clients"
  spec.description = "Event bus over gRPC — generated grpcdc.events.v1 publish/subscribe clients over WebRTC DataChannels, via the grpc-dc runtime (Ruby)."
  spec.homepage = "https://github.com/browser-grpc/grpc-over-datachannels"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.0"
  spec.metadata = { "homepage_uri" => spec.homepage, "source_code_uri" => "https://github.com/browser-grpc/grpc-over-datachannels/tree/main/packages/eventbus-ruby" }
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.add_runtime_dependency "grpc-dc", "= 0.38.0"
end
