//! Generated Rust message types (<base>_pb.rs) from the native
//! protoc-gen-grpc-dc-rust plugin: kitchen-sink round-trip plus a
//! protoc oracle — protoc's own --encode bytes must decode to the
//! same message and re-encode semantically identically.

use std::path::PathBuf;
use std::process::Command;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn run(cmd: &mut Command) {
    let status = cmd.status().expect("spawn command");
    assert!(status.success(), "command failed: {:?}", cmd);
}

fn capture(cmd: &mut Command) -> String {
    let out = cmd.output().expect("spawn command");
    assert!(
        out.status.success(),
        "capture failed: {:?} -> {}",
        cmd,
        String::from_utf8_lossy(&out.stdout)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

const KITCHEN_TEXT: &str = "\
d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: \"sink\"
blob: \"\\x01\\x02\\x03\" color: GREEN
nested { note: \"n\" level: 3 }
item { sku: \"abc\" quantity: 2 }
nums: [1, -2, 300] words: [\"a\", \"\", \"bc\"]
manys { note: \"m\" level: 1 }
vals: [0.5, -1.25]
counts { key: \"x\" value: 1 } counts { key: \"y\" value: -2 }
by_id { key: 7 value { note: \"z\" level: 9 } }
text: \"chosen\" big_negative: -9007199254740993 neg32: -123456
";

const HARNESS: &str = r#"
mod common_pb;
mod kitchen_pb;

use kitchen_pb::{Color, Kitchen, Nested};
use std::collections::HashMap;

fn fail(msg: &str) -> ! {
    eprintln!("FAIL: {msg}");
    std::process::exit(1);
}

fn make() -> Kitchen {
    let mut k = Kitchen::default();
    k.d = 1.5;
    k.f = 2.5;
    k.i32 = -3;
    k.i64 = -4;
    k.u32 = 5;
    k.u64 = 6;
    k.s32 = -7;
    k.s64 = -8;
    k.f32 = 9;
    k.f64 = 10;
    k.sf32 = -11;
    k.sf64 = -12;
    k.flag = true;
    k.name = "sink".to_string();
    k.blob = vec![1, 2, 3];
    k.color = Color::Green;
    let mut nested = Nested::default();
    nested.note = "n".to_string();
    nested.level = 3;
    k.nested = Some(Box::new(nested));
    let mut item = common_pb::Item::default();
    item.sku = "abc".to_string();
    item.quantity = 2;
    k.item = Some(Box::new(item));
    k.nums = vec![1, -2, 300];
    k.words = vec!["a".to_string(), String::new(), "bc".to_string()];
    let mut m = Nested::default();
    m.note = "m".to_string();
    m.level = 1;
    k.manys = vec![m];
    k.vals = vec![0.5, -1.25];
    k.counts = HashMap::from([("x".to_string(), 1), ("y".to_string(), -2)]);
    let mut z = Nested::default();
    z.note = "z".to_string();
    z.level = 9;
    k.by_id = HashMap::from([(7i64, z)]);
    k.text = "chosen".to_string();
    k.big_negative = -9007199254740993;
    k.neg32 = -123456;
    k
}

fn check_same(a: &Kitchen, b: &Kitchen) {
    if a != b {
        fail("mismatch");
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let k = make();
    if args[1] == "roundtrip" {
        let back = Kitchen::decode(&k.encode()).unwrap();
        check_same(&back, &k);
        if !Kitchen::default().encode().is_empty() {
            fail("empty");
        }
        let mut both = Kitchen::default();
        both.text = "a".to_string();
        both.code = 7;
        let both_back = Kitchen::decode(&both.encode()).unwrap();
        if !(both_back.text.is_empty() && both_back.code == 7) {
            fail("oneof encode clearing");
        }
        println!("roundtrip OK");
        return;
    }
    let bytes = std::fs::read(&args[2]).unwrap();
    let from = Kitchen::decode(&bytes).unwrap();
    check_same(&from, &k);
    let again = Kitchen::decode(&from.encode()).unwrap();
    check_same(&again, &from);
    println!("oracle OK");
}
"#;

#[test]
fn pb_messages_roundtrip_and_protoc_oracle() {
    let root = root();
    let tmp = std::env::temp_dir().join(format!("grpcdc-rust-pb-{}", std::process::id()));
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
        .args(["common.proto", "kitchen.proto"]));
    for stub in ["common_grpc_dc.rs", "kitchen_grpc_dc.rs"] {
        let _ = std::fs::remove_file(gen.join(stub));
    }
    std::fs::write(gen.join("main.rs"), HARNESS).unwrap();
    run(Command::new("rustc")
        .arg("--edition")
        .arg("2021")
        .arg(gen.join("main.rs"))
        .arg("-o")
        .arg(tmp.join("harness")));
    let out1 = capture(Command::new(tmp.join("harness")).arg("roundtrip"));
    assert!(out1.contains("roundtrip OK"), "roundtrip: {out1}");

    std::fs::write(tmp.join("kitchen.txt"), KITCHEN_TEXT).unwrap();
    let protoc_bin = tmp.join("protoc.bin");
    run(Command::new("bash")
        .arg("-c")
        .arg(format!(
            "protoc --encode=kitchen.v1.Kitchen -I {}/webapp/testdata kitchen.proto < {} > {}",
            root.display(),
            tmp.join("kitchen.txt").display(),
            protoc_bin.display()
        )));
    let out2 = capture(Command::new(tmp.join("harness")).arg("oracle").arg(&protoc_bin));
    assert!(out2.contains("oracle OK"), "oracle: {out2}");
    println!("TestPbMessages OK");
}
