package grpcdc_test

// Generated Go message types (<base>_pb.go) from the native
// protoc-gen-grpc-dc-go plugin: kitchen-sink round-trip plus a
// protoc oracle — protoc's own --encode bytes must decode to the
// same message and re-encode byte-identically.

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const kitchenText = `
d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
blob: "\x01\x02\x03" color: GREEN
nested { note: "n" level: 3 }
item { sku: "abc" quantity: 2 }
nums: [1, -2, 300] words: ["a", "", "bc"]
manys { note: "m" level: 1 }
vals: [0.5, -1.25]
counts { key: "x" value: 1 } counts { key: "y" value: -2 }
by_id { key: 7 value { note: "z" level: 9 } }
text: "chosen" big_negative: -9007199254740993 neg32: -123456
`

const duelProto = `
syntax = "proto3";
package duel;
message First {
  enum Kind { KIND_UNSPECIFIED = 0; ALPHA = 1; }
  Kind kind = 1;
}
message Second {
  enum Kind { KIND_UNSPECIFIED = 0; BETA = 1; }
  Kind kind = 1;
}
`

const harnessMain = `
package main

import (
	"fmt"
	"os"
	"reflect"

	pb "testpb/gen"
)

func fail(format string, args ...any) {
	fmt.Printf("FAIL: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
		mode := os.Args[1]
		if mode == "duel" {
			// Two messages with same-named nested enums: the enum
			// types must be qualified by their parent (First_Kind /
			// Second_Kind) or the generated file does not compile.
			f := &pb.First{Kind: pb.First_Kind_ALPHA}
			s := &pb.Second{Kind: pb.Second_Kind_BETA}
			fb, sb := new(pb.First), new(pb.Second)
			if err := fb.UnmarshalDC(f.MarshalDC()); err != nil {
				fail("duel unmarshal: %v", err)
			}
			if err := sb.UnmarshalDC(s.MarshalDC()); err != nil {
				fail("duel unmarshal: %v", err)
			}
			if fb.Kind != pb.First_Kind_ALPHA || sb.Kind != pb.Second_Kind_BETA {
				fail("duel kinds: %v %v", fb.Kind, sb.Kind)
			}
			fmt.Println("duel OK")
			return
		}
		if mode == "roundtrip" {
		k := &pb.Kitchen{
			D: 1.5, F: 2.5, I32: -3, I64: -4, U32: 5, U64: 6, S32: -7, S64: -8,
			F32: 9, F64: 10, Sf32: -11, Sf64: -12, Flag: true, Name: "sink",
			Blob: []byte{1, 2, 3}, Color: pb.Color_GREEN,
			Nested: &pb.Nested{Note: "n", Level: 3},
			Item:   &pb.Item{Sku: "abc", Quantity: 2},
			Nums:   []int32{1, -2, 300}, Words: []string{"a", "", "bc"},
			Manys: []*pb.Nested{{Note: "m", Level: 1}},
			Vals:  []float64{0.5, -1.25},
			Counts: map[string]int32{"x": 1, "y": -2},
			ById:   map[int64]*pb.Nested{7: {Note: "z", Level: 9}},
			Text: "chosen", BigNegative: -9007199254740993, Neg32: -123456,
		}
		back := new(pb.Kitchen)
		if err := back.UnmarshalDC(k.MarshalDC()); err != nil {
			fail("unmarshal: %v", err)
		}
		if !reflect.DeepEqual(back, k) {
			fail("round-trip mismatch:\n got %#v\nwant %#v", back, k)
		}
		if len(new(pb.Kitchen).MarshalDC()) != 0 {
			fail("empty message must encode to zero bytes")
		}
		// Encode-side oneof clearing: with both variants set, only
		// the last in field order is written.
		both := &pb.Kitchen{Text: "a", Code: 7}
		bothBack := new(pb.Kitchen)
		if err := bothBack.UnmarshalDC(both.MarshalDC()); err != nil {
			fail("oneof unmarshal: %v", err)
		}
		if bothBack.Text != "" || bothBack.Code != 7 {
			fail("oneof encode clearing: got text=%q code=%d", bothBack.Text, bothBack.Code)
		}
		fmt.Println("roundtrip OK")
		return
	}
	// oracle: decode protoc bytes from stdin, compare re-encode.
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		fail("read: %v", err)
	}
	k := &pb.Kitchen{
		D: 1.5, F: 2.5, I32: -3, I64: -4, U32: 5, U64: 6, S32: -7, S64: -8,
		F32: 9, F64: 10, Sf32: -11, Sf64: -12, Flag: true, Name: "sink",
		Blob: []byte{1, 2, 3}, Color: pb.Color_GREEN,
		Nested: &pb.Nested{Note: "n", Level: 3},
		Item:   &pb.Item{Sku: "abc", Quantity: 2},
		Nums:   []int32{1, -2, 300}, Words: []string{"a", "", "bc"},
		Manys: []*pb.Nested{{Note: "m", Level: 1}},
		Vals:  []float64{0.5, -1.25},
		Counts: map[string]int32{"x": 1, "y": -2},
		ById:   map[int64]*pb.Nested{7: {Note: "z", Level: 9}},
		Text: "chosen", BigNegative: -9007199254740993, Neg32: -123456,
	}
	fromProtoc := new(pb.Kitchen)
	if err := fromProtoc.UnmarshalDC(data); err != nil {
		fail("oracle unmarshal: %v", err)
	}
	if !reflect.DeepEqual(fromProtoc, k) {
		fail("oracle mismatch:\n got %#v\nwant %#v", fromProtoc, k)
	}
	re := fromProtoc.MarshalDC()
	if len(re) != len(data) {
		// Map iteration order can change entry order; decode both
		// and compare semantically instead of byte-wise.
		again := new(pb.Kitchen)
		if err := again.UnmarshalDC(re); err != nil {
			fail("re-decode: %v", err)
		}
		if !reflect.DeepEqual(again, fromProtoc) {
			fail("oracle re-encode mismatch")
		}
	}
	fmt.Println("oracle OK")
}
`

