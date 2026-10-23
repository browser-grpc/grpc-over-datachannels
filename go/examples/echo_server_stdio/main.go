// Interop harness: the Go echo server over stdio. Other languages'
// tests spawn this binary and drive it with their client, proving the
// runtimes interoperate on the same frames.
package main

import (
	"os"

	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

func main() {
	transport := echo.NewStdioTransport(os.Stdout, os.Stdin)
	// Exit when the driver closes our stdin (e.g. the oracle bridge
	// was killed): a stdio harness must not outlive its driver.
	transport.OnEOF = func() { os.Exit(0) }
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	server.ServeTransport(transport)
	select {} // serve until stdin EOF or killed by the test driver
}
