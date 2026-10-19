#!/usr/bin/env python3
"""Schema-shape matrix: every protoc-gen-grpc-dc-* plugin must
generate without error for degenerate schema shapes (empty file,
no package, messages only, enums only, services, proto2)."""
import os, subprocess, sys, tempfile

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

def plugins():
    out = []
    for name in sorted(os.listdir(os.path.join(ROOT, "bin"))):
        if name.startswith("protoc-gen-grpc-dc-"):
            out.append(name[len("protoc-gen-grpc-dc-"):])
    return out

def main():
    only = sys.argv[1:] or None
    failures = []
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
        for suffix in plugins():
            if only and suffix not in only:
                continue
            plugin = os.path.join(ROOT, "bin", f"protoc-gen-grpc-dc-{suffix}")
            for shape, (inc, files) in shape_dirs.items():
                out = os.path.join(td, "out", suffix, shape)
                os.makedirs(out, exist_ok=True)
                cmd = ["protoc", f"--plugin=protoc-gen-grpc-dc-{suffix}={plugin}",
                       f"--grpc-dc-{suffix}_out={out}", "-I", inc] + files
                r = subprocess.run(cmd, cwd=inc, capture_output=True, text=True)
                if r.returncode != 0:
                    failures.append((suffix, shape, (r.stdout + r.stderr).strip()[:300]))
                    print(f"FAIL {suffix} x {shape}: {(r.stdout + r.stderr).strip()[:200]}")
                else:
                    print(f"ok   {suffix} x {shape}")
    print(f"\n{len(failures)} failures")
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
