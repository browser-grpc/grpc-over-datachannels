module wasmecho

go 1.24

require grpcdc v0.0.0

replace grpcdc => ../../go

require dcwebrtc v0.0.0 // indirect

replace dcwebrtc => ../../webrtc/go
