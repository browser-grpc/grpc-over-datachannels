#!/usr/bin/env python3
"""Schema-shape matrix: every protoc-gen-grpc-dc-* plugin must
generate without error for degenerate schema shapes (empty file,
no package, messages only, enums only, services, proto2) AND the
generated output must compile / import / parse per language.

Generation-only checks missed real breakage (enums-only files lost
their enums in the Go/JS/Python pb companions, and Python emitted a
stub importing a pb module that was never generated), so each
plugin's output for the degenerate shapes is now also fed to the
language toolchain:

  compiled        go (go build), rust (cargo check), java (javac),
                  kotlin (kotlinc), scala (scalac), swift (swiftc
                  -typecheck), csharp (dotnet build), dart
                  (dart analyze), c/cpp/wasm-cpp (cc -fsyntax-only),
                  wasm-go (GOOS=js go build, no-service shapes)
  import-checked  python (importlib), js (node ESM import)
  syntax-only     ruby -c, php -l, lua loadfile, zig ast-check
                  (full compile of these is covered by the
                  per-language suites in `make test`)
  browser-covered wasm-kotlin, wasm-scala: Kotlin/Wasm and Scala.js
                  outputs only compile inside their browser harness
                  (test-kotlin-wasm-browser, test-scalajs-browser)

Missing toolchains are reported as compile-skip (the CI image
provisions every one); a present toolchain that rejects the output
is a failure. Message encode/decode roundtrips for arbitrary
schemas are covered by the per-language BDD suites; this gate adds
a Python roundtrip on the messages shape to prove the enum/map/
oneof codegen paths execute, not just compile.
"""
import os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SHAPES = {
    "empty": {"empty.proto": 'syntax = "proto3";\n'},
    "nopackage": {"plain.proto": 'syntax = "proto3";\nmessage Lone { string a = 1; }\n'},
    "messages": {"msgs.proto": '''syntax = "proto3";
package shapes;
enum Hue { HUE_UNSPECIFIED = 0; RED = 1; }
message Inner { string v = 1; }
message Outer {
  Inner inner = 1;
  Hue hue = 2;
  repeated int32 nums = 3 [packed = true];
  map<string, Inner> by_name = 4;
  oneof pick { string s = 5; int32 n = 6; }
  bytes blob = 7;
}
'''},
    "enums": {"enums.proto": 'syntax = "proto3";\npackage shapes;\nenum Only { ONLY_UNSPECIFIED = 0; ONE = 1; }\n'},
    "service": {"svc.proto": '''syntax = "proto3";
package shapes;
message Req { string q = 1; }
message Resp { string r = 1; }
service Echo {
  rpc Unary(Req) returns (Resp);
  rpc Client(stream Req) returns (Resp);
  rpc Server(Req) returns (stream Resp);
  rpc Bidi(stream Req) returns (stream Resp);
}
'''},
    "plainservice": {"psvc.proto": '''syntax = "proto3";
message Req { string q = 1; }
message Resp { string r = 1; }
service Echo {
  rpc Unary(Req) returns (Resp);
  rpc Bidi(stream Req) returns (stream Resp);
}
'''},
    "proto2": {"old.proto": '''syntax = "proto2";
package shapes;
message Old {
  required string name = 1;
  optional int32 count = 2 [default = 42];
  optional string greeting = 3 [default = "hi"];
  extensions 100 to 199;
}
extend Old { optional string note = 100; }
service OldSvc { rpc Get(Old) returns (Old); }
'''},
    "full": None,  # repo testdata
}

# Shapes fed to slow compilers (JVM / dotnet / swift): the
# degenerate ones this gate exists for, plus one service shape.
SLOW_SHAPES = ["empty", "enums", "service"]
FAST_SHAPES = ["empty", "nopackage", "messages", "enums", "service", "plainservice", "proto2"]


