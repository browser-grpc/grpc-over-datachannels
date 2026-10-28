// Starter projects for arbitrary schemas: given the compiled file
// models (describeFiles output) and the generated stub files, emit
// runnable example projects that wire the generated stubs to the
// generated dependency-free runtimes over an in-memory loopback
// transport (the same shape a real RTCDataChannel plugs into).
//
// Emitted layouts (paths relative to the starter-kit zip root):
//   projects/web/     index.html + main.js (browser, loopback demo)
//   projects/node/    main.mjs + package.json (`node main.mjs`)
//   projects/python/  main.py + gen/ copies (`python3 main.py`)
//   projects/go/      main.go + go.mod + gen/ copies (`go run .`)
// Server handlers return default (zero-value) responses; edit them
// to add real behavior. Client code calls every method once and
// prints what came back.

function baseOf(fileName) {
  return fileName.split("/").pop().replace(/\.proto$/, "");
}

function servicesOf(models) {
  const out = [];
  for (const f of models) {
    for (const svc of f.services || []) {
      out.push({ file: f, svc });
    }
  }
  return out;
}

function jsLower(name) {
  return name ? name[0].toLowerCase() + name.slice(1) : name;
}

function snake(name) {
  return name
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .toLowerCase();
}

function jsMain(models, browser) {
  const svcs = servicesOf(models);
  const lines = [];
  lines.push("// Starter: generated server + client for your schema,");
  lines.push("// wired over an in-memory loopback DataChannel pair.");
  lines.push("// Replace the default responses in `handlers` with real logic.");
  lines.push('import { Channel } from "../../runtime/js/channel.js";');
  lines.push('import { Server } from "../../runtime/js/server.js";');
  lines.push('import { memoryDataChannelPair } from "../../runtime/js/loopback.js";');
  const stubVars = new Map();
  for (const { file, svc } of svcs) {
    const b = baseOf(file.name);
    if (!stubVars.has(b)) {
      stubVars.set(b, true);
      lines.push(`import * as pb_${b} from "../../gen/js/${b}_pb.js";`);
      lines.push(`import * as stub_${b} from "../../gen/js/${b}_grpc_dc.js";`);
    }
  }
  lines.push("");
  lines.push("async function* one(item) { yield item; }");
  lines.push("");
  for (const { file, svc } of svcs) {
    const b = baseOf(file.name);
    lines.push(`const ${svc.name}Handlers = {`);
    for (const m of svc.methods) {
      const out = `pb_${b}.${m.output}`;
      const key = jsLower(m.name);
      if (m.kind === "unary") {
        lines.push(`  async ${key}(req) { return new ${out}(); },`);
      } else if (m.kind === "server-streaming") {
        lines.push(`  async *${key}(req) { yield new ${out}(); },`);
      } else if (m.kind === "client-streaming") {
        lines.push(`  async ${key}(reqs) { for await (const _ of reqs) { /* consume */ } return new ${out}(); },`);
      } else {
        lines.push(`  async *${key}(reqs) { for await (const _ of reqs) { yield new ${out}(); } },`);
      }
    }
    lines.push("};");
    lines.push("");
  }
  lines.push("export async function run(log) {");
  lines.push("  const [a, b] = memoryDataChannelPair();");
  lines.push("  const server = new Server();");
  for (const { file, svc } of svcs) {
    lines.push(`  server.addService(stub_${baseOf(file.name)}.create${svc.name}Service(${svc.name}Handlers));`);
  }
  lines.push("  server.serve(b);");
  lines.push("  const channel = new Channel(a);");
  for (const { file, svc } of svcs) {
    const b = baseOf(file.name);
    lines.push(`  const ${svc.name} = new stub_${b}.${svc.name}Client(channel);`);
    for (const m of svc.methods) {
      const req = `new pb_${b}.${m.input}()`;
      const key = jsLower(m.name);
      if (m.kind === "unary") {
        lines.push(`  log("${svc.name}.${m.name} ->", JSON.stringify(await ${svc.name}.${key}(${req})));`);
      } else if (m.kind === "server-streaming") {
        lines.push(`  { let n = 0; for await (const _ of await ${svc.name}.${key}(${req})) n++; log("${svc.name}.${m.name} ->", n + " response(s)"); }`);
      } else if (m.kind === "client-streaming") {
        lines.push(`  log("${svc.name}.${m.name} ->", JSON.stringify(await ${svc.name}.${key}(one(${req}))));`);
      } else {
        lines.push(`  { let n = 0; for await (const _ of await ${svc.name}.${key}(one(${req}))) n++; log("${svc.name}.${m.name} ->", n + " response(s)"); }`);
      }
    }
  }
  lines.push("}");
  lines.push("");
  if (browser) {
    lines.push("const out = document.getElementById(\"out\");");
    lines.push("run((...args) => { out.textContent += args.join(\" \") + \"\\n\"; })");
    lines.push("  .catch((e) => { out.textContent += \"error: \" + e.message + \"\\n\"; });");
  } else {
    lines.push("await run((...args) => console.log(...args));");
  }
  return lines.join("\n") + "\n";
}

