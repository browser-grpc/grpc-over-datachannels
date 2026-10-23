package grpcdc_test

// BDD schema scenarios: golden protoc bytes, generated classes.
// The case table (bdd_schemas_generated_test.go) is stamped from
// racket/bdd-schemas.rkt: protoc's own --encode output over
// webapp/testdata/{kitchen,features}.proto. Each case decodes
// with the generated classes and re-encodes byte-identically.
// The generated-classes harness mirrors pb_messages_test.go.

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func schemaHarness(cases []bddSchemaCase) string {
	var b strings.Builder
	b.WriteString(`package main

import (
	"encoding/hex"
	"fmt"
	"os"

	pb "testpb/gen"
)

func fail(format string, args ...any) {
	fmt.Printf("FAIL: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	cases := []struct{ name, message, input, expect string }{
`)
	for _, c := range cases {
		fmt.Fprintf(&b, "\t\t{%q, %q, %q, %q},\n", c.name, c.message, c.input, c.expect)
	}
	b.WriteString(`	}
	for _, c := range cases {
		input, err := hex.DecodeString(c.input)
		if err != nil {
			fail("%s: input hex: %v", c.name, err)
		}
		var got []byte
		switch c.message {
		case "kitchen":
			m := new(pb.Kitchen)
			if err := m.UnmarshalDC(input); err != nil {
				fail("%s: unmarshal: %v", c.name, err)
			}
			got = m.MarshalDC()
		case "outer":
			m := new(pb.Outer)
			if err := m.UnmarshalDC(input); err != nil {
				fail("%s: unmarshal: %v", c.name, err)
			}
			got = m.MarshalDC()
		default:
			fail("%s: unknown message %q", c.name, c.message)
		}
		if hex.EncodeToString(got) != c.expect {
			fail("%s: re-encode = %x, want %s", c.name, got, c.expect)
		}
	}
	fmt.Println("OK")
}
`)
	return b.String()
}

func TestBddSchemas(t *testing.T) {
	if _, err := exec.LookPath("protoc"); err != nil {
		t.Skip("protoc not available")
	}
	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	testdata := filepath.Join(root, "webapp", "testdata")
	tmp := t.TempDir()
	genDir := filepath.Join(tmp, "gen")
	if err := os.MkdirAll(genDir, 0o755); err != nil {
		t.Fatal(err)
	}
	plugin := filepath.Join(root, "bin", "protoc-gen-grpc-dc-go")
	out := exec.Command("protoc",
		"--plugin=protoc-gen-grpc-dc-go="+plugin,
		"--grpc-dc-go_out="+genDir,
		"-I", testdata, "common.proto", "kitchen.proto", "features.proto")
	out.Dir = testdata
	if b, err := out.CombinedOutput(); err != nil {
		t.Fatalf("plugin: %v\n%s", err, b)
	}
	for _, name := range []string{"common_grpc_dc.go", "kitchen_grpc_dc.go", "features_grpc_dc.go"} {
		if err := os.Remove(filepath.Join(genDir, name)); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"common_pb.go", "kitchen_pb.go", "features_pb.go"} {
		p := filepath.Join(genDir, name)
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		s := strings.Replace(string(b), "package common\n", "package gen\n", 1)
		s = strings.Replace(s, "package v1\n", "package gen\n", 1)
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(tmp, "go.mod"), []byte("module testpb\n\ngo 1.24\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mainDir := filepath.Join(tmp, "cmd")
	if err := os.MkdirAll(mainDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mainDir, "main.go"), []byte(schemaHarness(bddSchemaCases)), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("go", "run", "./cmd")
	cmd.Dir = tmp
	b, err := cmd.CombinedOutput()
	if err != nil || !bytes.Contains(b, []byte("OK")) {
		t.Fatalf("schema harness: %v\n%s", err, b)
	}
}
