use std::collections::HashMap;

#[path = "msgs_pb.rs"]
mod pb;
use pb::*;
#[path = "msgs2_pb.rs"]
mod pb2;
use pb2::P2;

fn value() -> Outer {
    let mut by_name = HashMap::new();
    by_name.insert("b".to_string(), Inner { v: "second".to_string(), n: 0, unknown_fields: Vec::new() });
    by_name.insert("a".to_string(), Inner { v: "first".to_string(), n: 9, unknown_fields: Vec::new() });
    let mut by_id = HashMap::new();
    by_id.insert(7, "seven".to_string());
    by_id.insert(2, "two".to_string());
    Outer {
        inner: Some(Box::new(Inner { v: "x".to_string(), n: -3, unknown_fields: Vec::new() })),
        hue: Hue::Red,
        nums: vec![1, -2, 300],
        by_name,
        s: "picked".to_string(),
        num: 0,
        blob: vec![1, 2, 3],
        names: vec!["n1".to_string(), "n2".to_string()],
        inners: vec![
            Inner { v: "i1".to_string(), n: 0, unknown_fields: Vec::new() },
            Inner { v: "i2".to_string(), n: 0, unknown_fields: Vec::new() },
            Inner { v: "i3".to_string(), n: 0, unknown_fields: Vec::new() },
        ],
        by_id,
        score: 3.5,
        ratio: 0.25,
        flag: true,
        stamp: 123456789,
        delta: -77,
        unknown_fields: Vec::new(),
    }
}

fn value2() -> P2 {
    P2 {
        name: "req".to_string(),
        count: 42,
        greeting: "hi".to_string(),
        enabled: false,
        ratio: 2.5,
        nums: vec![5, -6],
        ext_note: "note!".to_string(),
        unknown_fields: Vec::new(),
    }
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
        .collect()
}

fn main() {
    let golden_hex = std::env::args().nth(1).expect("hex arg");
    let golden: Vec<u8> = unhex(&golden_hex);
    let m = value();
    let got = m.marshal_struct();
    if got != golden {
        println!("MARSHAL_MISMATCH\n got {:?}\nwant {:?}", got.len(), golden.len());
        std::process::exit(1);
    }
    let back = Outer::unmarshal_struct(&golden).expect("decode");
    if back.marshal_struct() != golden {
        println!("ROUNDTRIP_MISMATCH");
        std::process::exit(1);
    }
    // Proto2 shape (msgs2.proto): decode into a zero-value P2
    // (unmarshal_struct starts from the zero value, not proto2 defaults).
    let golden2_hex = std::env::args().nth(2).expect("hex2 arg");
    let golden2: Vec<u8> = unhex(&golden2_hex);
    let m2 = value2();
    let got2 = m2.marshal_struct();
    if got2 != golden2 {
        println!("P2_MARSHAL_MISMATCH\n got {:?}\nwant {:?}", got2.len(), golden2.len());
        std::process::exit(1);
    }
    let back2 = P2::unmarshal_struct(&golden2).expect("p2 decode");
    if back2.marshal_struct() != golden2 {
        println!("P2_ROUNDTRIP_MISMATCH");
        std::process::exit(1);
    }
    println!("PASS rust");
}