function goMain(models) {
  const svcs = servicesOf(models);
  const lines = [];
  lines.push("// Starter: generated server + client for your schema over");
  lines.push("// an in-memory loopback transport. Replace the default");
  lines.push("// responses in the impl types with real logic.");
  lines.push("package main");
  lines.push("");
  lines.push("import (");
  lines.push('\t"context"');
  lines.push('\t"fmt"');
  lines.push('\t"io"');
  lines.push("");
  lines.push('\tgrpcdc "github.com/browser-grpc/grpc-over-datachannels/go"');
  lines.push('\tgen "grpcstarter/gen"');
  lines.push(")");
  lines.push("");
  for (const { svc } of svcs) {
    lines.push(`type ${svc.name}Impl struct{}`);
    lines.push("");
    for (const m of svc.methods) {
      if (m.kind === "unary") {
        lines.push(`func (${svc.name}Impl) ${m.name}(ctx context.Context, req *gen.${m.input}) (*gen.${m.output}, error) {`);
        lines.push(`\treturn &gen.${m.output}{}, nil`);
      } else if (m.kind === "server-streaming") {
        lines.push(`func (${svc.name}Impl) ${m.name}(req *gen.${m.input}, stream gen.${svc.name}${m.name}Server) error {`);
        lines.push(`\treturn stream.Send(&gen.${m.output}{})`);
      } else if (m.kind === "client-streaming") {
        lines.push(`func (${svc.name}Impl) ${m.name}(stream gen.${svc.name}${m.name}Server) error {`);
        lines.push("\tfor {");
        lines.push("\t\tif _, err := stream.Recv(); err != nil {");
        lines.push("\t\t\tbreak");
        lines.push("\t\t}");
        lines.push("\t}");
        lines.push(`\treturn stream.SendAndClose(&gen.${m.output}{})`);
      } else {
        lines.push(`func (${svc.name}Impl) ${m.name}(stream gen.${svc.name}${m.name}Server) error {`);
        lines.push("\tfor {");
        lines.push("\t\tif _, err := stream.Recv(); err != nil {");
        lines.push("\t\t\treturn nil");
        lines.push("\t\t}");
        lines.push(`\t\tif err := stream.Send(&gen.${m.output}{}); err != nil {`);
        lines.push("\t\t\treturn err");
        lines.push("\t\t}");
        lines.push("\t}");
      }
      lines.push("}");
      lines.push("");
    }
  }
  lines.push("func must(err error) {");
  lines.push("\tif err != nil {");
  lines.push("\t\tpanic(err)");
  lines.push("\t}");
  lines.push("}");
  lines.push("");
  lines.push("func main() {");
  lines.push("\ta, b := grpcdc.MemoryTransportPair()");
  lines.push("\tserver := grpcdc.NewServer()");
  for (const { svc } of svcs) {
    lines.push(`\tgen.Register${svc.name}Server(server, ${svc.name}Impl{})`);
  }
  lines.push("\tserver.ServeTransport(b)");
  lines.push("\tctx := context.Background()");
  for (const { svc } of svcs) {
    lines.push(`\t${svc.name} := gen.New${svc.name}Client(grpcdc.NewChannel(a))`);
    for (const m of svc.methods) {
      if (m.kind === "unary") {
        lines.push(`\tresp${m.name}, err := ${svc.name}.${m.name}(ctx, &gen.${m.input}{})`);
        lines.push("\tmust(err)");
        lines.push(`\tfmt.Printf("${svc.name}.${m.name} -> %v\\n", resp${m.name})`);
      } else if (m.kind === "server-streaming" || m.kind === "bidi") {
        const call = m.kind === "server-streaming"
          ? `${svc.name}.${m.name}(ctx, &gen.${m.input}{})`
          : `${svc.name}.${m.name}(ctx, &gen.${m.input}{})`;
        lines.push(`\tstream${m.name}, err := ${call}`);
        lines.push("\tmust(err)");
        lines.push(`\tn${m.name} := 0`);
        lines.push("\tfor {");
        lines.push(`\t\tif _, err := stream${m.name}.Recv(); err != nil {`);
        lines.push("\t\t\tif err == io.EOF {");
        lines.push("\t\t\t\tbreak");
        lines.push("\t\t\t}");
        lines.push("\t\t\tmust(err)");
        lines.push("\t\t}");
        lines.push(`\t\tn${m.name}++`);
        lines.push("\t}");
        lines.push(`\tfmt.Printf("${svc.name}.${m.name} -> %d response(s)\\n", n${m.name})`);
      } else {
        lines.push(`\tresp${m.name}, err := ${svc.name}.${m.name}(ctx, &gen.${m.input}{})`);
        lines.push("\tmust(err)");
        lines.push(`\tfmt.Printf("${svc.name}.${m.name} -> %v\\n", resp${m.name})`);
      }
    }
  }
  lines.push("}");
  return lines.join("\n") + "\n";
}

