// Command compiler is the browser schema compiler for the
// grpc-dc web app: protocompile (the compiler library behind
// buf) built to WebAssembly. It replaces the protoc binary for
// the fully client-side flow — uploaded .proto sources live in
// an in-memory map, and the compiled FileDescriptorSet bytes are
// handed back to the page, where the generated JS generators
// (webapp/gen/generators.js) consume exactly the descriptor
// model the native Racket plugins walk (racket/desc.rkt).
//
// JS entry point:
//
//	__grpcdcCompile(json) -> json
//
// Input:  {"files": {"echo.proto": "syntax = ...", ...},
//         "entries": ["echo.proto", ...]}
// Output: {"ok": true, "set": "<base64 FileDescriptorSet>"}
//      or {"ok": false, "error": "file.proto:3:5: ..."}
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"syscall/js"

	"github.com/bufbuild/protocompile"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/types/descriptorpb"

	_ "google.golang.org/protobuf/types/known/apipb"
	_ "google.golang.org/protobuf/types/known/sourcecontextpb"
	_ "google.golang.org/protobuf/types/known/typepb"
)

type compileRequest struct {
	Files   map[string]string `json:"files"`
	Entries []string          `json:"entries"`
}

func result(payload map[string]any) string {
	b, _ := json.Marshal(payload)
	return string(b)
}

func compile(_ js.Value, args []js.Value) any {
	if len(args) != 1 {
		return result(map[string]any{"ok": false, "error": "expected one JSON argument"})
	}
	var req compileRequest
	if err := json.Unmarshal([]byte(args[0].String()), &req); err != nil {
		return result(map[string]any{"ok": false, "error": "bad request: " + err.Error()})
	}
	compiler := protocompile.Compiler{
		Resolver: protocompile.WithStandardImports(&protocompile.SourceResolver{
			Accessor: protocompile.SourceAccessorFromMap(req.Files),
		}),
	}
	files, err := compiler.Compile(context.Background(), req.Entries...)
	if err != nil {
		return result(map[string]any{"ok": false, "error": err.Error()})
	}
	set := &descriptorpb.FileDescriptorSet{}
	for _, f := range files {
		set.File = append(set.File, protodesc.ToFileDescriptorProto(f))
	}
	raw, err := proto.Marshal(set)
	if err != nil {
		return result(map[string]any{"ok": false, "error": "marshal descriptor set: " + err.Error()})
	}
	return result(map[string]any{"ok": true, "set": base64.StdEncoding.EncodeToString(raw)})
}

func main() {
	js.Global().Set("__grpcdcCompile", js.FuncOf(compile))
	// Keep the Go runtime alive to serve calls.
	select {}
}
