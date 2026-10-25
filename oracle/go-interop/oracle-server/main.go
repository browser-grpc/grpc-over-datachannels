// Oracle interop server: the upstream grpc-go interop server
// main (google.golang.org/grpc/interop/server) plus the gzip
// encoding import, which upstream's main omits — without it the
// server rejects compressed requests ("Decompressor is not
// installed for grpc-encoding gzip") and the compressed interop
// cases cannot run against it.
package main

import (
	"flag"
	"net"
	"strconv"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/alts"
	_ "google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/grpclog"
	"google.golang.org/grpc/interop"
	"google.golang.org/grpc/orca"
	"google.golang.org/grpc/testdata"

	testgrpc "google.golang.org/grpc/interop/grpc_testing"
)

var (
	useTLS     = flag.Bool("use_tls", false, "Connection uses TLS if true, else plain TCP")
	useALTS    = flag.Bool("use_alts", false, "Connection uses ALTS if true (this option can only be used on GCP)")
	altsHSAddr = flag.String("alts_handshaker_service_address", "", "ALTS handshaker service address")
	certFile   = flag.String("tls_cert_file", "", "The TLS cert file")
	keyFile    = flag.String("tls_key_file", "", "The TLS key file")
	port       = flag.Int("port", 10000, "The server port")

	logger = grpclog.Component("interop")
)

func main() {
	flag.Parse()
	if *useTLS && *useALTS {
		logger.Fatal("-use_tls and -use_alts cannot be both set to true")
	}
	p := strconv.Itoa(*port)
	lis, err := net.Listen("tcp", ":"+p)
	if err != nil {
		logger.Fatalf("failed to listen: %v", err)
	}
	logger.Infof("interop server listening on %v", lis.Addr())
	opts := []grpc.ServerOption{orca.CallMetricsServerOption(nil)}
	if *useTLS {
		if *certFile == "" {
			*certFile = testdata.Path("server1.pem")
		}
		if *keyFile == "" {
			*keyFile = testdata.Path("server1.key")
		}
		creds, err := credentials.NewServerTLSFromFile(*certFile, *keyFile)
		if err != nil {
			logger.Fatalf("Failed to generate credentials: %v", err)
		}
		opts = append(opts, grpc.Creds(creds))
	} else if *useALTS {
		altsOpts := alts.DefaultServerOptions()
		if *altsHSAddr != "" {
			altsOpts.HandshakerServiceAddress = *altsHSAddr
		}
		altsTC := alts.NewServerCreds(altsOpts)
		opts = append(opts, grpc.Creds(altsTC))
	}
	server := grpc.NewServer(opts...)
	metricsRecorder := orca.NewServerMetricsRecorder()
	// Upstream's main also lowers the OOB reporting interval via
	// a grpc-internal hook unavailable outside the grpc module;
	// the ORCA interop cases here grade per-RPC trailers, not
	// OOB report cadence, so the default options suffice (the
	// Register error, if any, is ignored just like upstream).
	sopts := orca.ServiceOptions{
		MinReportingInterval:  time.Second,
		ServerMetricsProvider: metricsRecorder,
	}
	orca.Register(server, sopts)
	testgrpc.RegisterTestServiceServer(server, interop.NewTestServer(interop.NewTestServerOptions{MetricsRecorder: metricsRecorder}))
	server.Serve(lis)
}
