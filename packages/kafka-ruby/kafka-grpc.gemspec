Gem::Specification.new do |spec|
  spec.name = "kafka-grpc"
  spec.version = "0.37.0"
  spec.authors = ["John Davis"]
  spec.summary = "Kafka over gRPC — generated grpcdc.kafka.v1 Ruby clients"
  spec.description = "Kafka over gRPC — generated grpcdc.kafka.v1 clients (produce/consume/groups/topics) speaking gRPC over WebRTC DataChannels, via the grpc-dc runtime (Ruby)."
  spec.homepage = "https://github.com/browser-grpc/grpc-over-datachannels"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.0"
  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.add_runtime_dependency "grpc-dc", "= 0.37.0"
end