function pyMain(models) {
  const svcs = servicesOf(models);
  const lines = [];
  lines.push('"""Starter: generated server + client for your schema over');
  lines.push("an in-memory loopback transport. Replace the default");
  lines.push('responses in the impl classes with real logic."""');
  lines.push("");
  lines.push("import os");
  lines.push("import sys");
  lines.push("");
  lines.push('sys.path.insert(0, os.path.join(os.path.dirname(__file__), "gen"))');
  lines.push("");
  lines.push("# The kit ships the Python runtime flat in runtime/python/;");
  lines.push("# register it under its package name `grpcdc`.");
  lines.push("import importlib.util");
  lines.push('_rt = os.path.join(os.path.dirname(__file__), "..", "..", "runtime", "python")');
  lines.push('_spec = importlib.util.spec_from_file_location(');
  lines.push('    "grpcdc", os.path.join(_rt, "__init__.py"),');
  lines.push("    submodule_search_locations=[_rt])");
  lines.push("grpcdc = importlib.util.module_from_spec(_spec)");
  lines.push('sys.modules["grpcdc"] = grpcdc');
  lines.push("_spec.loader.exec_module(grpcdc)");
  const seen = new Set();
  for (const { file } of svcs) {
    const b = baseOf(file.name);
    if (seen.has(b)) continue;
    seen.add(b);
    lines.push(`import ${b}_grpc_dc`);
    lines.push(`import ${b}_pb`);
  }
  lines.push("");
  for (const { file, svc } of svcs) {
    const b = baseOf(file.name);
    lines.push(`class ${svc.name}Impl:`);
    for (const m of svc.methods) {
      if (m.kind === "unary") {
        lines.push(`    def ${m.name}(self, ctx, req):`);
        lines.push(`        return ${b}_pb.${m.output}()`);
      } else if (m.kind === "server-streaming") {
        lines.push(`    def ${m.name}(self, req, stream):`);
        lines.push(`        stream.send(${b}_pb.${m.output}())`);
      } else if (m.kind === "client-streaming") {
        lines.push(`    def ${m.name}(self, stream):`);
        lines.push("        while True:");
        lines.push("            try:");
        lines.push("                stream.recv()");
        lines.push("            except EOFError:");
        lines.push("                break");
        lines.push(`        stream.send_and_close(${b}_pb.${m.output}())`);
      } else {
        lines.push(`    def ${m.name}(self, stream):`);
        lines.push("        while True:");
        lines.push("            try:");
        lines.push("                stream.recv()");
        lines.push("            except EOFError:");
        lines.push("                return");
        lines.push(`            stream.send(${b}_pb.${m.output}())`);
      }
    }
    lines.push("");
  }
  lines.push("def main():");
  lines.push("    a, b = grpcdc.memory_transport_pair()");
  lines.push("    server = grpcdc.Server()");
  for (const { file, svc } of svcs) {
    const b = baseOf(file.name);
    lines.push(`    ${b}_grpc_dc.register_${snake(svc.name)}_server(server, ${svc.name}Impl())`);
  }
  lines.push("    server.serve_transport(b)");
  lines.push("    channel = grpcdc.Channel(a)");
  for (const { file, svc } of svcs) {
    const b = baseOf(file.name);
    lines.push(`    ${svc.name} = ${b}_grpc_dc.${svc.name}Client(channel)`);
    for (const m of svc.methods) {
      const req = `${b}_pb.${m.input}()`;
      if (m.kind === "unary") {
        lines.push(`    print("${svc.name}.${m.name} ->", ${svc.name}.${m.name}(${req}))`);
      } else if (m.kind === "server-streaming") {
        lines.push(`    print("${svc.name}.${m.name} ->", len(list(${svc.name}.${m.name}(${req}))), "response(s)")`);
      } else if (m.kind === "client-streaming") {
        lines.push(`    print("${svc.name}.${m.name} ->", ${svc.name}.${m.name}([${req}]))`);
      } else {
        lines.push(`    print("${svc.name}.${m.name} ->", len(list(${svc.name}.${m.name}([${req}]))), "response(s)")`);
      }
    }
  }
  lines.push("");
  lines.push('if __name__ == "__main__":');
  lines.push("    main()");
  return lines.join("\n") + "\n";
}

