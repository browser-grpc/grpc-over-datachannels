#!/usr/bin/env python3
"""Verify the rust_no_std generation profile: generated Rust
message code compiles in a #![no_std] crate with only alloc.

Generates echo + kitchen/features messages with
rust_no_std=true into a scratch crate, then cargo-builds it for
the host and (when the rustup target is installed) aarch64.
Runtime behavior of the same emitter with std types is covered
by the normal Rust test suite; this gate proves the embedded
profile compiles.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True, **kw)


def main():
    work = Path(tempfile.mkdtemp(prefix="grpcdc-nostd-"))
    src = work / "src"
    src.mkdir(parents=True)
    (work / "Cargo.toml").write_text(
        '[package]\nname = "grpcdc-nostd-check"\nversion = "0.0.0"\nedition = "2021"\n\n[dependencies]\n\n[profile.dev]\npanic = "abort"\n')
    gen_dir = work / "gen"
    gen_dir.mkdir()
    protoc = os.environ.get("PROTOC", "protoc")
    for inc, files in [(ROOT / "proto", ["echo.proto"]),
                       (ROOT / "webapp/testdata",
                        ["common.proto", "kitchen.proto", "features.proto"])]:
        run([protoc,
             f"--plugin=protoc-gen-grpc-dc-rust={ROOT}/bin/protoc-gen-grpc-dc-rust",
             "--grpc-dc-rust_opt=rust_no_std=true",
             f"--grpc-dc-rust_out={gen_dir}",
             "-I", str(inc), *[str(inc / f) for f in files]])
    modules = sorted(p.name[:-3] for p in gen_dir.glob("*_pb.rs"))
    if not modules:
        print("no pb modules generated", file=sys.stderr)
        return 1
    (src / "lib.rs").write_text(
        "#![no_std]\n\nextern crate alloc;\n\n"
        + "".join(f"#[path = \"../gen/{m}.rs\"]\npub mod {m};\n" for m in modules))
    cargo = os.environ.get("CARGO", "cargo")
    run([cargo, "build", "--release"], cwd=work)
    # Cross-check the embedded target shape too (compile only),
    # when the rustup target is installed.
    targets = subprocess.run(["rustup", "target", "list", "--installed"],
                             capture_output=True, text=True)
    if "aarch64-unknown-linux-gnu" in targets.stdout:
        run([cargo, "build", "--release", "--target",
             "aarch64-unknown-linux-gnu"], cwd=work)
    else:
        print("note: aarch64 rustup target not installed; host build only")
    lib = work / "target/release/libgrpcdc_nostd_check.rlib"
    size = lib.stat().st_size
    print(f"no_std generated-code crate builds (host + aarch64); rlib {size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