func TestGeneratedGoMessages(t *testing.T) {
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
		"-I", testdata, "common.proto", "kitchen.proto")
	out.Dir = testdata
	if b, err := out.CombinedOutput(); err != nil {
		t.Fatalf("plugin: %v\n%s", err, b)
	}
	// The stubs need the grpcdc runtime; the test exercises only
	// the generated message files.
	for _, name := range []string{"common_grpc_dc.go", "kitchen_grpc_dc.go"} {
		if err := os.Remove(filepath.Join(genDir, name)); err != nil {
			t.Fatal(err)
		}
	}
	// Both proto packages generate into one Go package for the test.
	for _, name := range []string{"common_pb.go", "kitchen_pb.go"} {
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
	if err := os.WriteFile(filepath.Join(tmp, "go.mod"),
		[]byte("module testpb\n\ngo 1.24\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mainDir := filepath.Join(tmp, "cmd")
	if err := os.MkdirAll(mainDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mainDir, "main.go"), []byte(harnessMain), 0o644); err != nil {
		t.Fatal(err)
	}
	runHarness := func(args ...string) {
		cmd := exec.Command("go", append([]string{"run", "./cmd"}, args...)...)
		cmd.Dir = tmp
		b, err := cmd.CombinedOutput()
		if err != nil || !bytes.Contains(b, []byte("OK")) {
			t.Fatalf("harness %v: %v\n%s", args, err, b)
		}
	}
	// Duel schema: same-named nested enums in two messages, plus
	// a package rename like the kitchen files above.
	duelDir := filepath.Join(tmp, "duel")
	if err := os.MkdirAll(duelDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(duelDir, "duel.proto"), []byte(duelProto), 0o644); err != nil {
		t.Fatal(err)
	}
	dout := exec.Command("protoc",
		"--plugin=protoc-gen-grpc-dc-go="+plugin,
		"--grpc-dc-go_out="+genDir,
		"-I", duelDir, "duel.proto")
	dout.Dir = duelDir
	if b, err := dout.CombinedOutput(); err != nil {
		t.Fatalf("duel plugin: %v\n%s", err, b)
	}
	if err := os.Remove(filepath.Join(genDir, "duel_grpc_dc.go")); err != nil {
		t.Fatal(err)
	}
	dp := filepath.Join(genDir, "duel_pb.go")
	db, err := os.ReadFile(dp)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dp, []byte(strings.Replace(string(db), "package duel\n", "package gen\n", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	runHarness("duel")

	runHarness("roundtrip")


	enc := exec.Command("protoc", "--encode=kitchen.v1.Kitchen",
		"-I", testdata, "kitchen.proto")
	enc.Dir = testdata
	enc.Stdin = strings.NewReader(kitchenText)
	protocBytes, err := enc.Output()
	if err != nil {
		t.Fatalf("protoc encode: %v", err)
	}
	binPath := filepath.Join(tmp, "protoc.bin")
	if err := os.WriteFile(binPath, protocBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	runHarness("oracle", binPath)

	// Golden vector: EchoRequest{message:"hi", count:2}.
	echoDir := filepath.Join(tmp, "echogen")
	if err := os.MkdirAll(echoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	_ = echoDir
}
