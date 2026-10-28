module wasmecho

go 1.24

require github.com/browser-grpc/grpc-over-datachannels/go v0.33.0

require github.com/browser-grpc/grpc-over-datachannels/webrtc/go v0.33.0 // indirect

replace github.com/browser-grpc/grpc-over-datachannels/go => ../../go

replace github.com/browser-grpc/grpc-over-datachannels/webrtc/go => ../../webrtc/go