// models: describeFiles output. generatedGo/Python: [{name, content}]
// generated files to vendor into the go/python project dirs.
export function starterProjectFiles(models, generatedGo, generatedPython) {
  const out = [];
  const text = (path, content) => out.push({ name: path, data: new TextEncoder().encode(content) });
  const svcs = servicesOf(models);
  if (!svcs.length) return out;

  // web + node (JS)
  text("projects/web/main.js", jsMain(models, true));
  text("projects/web/index.html", [
    "<!doctype html>",
    '<meta charset="utf-8">',
    "<title>grpc-dc starter</title>",
    "<h1>grpc-dc starter</h1>",
    "<p>Your generated server and client, talking over an in-memory",
    "loopback DataChannel pair. Swap the loopback for a real",
    "<code>RTCDataChannel</code> to go over the wire.</p>",
    '<pre id="out"></pre>',
    '<script type="module" src="main.js"></script>',
    "",
  ].join("\n"));
  text("projects/node/main.mjs", jsMain(models, false));
  text("projects/node/package.json", JSON.stringify({ type: "module", private: true }, null, 2) + "\n");

  // python
  for (const f of generatedPython || []) {
    out.push({ name: "projects/python/gen/" + f.name, data: typeof f.content === "string" ? new TextEncoder().encode(f.content) : f.content });
  }
  text("projects/python/main.py", pyMain(models));

  // go (single-package check for vendored gen/)
  const goFiles = generatedGo || [];
  const pkgs = new Set(goFiles.map((f) => {
    const m = /^package\s+(\w+)/m.exec(typeof f.content === "string" ? f.content : new TextDecoder().decode(f.content));
    return m ? m[1] : "";
  }));
  if (goFiles.length && pkgs.size === 1 && !pkgs.has("")) {
    for (const f of goFiles) {
      out.push({ name: "projects/go/gen/" + f.name, data: typeof f.content === "string" ? new TextEncoder().encode(f.content) : f.content });
    }
    text("projects/go/go.mod", [
      "module grpcstarter",
      "",
      "go 1.24",
      "",
      "require github.com/browser-grpc/grpc-over-datachannels/go v0.33.0",
      "",
    ].join("\n"));
    text("projects/go/main.go", goMain(models));
  }

  text("projects/README.md", [
    "# Starter projects",
    "",
    "Runnable examples for your schema, generated next to the",
    "stubs (`gen/`) and runtimes (`runtime/`) in this kit. Each",
    "project serves your services with default (zero-value)",
    "responses and calls every method once, over an in-memory",
    "loopback transport — swap in a real RTCDataChannel (or the",
    "stdio/TCP transports in the runtime) to go over the wire.",
    "",
    "- web:    serve this kit root statically, open projects/web/",
    "- node:   `node projects/node/main.mjs`",
    "- python: `python3 projects/python/main.py`",
    goFiles.length && pkgs.size === 1 ? "- go:     `cd projects/go && go mod tidy && go run .`" : "- go:     (skipped: generated Go files span multiple packages; see gen/go/)",
    "",
  ].join("\n"));
  return out;
}
