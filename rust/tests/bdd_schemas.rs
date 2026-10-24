//! BDD schema scenarios: golden protoc bytes, generated classes.
//! The case table (tests/bdd_schemas/mod.rs) is generated from
//! the schema scenarios: protoc's own --encode output over
//! webapp/testdata/{kitchen,features}.proto. Each case decodes
//! with the generated classes and re-encodes byte-identically.
//! The generated-classes harness mirrors pb_messages.rs.

use std::path::PathBuf;
use std::process::Command;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf()
}

fn run(cmd: &mut Command) {
    let status = cmd.status().expect("spawn command");
    assert!(status.success(), "command failed: {:?}", cmd);
}

fn hex_decode(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

const HARNESS: &str = r#"
mod common_pb;
mod features_pb;
mod kitchen_pb;
mod stamped;

use stamped::BDD_SCHEMAS;

fn fail(msg: &str) -> ! {
    eprintln!("FAIL: {msg}");
    std::process::exit(1);
}

fn hex_decode(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn main() {
    for c in BDD_SCHEMAS {
        let input = hex_decode(c.input);
        let got = match c.message {
            "kitchen" => kitchen_pb::Kitchen::decode(&input)
                .unwrap_or_else(|_| fail("kitchen decode"))
                .encode(),
            "outer" => features_pb::Outer::decode(&input)
                .unwrap_or_else(|_| fail("outer decode"))
                .encode(),
            other => fail(&format!("unknown message {other}")),
        };
        if hex_encode(&got) != c.expect {
            fail(&format!("{}: re-encode mismatch", c.name));
        }
    }
    println!("schemas OK");
}
"#;

#[test]
fn bdd_schemas_protoc_golden_bytes() {
    if Command::new("protoc").arg("--version").output().is_err() {
        eprintln!("protoc unavailable; skipping schema scenarios");
        return;
    }
    let root = root();
    let tmp = std::env::temp_dir().join(format!("grpcdc-rust-schemas-{}", std::process::id()));
    let gen = tmp.join("gen");
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&gen).unwrap();
    run(Command::new("protoc")
        .arg(format!(
            "--plugin=protoc-gen-grpc-dc-rust={}/bin/protoc-gen-grpc-dc-rust",
            root.display()
        ))
        .arg(format!("--grpc-dc-rust_out={}", gen.display()))
        .arg("-I")
        .arg(root.join("webapp/testdata"))
        .args(["common.proto", "kitchen.proto", "features.proto"]));
    for stub in ["common_grpc_dc.rs", "kitchen_grpc_dc.rs", "features_grpc_dc.rs"] {
        let _ = std::fs::remove_file(gen.join(stub));
    }
    // The stamped table lives at rust/tests/bdd_schemas/mod.rs;
    // pull it into the harness by absolute path.
    let table = root.join("rust/tests/bdd_schemas/mod.rs");
    let harness = HARNESS.replace(
        "mod stamped;",
        &format!("#[path = {:?}] mod stamped;", table.display().to_string()),
    );
    std::fs::write(gen.join("main.rs"), harness).unwrap();
    let bin = gen.join("schemas_harness");
    run(Command::new("rustc")
        .arg("--edition")
        .arg("2021")
        .arg(gen.join("main.rs"))
        .arg("-o")
        .arg(&bin));
    let out = Command::new(&bin).output().unwrap();
    assert!(
        out.status.success() && String::from_utf8_lossy(&out.stdout).contains("schemas OK"),
        "harness failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    // Silence dead-code warnings for helpers used by future cases.
    let _ = hex_decode("00");
    let _ = hex_encode(&[]);
}