def plugins():
    out = []
    for name in sorted(os.listdir(os.path.join(ROOT, "bin"))):
        if name.startswith("protoc-gen-grpc-dc-"):
            out.append(name[len("protoc-gen-grpc-dc-"):])
    return out


def run(cmd, cwd=None, env=None, timeout=300):
    e = dict(os.environ)
    if env:
        e.update(env)
    r = subprocess.run(cmd, cwd=cwd, env=e, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


def errlines(msg, limit=3):
    lines = [l for l in msg.splitlines() if "error" in l.lower()]
    return " | ".join(lines[:limit]) if lines else msg[-300:]


def have(tool):
    return shutil.which(tool) is not None


class Checker:
    """Returns (status, detail): status in ok|fail|skip|covered."""

    def __init__(self, td):
        self.td = td
        self.n = 0

    def scratch(self, suffix, shape):
        self.n += 1
        d = os.path.join(self.td, f"cc{self.n}-{suffix}-{shape}")
        os.makedirs(d)
        return d

    # -- interpreted: import / load --------------------------------
    def python(self, suffix, shape, out, files):
        if not have("python3"):
            return ("skip", "no python3")
        py = [f for f in files if f.endswith(".py")]
        code = "import importlib,sys;" + "".join(
            f"importlib.import_module({f[:-3]!r});" for f in sorted(py))
        env = {"PYTHONPATH": out + os.pathsep + os.path.join(ROOT, "python"),
               "PYTHONDONTWRITEBYTECODE": "1"}
        rc, msg = run([sys.executable, "-c", code], env=env)
        return ("ok", "") if rc == 0 else ("fail", msg[-300:])

    def js(self, suffix, shape, out, files):
        if not have("node"):
            return ("skip", "no node")
        with open(os.path.join(out, "package.json"), "w") as f:
            f.write('{"type":"module"}\n')
        js = [f for f in files if f.endswith(".js")]
        code = "".join(f"await import('./{f}');" for f in sorted(js))
        rc, msg = run(["node", "--input-type=module", "-e", code], cwd=out)
        return ("ok", "") if rc == 0 else ("fail", msg[-300:])

    # -- compiled ---------------------------------------------------
    def go(self, suffix, shape, out, files, wasm=False):
        if not have("go"):
            return ("skip", "no go")
        d = self.scratch(suffix, shape)
        for f in files:
            if f.endswith(".go"):
                shutil.copy(os.path.join(out, f), d)
        module = "github.com/browser-grpc/grpc-over-datachannels/go"
        webrtc = "github.com/browser-grpc/grpc-over-datachannels/webrtc/go"
        with open(os.path.join(d, "go.mod"), "w") as f:
            f.write(f"module shapeprobe\n\ngo 1.24\n\nrequire {module} v0.0.0\n\n"
                    f"require {webrtc} v0.0.0\n\n"
                    f"replace {module} => {os.path.join(ROOT, 'go')}\n\n"
                    f"replace {webrtc} => {os.path.join(ROOT, 'webrtc', 'go')}\n")
        env = {"GOFLAGS": "-mod=mod", "GOPROXY": "off"}
        if wasm:
            env.update({"GOOS": "js", "GOARCH": "wasm"})
        rc, msg = run(["go", "build", "./..."], cwd=d, env=env)
        if rc != 0 and "module cache" in msg:
            return ("skip", "go module cache not warm (CI image provisions it)")
        return ("ok", "") if rc == 0 else ("fail", msg[-300:])

    def wasm_go(self, suffix, shape, out, files, shape_dir, plugins_map):
        """Compile the wasm facade the way consumers wire it: Go pb
        messages generated into a scratch module, messages_import
        pointed at them, GOOS=js build."""
        if not have("go"):
            return ("skip", "no go")
        d = self.scratch(suffix, shape)
        protos = sorted(f for f in os.listdir(shape_dir) if f.endswith(".proto"))
        shapes_dir = os.path.join(d, "shapes")
        os.makedirs(shapes_dir)
        rc, msg = run(["protoc", f"--plugin=protoc-gen-grpc-dc-go={plugins_map['go']}",
                       "--grpc-dc-go_opt=go_package=echo",
                       f"--grpc-dc-go_out={shapes_dir}", "-I", shape_dir] + protos,
                      cwd=shape_dir)
        if rc != 0:
            return ("fail", "go pb gen: " + msg[-200:])
        wasm_dir = os.path.join(d, "wasm")
        os.makedirs(wasm_dir)
        # The facade compiles beside the bridge runtime (package
        # echowasm), as in wasm/go/.
        shutil.copy(os.path.join(ROOT, "wasm", "go", "bridge.go"), wasm_dir)
        rc, msg = run(["protoc", f"--plugin=protoc-gen-grpc-dc-wasm-go={plugins_map['wasm-go']}",
                       "--grpc-dc-wasm-go_opt=messages_import=shapeprobe/shapes",
                       f"--grpc-dc-wasm-go_out={wasm_dir}", "-I", shape_dir] + protos,
                      cwd=shape_dir)
        if rc != 0:
            return ("fail", "wasm-go gen: " + msg[-200:])
        module = "github.com/browser-grpc/grpc-over-datachannels/go"
        webrtc = "github.com/browser-grpc/grpc-over-datachannels/webrtc/go"
        with open(os.path.join(d, "go.mod"), "w") as f:
            f.write(f"module shapeprobe\n\ngo 1.24\n\nrequire {module} v0.0.0\n\n"
                    f"require {webrtc} v0.0.0\n\n"
                    f"replace {module} => {os.path.join(ROOT, 'go')}\n\n"
                    f"replace {webrtc} => {os.path.join(ROOT, 'webrtc', 'go')}\n")
        env = {"GOFLAGS": "-mod=mod", "GOPROXY": "off", "GOOS": "js", "GOARCH": "wasm"}
        rc, msg = run(["go", "build", "./..."], cwd=d, env=env)
        if rc != 0 and "module cache" in msg:
            return ("skip", "go module cache not warm (CI image provisions it)")
        return ("ok", "") if rc == 0 else ("fail", errlines(msg))

    def rust(self, suffix, shape, out, files):
        if not have("cargo"):
            return ("skip", "no cargo")
        d = self.scratch(suffix, shape)
        gen = os.path.join(d, "gen")
        os.makedirs(os.path.join(d, "src"))
        os.makedirs(gen)
        mods = []
        pbs = []
        for f in files:
            if f.endswith(".rs"):
                shutil.copy(os.path.join(out, f), os.path.join(gen, f))
                base = f[:-3]
                mods.append(base)
                if f.endswith("_pb.rs"):
                    pbs.append(base)
        lib = []
        for m in mods:
            lib.append(f'#[path = "../gen/{m}.rs"] pub mod {m};')
        # Same-file types are referenced as crate::pb (consumer alias).
        if pbs:
            lib.append(f"pub use crate::{pbs[0]} as pb;")
        # Generated types get grpc_dc::Message from consumer glue
        # (rust/examples/echo_demo/pb_message_impl.rs is the repo's
        # instance); synthesize it per pb struct.
        import re as _re
        for m in pbs:
            text = open(os.path.join(gen, m + ".rs")).read()
            for t in _re.findall(r"pub struct (\w+)", text):
                lib.append(
                    f"impl grpc_dc::Message for crate::{m}::{t} {{\n"
                    f"    fn encode(&self) -> Vec<u8> {{ crate::{m}::{t}::encode(self) }}\n"
                    f"    fn decode(bytes: &[u8]) -> Result<Self, grpc_dc::Status> {{\n"
                    f"        crate::{m}::{t}::decode(bytes).map_err(grpc_dc::Status::invalid_argument) }}\n}}")
        with open(os.path.join(d, "src", "lib.rs"), "w") as f:
            f.write("\n".join(lib) + "\n")
        with open(os.path.join(d, "Cargo.toml"), "w") as f:
            f.write('[package]\nname = "shapeprobe"\nversion = "0.0.0"\nedition = "2021"\n\n'
                    f'[dependencies]\ngrpc_dc = {{ package = "grpc-dc", path = "{os.path.join(ROOT, "rust")}" }}\n')
        env = {"CARGO_TARGET_DIR": os.path.join(self.td, "cargo-target"),
               "CARGO_NET_OFFLINE": "true"}
        rc, msg = run(["cargo", "check", "--offline"], cwd=d, env=env)
        return ("ok", "") if rc == 0 else ("fail", errlines(msg))

    def javac_like(self, suffix, shape, out, files, tool, runtime_glob, extra):
        if not have(tool):
            return ("skip", f"no {tool}")
        d = self.scratch(suffix, shape)
        srcs = []
        import glob as g
        srcs += sorted(g.glob(os.path.join(ROOT, runtime_glob), recursive=True))
        srcs += [os.path.join(out, f) for f in files if f.endswith(extra)]
        if tool == "javac":
            cmd = ["javac", "-nowarn", "-d", d] + srcs
        elif tool == "kotlinc":
            cmd = ["kotlinc", "-nowarn"] + srcs + ["-d", os.path.join(d, "out.jar")]
        elif tool == "scalac":
            os.makedirs(os.path.join(d, "classes"))
            cmd = ["scalac", "-d", os.path.join(d, "classes")] + srcs
        else:  # swiftc
            cmd = ["swiftc", "-typecheck"] + srcs
        rc, msg = run(cmd, timeout=600)
        return ("ok", "") if rc == 0 else ("fail", errlines(msg))

    def csharp(self, suffix, shape, out, files):
        if not have("dotnet"):
            return ("skip", "no dotnet")
        d = self.scratch(suffix, shape)
        with open(os.path.join(d, "shapeprobe.csproj"), "w") as f:
            f.write('<Project Sdk="Microsoft.NET.Sdk">\n<PropertyGroup>\n'
                    '<TargetFramework>net8.0</TargetFramework>\n<Nullable>disable</Nullable>\n'
                    '<ImplicitUsings>enable</ImplicitUsings>\n'
                    '<EnableDefaultCompileItems>false</EnableDefaultCompileItems>\n</PropertyGroup>\n<ItemGroup>\n')
            import glob as g
            for src in sorted(g.glob(os.path.join(ROOT, "csharp", "grpcdc", "**", "*.cs"), recursive=True)):
                if f"{os.sep}obj{os.sep}" in src or f"{os.sep}bin{os.sep}" in src:
                    continue
                f.write(f'<Compile Include="{src}" />\n')
            for fn in files:
                if fn.endswith(".cs"):
                    f.write(f'<Compile Include="{os.path.join(out, fn)}" />\n')
            f.write('</ItemGroup>\n</Project>\n')
        rc, msg = run(["dotnet", "build", "--nologo", "-v", "q", d], timeout=600)
        return ("ok", "") if rc == 0 else ("fail", errlines(msg))

    def dart(self, suffix, shape, out, files):
        if not have("dart"):
            return ("skip", "no dart")
        d = self.scratch(suffix, shape)
        os.symlink(os.path.join(ROOT, "dart", "grpcdc"), os.path.join(d, "grpcdc"))
        gen = os.path.join(d, "gen")
        os.makedirs(gen)
        for f in files:
            if f.endswith(".dart"):
                shutil.copy(os.path.join(out, f), os.path.join(gen, f))
        with open(os.path.join(d, "pubspec.yaml"), "w") as f:
            f.write("name: shapeprobe\nenvironment:\n  sdk: ^3.0.0\n")
        rc, msg = run(["dart", "analyze", "gen"], cwd=d)
        errs = [l for l in msg.splitlines() if " error - " in l]
        return ("fail", " | ".join(errs[:3])) if errs else ("ok", "")

    def cc(self, suffix, shape, out, files, tool, std, incdirs, exts):
        if not have(tool):
            return ("skip", f"no {tool}")
        bad = []
        for f in files:
            if f.endswith(exts):
                rc, msg = run([tool, f"-std={std}", "-fsyntax-only"] +
                              [x for d in incdirs for x in ("-I", d)] +
                              [os.path.join(out, f)])
                if rc != 0:
                    bad.append(msg[-200:])
        return ("fail", errlines(" ".join(bad))) if bad else ("ok", "")

    def wasm_cpp(self, suffix, shape, out, files, shape_proto_dir, plugins_map):
        if not have("g++"):
            return ("skip", "no g++")
        d = self.scratch(suffix, shape)
        ex = os.path.join(d, "examples")
        os.makedirs(ex)
        # messages live in the cpp plugin's <base>_messages.hpp
        cmd = ["protoc", f"--plugin=protoc-gen-grpc-dc-cpp={plugins_map['cpp']}",
               f"--grpc-dc-cpp_out={ex}", "-I", shape_proto_dir] + \
              [f for f in os.listdir(shape_proto_dir) if f.endswith(".proto")]
        rc, msg = run(cmd, cwd=shape_proto_dir)
        if rc != 0:
            return ("fail", "cpp messages gen: " + msg[-200:])
        bad = []
        for f in files:
            if f.endswith(".hpp"):
                rc, msg = run(["g++", "-std=c++17", "-fsyntax-only",
                               "-I", os.path.join(ROOT, "wasm", "cpp"),
                               "-I", ex, "-I", d, "-I", os.path.join(ROOT, "cpp"),
                               os.path.join(out, f)])
                if rc != 0:
                    bad.append(msg[-200:])
        return ("fail", errlines(" ".join(bad))) if bad else ("ok", "")

    def syntax(self, suffix, shape, out, files, kind):
        # The repo targets Lua 5.4 (generated code uses 5.3+ bitwise
        # operators); CI sets LUA=lua5.4 for the same reason.
        tools = {"ruby": (["ruby"], ["-c"]), "php": (["php"], ["-l"]),
                 "lua": (["lua5.4", "lua"], None), "zig": (["zig"], ["ast-check"])}
        candidates, args = tools[kind]
        tool = next((t for t in candidates if have(t)), None)
        if not tool:
            return ("skip", f"no {candidates[0]}")
        ext = {"ruby": ".rb", "php": ".php", "lua": ".lua", "zig": ".zig"}[kind]
        bad = []
        for f in files:
            if not f.endswith(ext):
                continue
            p = os.path.join(out, f)
            cmd = [tool, "-e", f"assert(loadfile({p!r}))"] if kind == "lua" else [tool] + args + [p]
            rc, msg = run(cmd)
            if rc != 0:
                bad.append(msg[-200:])
        return ("fail", errlines(" ".join(bad))) if bad else ("ok", "")


def compile_check(ck, suffix, shape, out, files, shape_dir, plugins_map):
    """Dispatch per plugin suffix. Returns (status, detail)."""
    if suffix == "python":
        return ck.python(suffix, shape, out, files)
    if suffix == "js":
        return ck.js(suffix, shape, out, files)
    if suffix == "go":
        return ck.go(suffix, shape, out, files)
    if suffix == "wasm-go":
        return ck.wasm_go(suffix, shape, out, files, shape_dir, plugins_map)
    if suffix == "rust":
        return ck.rust(suffix, shape, out, files)
    if suffix == "java":
        return ck.javac_like(suffix, shape, out, files, "javac", "java/grpcdc/**/*.java", ".java")
    if suffix in ("kotlin", "kotlin-native"):
        if suffix == "kotlin-native":
            return ("covered", "Kotlin/Native compile covered by test-kotlin-wasm-native-browser")
        return ck.javac_like(suffix, shape, out, files, "kotlinc", "kotlin/grpcdc/*.kt", ".kt")
    if suffix == "scala":
        return ck.javac_like(suffix, shape, out, files, "scalac", "scala/grpcdc/*.scala", ".scala")
    if suffix == "swift":
        return ck.javac_like(suffix, shape, out, files, "swiftc", "swift/grpcdc/*.swift", ".swift")
    if suffix == "csharp":
        return ck.csharp(suffix, shape, out, files)
    if suffix == "dart":
        return ck.dart(suffix, shape, out, files)
    if suffix == "c":
        return ck.cc(suffix, shape, out, files, "gcc", "c99",
                     [ROOT, os.path.join(ROOT, "c")], (".h",))
    if suffix == "cpp":
        d = ck.scratch(suffix, shape)
        ex = os.path.join(d, "examples")
        os.makedirs(ex, exist_ok=True)
        for f in files:
            if f.endswith("_messages.hpp"):
                shutil.copy(os.path.join(out, f), os.path.join(ex, f))
        return ck.cc(suffix, shape, out, files, "g++", "c++17",
                     [d, os.path.join(ROOT, "cpp"), ROOT], (".hpp",))
    if suffix == "wasm-cpp":
        # The facade contract pairs with hand-written exception-free
        # messages (wasm/cpp/echo_messages.hpp), not the C++ plugin's
        # messages, so service shapes compile only in the browser
        # suite; no-service shapes still check the emitted struct.
        if shape in ("service", "plainservice", "proto2"):
            return ("covered", "service shapes covered by test-cpp-wasm-browser")
        return ck.wasm_cpp(suffix, shape, out, files, shape_dir, plugins_map)
    if suffix == "wasm-swift":
        # Swift against the wasm bridge declarations plus the Swift
        # plugin's messages for the same schema (the facade's types).
        if not have("swiftc"):
            return ("skip", "no swiftc")
        d = ck.scratch(suffix, shape)
        protos = sorted(f for f in os.listdir(shape_dir) if f.endswith(".proto"))
        rc, msg = run(["protoc", f"--plugin=protoc-gen-grpc-dc-swift={plugins_map['swift']}",
                       f"--grpc-dc-swift_out={d}", "-I", shape_dir] + protos,
                      cwd=shape_dir)
        if rc != 0:
            return ("fail", "swift messages gen: " + msg[-200:])
        # File set mirrors the Makefile swift-wasm build: bridge +
        # Wire + Pb support + messages + facade.
        srcs = [os.path.join(ROOT, "wasm", "swift", "bridge.swift"),
                os.path.join(ROOT, "swift", "grpcdc", "Wire.swift"),
                os.path.join(ROOT, "swift", "examples", "Pb.swift")] + \
               [os.path.join(d, f) for f in os.listdir(d) if f.endswith("Messages.swift")] + \
               [os.path.join(out, f) for f in files if f.endswith(".swift")]
        rc, msg = run(["swiftc", "-typecheck", "-enable-experimental-feature", "Extern"] + srcs, timeout=600)
        return ("ok", "") if rc == 0 else ("fail", errlines(msg))
    if suffix in ("wasm-kotlin", "wasm-scala"):
        return ("covered", "facade compile covered by its browser suite in make test")
    if suffix == "wasm-zig":
        return ck.syntax(suffix, shape, out, files, "zig")
    if suffix in ("ruby", "php", "lua", "zig"):
        return ck.syntax(suffix, shape, out, files, suffix)
    return ("covered", "no standalone checker; covered by per-language suite")


def python_roundtrip(out_root):
    """Execute the generated messages-shape code: enum/map/oneof
    must survive a marshal roundtrip (proves codegen runs)."""
    out = os.path.join(out_root, "python", "messages")
    if not os.path.isdir(out):
        return None
    code = (
        "import msgs_pb\n"
        "o = msgs_pb.Outer(inner=msgs_pb.Inner(v='x'), hue=msgs_pb.Hue.RED,"
        " nums=[1,2,3], by_name={'k': msgs_pb.Inner(v='y')}, s='pick')\n"
        "b = o.marshal_dc()\n"
        "o2 = msgs_pb.Outer()\n"
        "o2.unmarshal_dc(b)\n"
        "assert o2.hue == msgs_pb.Hue.RED and o2.inner.v == 'x'"
        " and o2.by_name['k'].v == 'y' and o2.s == 'pick' and list(o2.nums) == [1,2,3], o2\n"
        "print('python roundtrip ok')\n")
    env = {"PYTHONPATH": out + os.pathsep + os.path.join(ROOT, "python"),
           "PYTHONDONTWRITEBYTECODE": "1"}
    rc, msg = run([sys.executable, "-c", code], env=env)
    return rc == 0, msg[-300:]


def main():
    only = sys.argv[1:] or None
    failures = []
    skipped = []
    with tempfile.TemporaryDirectory() as td:
        shape_dirs = {}
        for shape, files in SHAPES.items():
            d = os.path.join(td, shape)
            os.makedirs(d)
            if files is None:
                src = os.path.join(ROOT, "webapp", "testdata")
                shape_dirs[shape] = (src, ["common.proto", "kitchen.proto", "features.proto", "legacy.proto"])
            else:
                for name, text in files.items():
                    with open(os.path.join(d, name), "w") as f:
                        f.write(text)
                shape_dirs[shape] = (d, sorted(files))
        plugs = plugins()
        plugins_map = {s: os.path.join(ROOT, "bin", f"protoc-gen-grpc-dc-{s}") for s in plugs}
        ck = Checker(td)
        for suffix in plugs:
            if only and suffix not in only:
                continue
            plugin = plugins_map[suffix]
            slow = suffix in ("java", "kotlin", "scala", "swift", "csharp")
            for shape, (inc, files) in shape_dirs.items():
                out = os.path.join(td, "out", suffix, shape)
                os.makedirs(out, exist_ok=True)
                cmd = ["protoc", f"--plugin=protoc-gen-grpc-dc-{suffix}={plugin}",
                       f"--grpc-dc-{suffix}_out={out}", "-I", inc] + files
                r = subprocess.run(cmd, cwd=inc, capture_output=True, text=True)
                if r.returncode != 0:
                    failures.append((suffix, shape, (r.stdout + r.stderr).strip()[:300]))
                    print(f"FAIL {suffix} x {shape}: {(r.stdout + r.stderr).strip()[:200]}")
                    continue
                gen_files = sorted(os.listdir(out))
                # Compile/run check the degenerate shapes.
                if shape == "full":
                    print(f"ok   {suffix} x {shape} (gen only; compile covered by suites)")
                    continue
                if slow and shape not in SLOW_SHAPES:
                    print(f"ok   {suffix} x {shape} (gen; compile on {SLOW_SHAPES})")
                    continue
                status, detail = compile_check(ck, suffix, shape, out, gen_files, inc, plugins_map)
                if status == "fail":
                    failures.append((suffix, shape, "compile: " + detail))
                    print(f"FAIL {suffix} x {shape} compile: {detail[:200]}")
                elif status == "skip":
                    skipped.append((suffix, shape, detail))
                    print(f"ok   {suffix} x {shape} (gen; compile-skip: {detail})")
                elif status == "covered":
                    print(f"ok   {suffix} x {shape} (gen; compile {detail})")
                else:
                    print(f"ok   {suffix} x {shape} (gen+compile)")
        rt = python_roundtrip(os.path.join(td, "out"))
        if rt is not None:
            ok, detail = rt
            if not ok:
                failures.append(("python", "messages-roundtrip", detail))
                print(f"FAIL python x messages roundtrip: {detail[:200]}")
            else:
                print("ok   python x messages (roundtrip)")
    print(f"\n{len(failures)} failures, {len(skipped)} compile-skips")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
