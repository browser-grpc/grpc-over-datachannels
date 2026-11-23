#!/usr/bin/env python3
"""Struct-codec conformance corpus: every admitted language must
reproduce conformance/struct/golden.hex byte-for-byte (Go reference).

Usage: test-struct-corpus.py [lang ...]   (default: every admitted lang)
Exits nonzero on the first failing language. Run inside the CI image.
"""
import os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(ROOT, "conformance", "struct")
PROTO = os.path.join(CORPUS, "msgs.proto")
GOLDEN = open(os.path.join(CORPUS, "golden.hex")).read().strip()

ADMITTED = ["go", "rust", "rust-shared", "java", "kotlin", "scala", "swift", "dart", "csharp", "c", "cpp", "zig", "js", "python", "lua", "php", "ruby", "dart-pure"]


def run(*args, **kw):
    print("+", " ".join(str(a) for a in args), flush=True)
    subprocess.run(args, check=True, **kw)


def protoc(lang, outdir, plugin_opt="struct_codec=true"):
    os.makedirs(outdir, exist_ok=True)
    run("protoc", f"--plugin=protoc-gen-grpc-dc-{lang}={ROOT}/bin/protoc-gen-grpc-dc-{lang}",
        f"--grpc-dc-{lang}_out={outdir}", f"--grpc-dc-{lang}_opt={plugin_opt}",
        "-I", CORPUS, PROTO)


_CDYLIB_DIR = None


def cdylib_dir():
    """Build the Rust cdylib once; return its directory."""
    global _CDYLIB_DIR
    if _CDYLIB_DIR is None:
        run("cargo", "build", "--release", "--quiet",
            cwd=os.path.join(ROOT, "rust"))
        _CDYLIB_DIR = os.path.join(ROOT, "rust", "target", "release")
    return _CDYLIB_DIR



_JNI_LIB = None


def jni_lib():
    """Build the JVM struct-codec JNI shim once; return its path."""
    global _JNI_LIB
    if _JNI_LIB is None:
        javac = shutil.which("javac")
        java_home = os.path.dirname(os.path.dirname(os.path.realpath(javac)))
        outdir = os.path.join(ROOT, "rust", "target", "jni")
        os.makedirs(outdir, exist_ok=True)
        out = os.path.join(outdir, "libgrpcdc_structdc_jni.so")
        run("cc", "-shared", "-fPIC",
            "-I", os.path.join(java_home, "include"),
            "-I", os.path.join(java_home, "include", "linux"),
            os.path.join(ROOT, "java", "jni", "structdc_jni.c"),
            "-ldl", "-o", out)
        _JNI_LIB = out
    return _JNI_LIB


def jvm_env():
    lib = cdylib_dir()
    return {**os.environ,
            "GRPC_DC_STRUCTDC_JNI": jni_lib(),
            "GRPCDC_STRUCTDC_LIB": os.path.join(lib, "libgrpc_dc.so")}


def check_go(tmp):
    d = os.path.join(tmp, "go"); os.makedirs(d)
    protoc("go", d)
    shutil.copy(os.path.join(CORPUS, "drivers", "go", "corpus_test.go"), d)
    with open(os.path.join(d, "go.mod"), "w") as f:
        f.write("module codec-corpus-go\n\ngo 1.24\n")
    lib = cdylib_dir()
    run("go", "test", "-run", "TestStructCorpus", "-count=1", "-v", ".",
        cwd=d, env={**os.environ, "STRUCT_GOLDEN_HEX": GOLDEN,
                    "GRPCDC_STRUCTDC_LIB": os.path.join(lib, "libgrpc_dc.so")})


def check_rust(tmp):
    d = os.path.join(tmp, "rust/src"); os.makedirs(d)
    gen = os.path.join(tmp, "rust-gen"); protoc("rust", gen)
    shutil.copy(os.path.join(CORPUS, "drivers", "rust", "Cargo.toml"), os.path.join(tmp, "rust"))
    shutil.copy(os.path.join(CORPUS, "drivers", "rust", "main.rs"), d)
    shutil.copy(os.path.join(gen, "msgs_pb.rs"), d)
    run("cargo", "run", "--quiet", "--release", "--manifest-path",
        os.path.join(tmp, "rust", "Cargo.toml"), "--", GOLDEN)


