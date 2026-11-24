//! The shared descriptor-driven struct codec
//! (`grpc_dc::structdc`) must reproduce the conformance corpus
//! golden bytes (conformance/struct/golden.hex, Go reference)
//! byte-for-byte, in both directions. The descriptor models are
//! built by hand here so the check runs under plain `cargo test`.

use grpc_dc::dynamic::{
    FieldModel, FileModel, GenericMessage, GenericValue, MessageModel,
};
use grpc_dc::structdc::{decode_struct, encode_struct};
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

fn field(number: u32, name: &str, ty: i32, repeated: bool, type_name: &str) -> FieldModel {
    FieldModel {
        number,
        name: name.to_string(),
        ty,
        repeated,
        type_name: type_name.to_string(),
    }
}

fn model(full_name: &str, fields: Vec<FieldModel>, map_entry: bool) -> Arc<MessageModel> {
    let by_name = fields.iter().map(|f| (f.name.clone(), f.number)).collect::<HashMap<_, _>>();
    Arc::new(MessageModel {
        full_name: full_name.to_string(),
        fields: fields.into_iter().map(|f| (f.number, f)).collect::<BTreeMap<_, _>>(),
        by_name,
        map_entry,
    })
}

fn corpus_file() -> FileModel {
    // proto types: string=9 int32=5 message=11 enum=14 bytes=12
    // double=1 float=2 bool=8 fixed64=6 sint32=17
    let inner = model(
        "shapes.Inner",
        vec![field(1, "v", 9, false, ""), field(2, "n", 5, false, "")],
        false,
    );
    let by_name = model(
        "shapes.Outer.ByNameEntry",
        vec![
            field(1, "key", 9, false, ""),
            field(2, "value", 11, false, ".shapes.Inner"),
        ],
        true,
    );
    let by_id = model(
        "shapes.Outer.ByIdEntry",
        vec![field(1, "key", 5, false, ""), field(2, "value", 9, false, "")],
        true,
    );
    let outer = model(
        "shapes.Outer",
        vec![
            field(1, "inner", 11, false, ".shapes.Inner"),
            field(2, "hue", 14, false, ".shapes.Hue"),
            field(3, "nums", 5, true, ""),
            field(4, "by_name", 11, true, ".shapes.Outer.ByNameEntry"),
            field(5, "s", 9, false, ""),
            field(6, "num", 5, false, ""),
            field(7, "blob", 12, false, ""),
            field(8, "names", 9, true, ""),
            field(9, "inners", 11, true, ".shapes.Inner"),
            field(10, "by_id", 11, true, ".shapes.Outer.ByIdEntry"),
            field(11, "score", 1, false, ""),
            field(12, "ratio", 2, false, ""),
            field(13, "flag", 8, false, ""),
            field(14, "stamp", 6, false, ""),
            field(15, "delta", 17, false, ""),
        ],
        false,
    );
    let mut messages = HashMap::new();
    for m in [inner, by_name, by_id, outer] {
        messages.insert(format!(".{}", m.full_name), m);
    }
    FileModel { messages, services: HashMap::new() }
}

fn inner(v: &str, n: i64) -> GenericMessage {
    let mut m = GenericMessage::new();
    m.set(1, v);
    if n != 0 {
        m.set(2, n);
    }
    m
}

fn entry(key: GenericValue, value: GenericValue) -> GenericMessage {
    let mut m = GenericMessage::new();
    m.set(1, key);
    m.set(2, value);
    m
}

fn sample() -> GenericMessage {
    let mut m = GenericMessage::new();
    m.set(1, inner("x", -3));
    m.set(2, 1i64);
    for v in [1i64, -2, 300] {
        m.add(3, v);
    }
    m.add(4, entry(GenericValue::from("b"), GenericValue::from(inner("second", 0))));
    m.add(4, entry(GenericValue::from("a"), GenericValue::from(inner("first", 9))));
    m.set(5, "picked");
    m.set(7, GenericValue::Bytes(vec![1, 2, 3]));
    for v in ["n1", "n2"] {
        m.add(8, v);
    }
    for v in ["i1", "i2", "i3"] {
        m.add(9, inner(v, 0));
    }
    m.add(10, entry(GenericValue::from(7i64), GenericValue::from("seven")));
    m.add(10, entry(GenericValue::from(2i64), GenericValue::from("two")));
    m.set(11, 3.5f64);
    m.set(12, GenericValue::F32(0.25));
    m.set(13, true);
    m.set(14, GenericValue::U64(123456789));
    m.set(15, -77i64);
    m
}

