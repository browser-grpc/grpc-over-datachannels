// Interop harness: the dynamic (descriptor-driven) Go echo server
// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
// no generated stubs involved. Used by the oracle tests.
package main

import (
	"os"
	"path/filepath"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

func main() {
	// Locate fixtures/echo_descriptor_set.bin relative to the working
	// directory or the executable (tests run from different cwds).
	candidates := []string{
		filepath.Join("..", "fixtures", "echo_descriptor_set.bin"),
		filepath.Join("fixtures", "echo_descriptor_set.bin"),
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		for i := 0; i < 6; i++ {
			candidates = append(candidates, filepath.Join(dir, "fixtures", "echo_descriptor_set.bin"))
			dir = filepath.Dir(dir)
		}
	}
	var data []byte
	var err error
	for _, candidate := range candidates {
		if data, err = os.ReadFile(candidate); err == nil {
			break
		}
	}
	if err != nil {
		panic(err)
	}
	model, err := grpcdc.ParseDescriptorSet(data)
	if err != nil {
		panic(err)
	}
	transport := echo.NewStdioTransport(os.Stdout, os.Stdin)
	transport.OnEOF = func() { os.Exit(0) }
	server := grpcdc.NewServer()
	if err := grpcdc.RegisterDynamicService(server, model, "echo.Echo", echo.DynamicEchoService{}); err != nil {
		panic(err)
	}
	server.ServeTransport(transport)
	select {}
}