def check_java(tmp):
    d = os.path.join(tmp, "java"); protoc("java", d)
    shutil.copy(os.path.join(CORPUS, "drivers", "java", "StructDriver.java"), d)
    classes = os.path.join(tmp, "classes"); os.makedirs(classes)
    files = []
    for dirpath, _dirs, names in os.walk(d):
        for n in names:
            if n.endswith(".java") and "GrpcDc" not in n:
                files.append(os.path.join(dirpath, n))
    run("javac", "-encoding", "UTF-8", "-d", classes,
        "-sourcepath", os.path.join(ROOT, "java"), *files)
    run("java", "-cp", classes, "StructDriver", GOLDEN, cwd=d, env=jvm_env())


def check_kotlin(tmp):
    d = os.path.join(tmp, "kotlin"); protoc("kotlin", d)
    shutil.copy(os.path.join(CORPUS, "drivers", "kotlin", "Main.kt"), d)
    srcs = [os.path.join(ROOT, "kotlin", "grpcdc")]
    files = []
    for dirpath, _dirs, names in os.walk(d):
        for n in names:
            if n.endswith(".kt") and "GrpcDc" not in n:
                files.append(os.path.join(dirpath, n))
    jar = os.path.join(tmp, "kotlin.jar")
    run("kotlinc", "-include-runtime", *srcs, *files, "-d", jar)
    run("java", "-jar", jar, GOLDEN, env=jvm_env())


def check_scala(tmp):
    d = os.path.join(tmp, "scala"); protoc("scala", d)
    shutil.copy(os.path.join(CORPUS, "drivers", "scala", "Main.scala"), d)
    files = []
    for dirpath, _dirs, names in os.walk(d):
        for n in names:
            if n.endswith(".scala") and "GrpcDc" not in n:
                files.append(os.path.join(dirpath, n))
    jar = os.path.join(tmp, "scala.jar")
    import glob as _g
    run("scalac", "-d", jar, *sorted(_g.glob(os.path.join(ROOT, "scala", "grpcdc", "*.scala"))), *files)
    run("scala", "-cp", jar, "shapes.StructDriver", GOLDEN, env=jvm_env())


def check_swift(tmp):
    import glob as _g
    d = os.path.join(tmp, "swift"); protoc("swift", d)
    shutil.copy(os.path.join(CORPUS, "drivers", "swift", "main.swift"), d)
    files = []
    for dirpath, _dirs, names in os.walk(d):
        for n in names:
            if n.endswith(".swift") and "GrpcDc" not in n:
                files.append(os.path.join(dirpath, n))
    out = os.path.join(tmp, "swiftdriver")
    lib = cdylib_dir()
    run("swiftc", "-swift-version", "5", "-L", lib, "-lgrpc_dc",
        "-Xlinker", "-rpath", "-Xlinker", lib,
        *sorted(_g.glob(os.path.join(ROOT, "swift", "grpcdc", "*.swift"))),
        *files, "-o", out)
    run(out, GOLDEN)


def check_dart_pure(tmp):
    # The Wasm (no-FFI) Dart engine: stub companions over
    # grpcdc/structdc.dart, byte-identical to the Go golden.
    gen = os.path.join(tmp, "gen"); protoc("dart", gen)
    app = os.path.join(tmp, "app"); os.makedirs(app)
    for n in os.listdir(gen):
        if n.endswith(".dart") and "grpc_dc" not in n:
            shutil.copy(os.path.join(gen, n), app)
    shutil.copy(os.path.join(CORPUS, "drivers", "dart-pure", "main.dart"), app)
    os.symlink(os.path.join(ROOT, "dart", "grpcdc"), os.path.join(tmp, "grpcdc"))
    run("dart", os.path.join(app, "main.dart"), GOLDEN)


