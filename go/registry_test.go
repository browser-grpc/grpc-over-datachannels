package grpcdc_test

// Registry discovery (Go): ListServices from live
// registrations, GetDescriptor returns registered bytes, and
// a dynamic client calls the discovered service with the
// fetched descriptor.

import (
	"bytes"
	"context"
	"os"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

func TestRegistryDiscovery(t *testing.T) {
	echoDescriptor, err := os.ReadFile("../fixtures/echo_descriptor_set.bin")
	if err != nil {
		t.Fatal(err)
	}
	clientTransport, serverTransport := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	registry := grpcdc.NewRegistry()
	registry.RegisterDescriptor("echo.Echo", echoDescriptor)
	if err := grpcdc.ServeRegistry(server, registry); err != nil {
		t.Fatal(err)
	}
	server.ServeTransport(serverTransport)

	model, err := grpcdc.ParseDescriptorSet(grpcdc.REGISTRY_DESCRIPTOR_SET)
	if err != nil {
		t.Fatal(err)
	}
	client := grpcdc.NewDynamicClient(grpcdc.NewChannel(clientTransport), model)
	listed, err := client.Unary(context.Background(), "grpcdc.registry.v1.Registry", "ListServices",
		grpcdc.NewGenericMessage(model.Messages[".grpcdc.registry.v1.ListServicesRequest"]), nil)
	if err != nil {
		t.Fatal(err)
	}
	names := listed.Values[1]
	contains := func(want string) bool {
		for _, n := range names {
			if s, ok := n.(string); ok && s == want {
				return true
			}
		}
		return false
	}
	if !contains("echo.Echo") || !contains("grpcdc.registry.v1.Registry") {
		t.Fatalf("services = %v", names)
	}

	fetch := grpcdc.NewGenericMessage(model.Messages[".grpcdc.registry.v1.GetDescriptorRequest"])
	fetch.Set(1, "echo.Echo")
	got, err := client.Unary(context.Background(), "grpcdc.registry.v1.Registry", "GetDescriptor", fetch, nil)
	if err != nil {
		t.Fatal(err)
	}
	fetched, ok := got.Get(1)
	if !ok {
		t.Fatal("no descriptor in response")
	}
	fetchedBytes, ok := fetched.([]byte)
	if !ok || !bytes.Equal(fetchedBytes, echoDescriptor) {
		t.Fatalf("descriptor mismatch (%T)", fetched)
	}

	echoModel, err := grpcdc.ParseDescriptorSet(fetchedBytes)
	if err != nil {
		t.Fatal(err)
	}
	// The discovered client gets its own transport pair:
	// two client endpoints sharing one transport race for
	// frames (each read loop drops the other's streams),
	// which starved this call under -race in containers.
	clientTransport2, serverTransport2 := grpcdc.MemoryTransportPair()
	server.ServeTransport(serverTransport2)
	dyn := grpcdc.NewDynamicClient(grpcdc.NewChannel(clientTransport2), echoModel)
	req := grpcdc.NewGenericMessage(echoModel.Messages[".echo.EchoRequest"])
	req.Set(1, "discovered")
	resp, err := dyn.Unary(context.Background(), "echo.Echo", "Unary", req, nil)
	if err != nil {
		t.Fatal(err)
	}
	if resp.GetString(1) != "echo: discovered" {
		t.Fatalf("resp = %v", resp)
	}
}