fn corpus_file2() -> FileModel {
    // Proto2 shape (msgs2.proto): the extension field (100, ext_note)
    // is not a model field — its protobuf bytes ride the unknown tail.
    // Types: double=1 int32=5 bool=8 string=9.
    let p2 = model(
        "shapes.P2",
        vec![
            field(1, "name", 9, false, ""),
            field(2, "count", 5, false, ""),
            field(3, "greeting", 9, false, ""),
            field(4, "enabled", 8, false, ""),
            field(5, "ratio", 1, false, ""),
            field(6, "nums", 5, true, ""),
        ],
        false,
    );
    let mut messages = HashMap::new();
    messages.insert(format!(".{}", p2.full_name), p2);
    FileModel { messages, services: HashMap::new() }
}

fn sample2() -> GenericMessage {
    let mut m = GenericMessage::new();
    m.set(1, "req");
    m.set(2, 42i64);
    m.set(3, "hi");
    // enabled=false is non-present under proto3-style presence
    // (its proto2 default is true), so it carries no struct bit.
    m.set(4, false);
    m.set(5, 2.5f64);
    for v in [5i64, -6] {
        m.add(6, v);
    }
    // Extension field 100 ("note!") as raw protobuf chunk in the tail:
    // tag (100<<3|2)=802 -> a2 06, len 5, "note!".
    m.unknown.push(vec![0xa2, 0x06, 0x05, b'n', b'o', b't', b'e', b'!']);
    m
}

fn golden2() -> Vec<u8> {
    let hex = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../conformance/struct/golden2.hex"
    ))
    .expect("read golden2.hex");
    let hex = hex.trim();
    (0..hex.len() / 2)
        .map(|i| u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap())
        .collect()
}

fn golden() -> Vec<u8> {
    let hex = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../conformance/struct/golden.hex"
    ))
    .expect("read golden.hex");
    let hex = hex.trim();
    (0..hex.len() / 2)
        .map(|i| u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap())
        .collect()
}

#[test]
fn shared_struct_codec_matches_corpus_golden() {
    let file = corpus_file();
    let outer = file.message(".shapes.Outer").unwrap();
    let golden = golden();
    let encoded = encode_struct(&outer, &sample(), &file).unwrap();
    assert_eq!(encoded, golden, "shared Rust struct codec must match the Go golden");
    let back = decode_struct(&outer, &golden, &file).unwrap();
    let re = encode_struct(&outer, &back, &file).unwrap();
    assert_eq!(re, golden, "shared Rust struct codec roundtrip mismatch");
}

#[test]
fn shared_struct_codec_matches_corpus_golden2() {
    let file = corpus_file2();
    let p2 = file.message(".shapes.P2").unwrap();
    let golden = golden2();
    let encoded = encode_struct(&p2, &sample2(), &file).unwrap();
    assert_eq!(encoded, golden, "shared Rust struct codec (P2) must match the Go golden2");
    // Decode into a zero-value GenericMessage: decode_struct only
    // materialises fields the presence bitmap marks present, so no
    // proto2 defaults are manufactured (enabled stays absent/false).
    let back = decode_struct(&p2, &golden, &file).unwrap();
    let re = encode_struct(&p2, &back, &file).unwrap();
    assert_eq!(re, golden, "shared Rust struct codec (P2) roundtrip mismatch");
}

#[test]
fn shared_struct_codec_rejects_garbage() {
    let file = corpus_file();
    let outer = file.message(".shapes.Outer").unwrap();
    let golden = golden();
    // bad magic
    let mut bad = golden.clone();
    bad[0] = 0;
    assert!(decode_struct(&outer, &bad, &file).is_err());
    // bad fingerprint
    let mut bad = golden.clone();
    bad[8] ^= 0xFF;
    assert!(decode_struct(&outer, &bad, &file).is_err());
    // truncated
    assert!(decode_struct(&outer, &golden[..golden.len() / 2], &file).is_err());
    // empty / tiny
    assert!(decode_struct(&outer, &[], &file).is_err());
    assert!(decode_struct(&outer, b"DCS1", &file).is_err());
    // corrupted variable-area offset (by_name slot offset+count at 40)
    let mut bad = golden.clone();
    bad[40] = 0xFF;
    bad[41] = 0xFF;
    assert!(decode_struct(&outer, &bad, &file).is_err());
    // unknown message type propagates as error from encode path
    assert!(file.message(".shapes.Nope").is_err());
}