def check_dart(tmp):
    gen = os.path.join(tmp, "gen"); protoc("dart", gen)
    app = os.path.join(tmp, "app"); os.makedirs(app)
    for n in os.listdir(gen):
        if n.endswith(".dart") and "grpc_dc" not in n:
            shutil.copy(os.path.join(gen, n), app)
    shutil.copy(os.path.join(CORPUS, "drivers", "dart", "main.dart"), app)
    os.symlink(os.path.join(ROOT, "dart", "grpcdc"), os.path.join(tmp, "grpcdc"))
    out = os.path.join(tmp, "dartdriver")
    run("dart", "compile", "exe", os.path.join(app, "main.dart"), "-o", out)
    lib = cdylib_dir()
    run(out, GOLDEN, env={**os.environ,
                          "GRPCDC_STRUCTDC_LIB": os.path.join(lib, "libgrpc_dc.so")})


def check_python(tmp):
    gen = os.path.join(tmp, "gen"); protoc("python", gen)
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join([gen, os.path.join(ROOT, "python")])
    run("python3", os.path.join(CORPUS, "drivers", "python", "main.py"), GOLDEN,
        env=env, cwd=gen)


def check_lua(tmp):
    gen = os.path.join(tmp, "gen"); protoc("lua", gen)
    env = dict(os.environ)
    env["LUA_PATH"] = ";".join([os.path.join(gen, "?.lua"),
                                os.path.join(ROOT, "lua", "?.lua"), ";"])
    run(os.environ.get("LUA", "lua"), os.path.join(CORPUS, "drivers", "lua", "main.lua"), GOLDEN, env=env)


def check_php(tmp):
    gen = os.path.join(tmp, "gen"); protoc("php", gen)
    shutil.copy(os.path.join(ROOT, "php", "grpcdc.php"), tmp)
    os.makedirs(os.path.join(tmp, "grpcdc"))
    for n in os.listdir(os.path.join(ROOT, "php", "grpcdc")):
        if n.endswith(".php"):
            shutil.copy(os.path.join(ROOT, "php", "grpcdc", n), os.path.join(tmp, "grpcdc"))
    shutil.copy(os.path.join(CORPUS, "drivers", "php", "main.php"), gen)
    run("php", os.path.join(gen, "main.php"), GOLDEN)


def check_ruby(tmp):
    gen = os.path.join(tmp, "gen"); protoc("ruby", gen)
    env = dict(os.environ)
    env["RUBYLIB"] = os.pathsep.join([gen, os.path.join(ROOT, "ruby")])
    run(os.environ.get("RUBY", "ruby"), os.path.join(CORPUS, "drivers", "ruby", "main.rb"),
        GOLDEN, env=env)


def check_js(tmp):
    gen = os.path.join(tmp, "gen"); protoc("js", gen)
    src = os.path.join(tmp, "src"); os.makedirs(src)
    for n in ["structdc.js", "dynamic.js", "codec.js"]:
        shutil.copy(os.path.join(ROOT, "js", "src", n), src)
    shutil.copy(os.path.join(ROOT, "js", "wire_gen.js"), tmp)
    shutil.copy(os.path.join(CORPUS, "drivers", "js", "main.mjs"), gen)
    run("node", os.path.join(gen, "main.mjs"), GOLDEN)


def check_csharp(tmp):
    d = os.path.join(tmp, "csharp"); protoc("csharp", d)
    shutil.copy(os.path.join(CORPUS, "drivers", "csharp", "Program.cs"), d)
    with open(os.path.join(d, "corpus.csproj"), "w") as f:
        f.write("""<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>disable</Nullable>
    <ImplicitUsings>disable</ImplicitUsings>
    <AssemblyName>StructCorpus</AssemblyName>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="%s" />
  </ItemGroup>
</Project>
""" % os.path.join(ROOT, "csharp", "grpcdc", "Grpcdc.csproj"))
    lib = cdylib_dir()
    env = {**os.environ, "LD_LIBRARY_PATH": lib, "DOTNET_SKIP_FIRST_TIME_EXPERIENCE": "1",
           "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
           "HOME": os.path.join(tmp, "dothome"),
           "DOTNET_CLI_HOME": os.path.join(tmp, "dothome"),
           "TMPDIR": os.path.join(tmp, "dotnetmp"),
           "NUGET_PACKAGES": os.path.join(tmp, "nugetpkgs")}
    os.makedirs(os.path.join(tmp, "dotnetmp"), exist_ok=True)
    os.makedirs(os.path.join(tmp, "dothome"), exist_ok=True)
    run("dotnet", "run", "--project", os.path.join(d, "corpus.csproj"), "--", GOLDEN,
        env=env)


def check_c(tmp):
    d = os.path.join(tmp, "c"); protoc("c", d)
    shutil.copy(os.path.join(CORPUS, "drivers", "c", "main.c"), d)
    lib = cdylib_dir()
    out = os.path.join(tmp, "cdriver")
    run("cc", "-std=c99", "-Wall", "-Wno-unused-function", "-I", d,
        os.path.join(d, "main.c"), "-L", lib, "-lgrpc_dc",
        "-Wl,-rpath," + lib, "-o", out)
    run(out, GOLDEN)


def check_cpp(tmp):
    d = os.path.join(tmp, "cpp"); protoc("cpp", d)
    shutil.copy(os.path.join(CORPUS, "drivers", "cpp", "main.cpp"), d)
    out = os.path.join(tmp, "cppdriver")
    lib = cdylib_dir()
    run("c++", "-std=c++17", "-pthread", "-I", os.path.join(ROOT, "cpp"), "-I", d,
        os.path.join(d, "main.cpp"), "-L", lib, "-lgrpc_dc",
        "-Wl,-rpath," + lib, "-o", out)
    run(out, GOLDEN)


def check_zig(tmp):
    d = os.path.join(tmp, "zig"); protoc("zig", d)
    shutil.copy(os.path.join(CORPUS, "drivers", "zig", "main.zig"), d)
    out = os.path.join(tmp, "zigdriver")
    lib = cdylib_dir()
    run("zig", "build-exe", os.path.join(d, "main.zig"),
        "-O", "ReleaseSafe", "-lc", "-lgrpc_dc", "-L", lib, "-femit-bin=" + out,
        env={**os.environ, "LD_LIBRARY_PATH": lib})
    run(out, GOLDEN)


def check_rust_shared(tmp):
    # The shared descriptor-driven codec in the Rust runtime
    # (grpc_dc::structdc) against the same golden, via its cargo
    # test (models built by hand in rust/tests/structdc_corpus.rs).
    run("cargo", "test", "--test", "structdc_corpus", "--quiet",
        cwd=os.path.join(ROOT, "rust"))


CHECKS = {"go": check_go, "rust": check_rust, "rust-shared": check_rust_shared, "java": check_java,
          "kotlin": check_kotlin, "scala": check_scala, "swift": check_swift,
          "dart": check_dart, "csharp": check_csharp, "c": check_c, "js": check_js, "python": check_python,
          "cpp": check_cpp, "zig": check_zig, "lua": check_lua, "php": check_php, "ruby": check_ruby, "dart-pure": check_dart_pure}


def main():
    langs = sys.argv[1:] or ADMITTED
    for lang in langs:
        if lang not in CHECKS:
            print(f"FAIL struct corpus: {lang!r} not admitted "
                  f"(admitted: {', '.join(ADMITTED)})")
            return 1
        with tempfile.TemporaryDirectory(prefix=f"struct-corpus-{lang}-") as tmp:
            try:
                CHECKS[lang](tmp)
            except subprocess.CalledProcessError as e:
                print(f"FAIL struct corpus {lang}: exit {e.returncode}")
                return 1
        print(f"PASS struct corpus {lang}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
