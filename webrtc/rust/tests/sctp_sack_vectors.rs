//! Phase 3 conformance vectors (fixtures/sctp_vectors.json,
//! sack_scenarios): all three mirrored SCTP stacks run the same
//! SACK/gap/retransmit scenarios against the generated tracker.
//! Thin interpreter only — scenarios are generated data. The
//! vector file is ours and fixed-shape; a tiny JSON value
//! scanner suffices (the crate stays dependency-free).

use dc_webrtc::sctp_sack_gen::SctpSackTracker;

#[derive(Debug, PartialEq)]
enum Value {
    Num(u64),
    Str(String),
    Arr(Vec<Value>),
    Obj(Vec<(String, Value)>),
}

struct Scanner<'a> {
    chars: std::iter::Peekable<std::str::Chars<'a>>,
}

impl<'a> Scanner<'a> {
    fn ws(&mut self) {
        while matches!(self.chars.peek(), Some(c) if c.is_whitespace()) {
            self.chars.next();
        }
    }
    fn value(&mut self) -> Value {
        self.ws();
        match self.chars.peek() {
            Some('{') => {
                self.chars.next();
                let mut fields = Vec::new();
                loop {
                    self.ws();
                    if self.chars.peek() == Some(&'}') {
                        self.chars.next();
                        return Value::Obj(fields);
                    }
                    let key = match self.value() {
                        Value::Str(s) => s,
                        _ => panic!("object key must be a string"),
                    };
                    self.ws();
                    assert_eq!(self.chars.next(), Some(':'));
                    let v = self.value();
                    fields.push((key, v));
                    self.ws();
                    if self.chars.peek() == Some(&',') {
                        self.chars.next();
                    }
                }
            }
            Some('[') => {
                self.chars.next();
                let mut items = Vec::new();
                loop {
                    self.ws();
                    if self.chars.peek() == Some(&']') {
                        self.chars.next();
                        return Value::Arr(items);
                    }
                    items.push(self.value());
                    self.ws();
                    if self.chars.peek() == Some(&',') {
                        self.chars.next();
                    }
                }
            }
            Some('"') => {
                self.chars.next();
                let mut out = String::new();
                loop {
                    match self.chars.next() {
                        Some('"') => return Value::Str(out),
                        Some(c) => out.push(c),
                        None => panic!("unterminated string"),
                    }
                }
            }
            _ => {
                let mut out = String::new();
                while matches!(self.chars.peek(), Some(c) if c.is_ascii_digit()) {
                    out.push(self.chars.next().unwrap());
                }
                Value::Num(out.parse().expect("number"))
            }
        }
    }
}

fn get<'a>(v: &'a Value, key: &str) -> &'a Value {
    match v {
        Value::Obj(fields) => fields
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v)
            .unwrap_or_else(|| panic!("missing key {key}")),
        _ => panic!("not an object"),
    }
}

fn nums(v: &Value) -> Vec<u32> {
    match v {
        Value::Arr(items) => items
            .iter()
            .map(|i| match i {
                Value::Num(n) => *n as u32,
                _ => panic!("not a number"),
            })
            .collect(),
        _ => panic!("not an array"),
    }
}

fn blocks(v: &Value) -> Vec<(u16, u16)> {
    match v {
        Value::Arr(items) => items
            .iter()
            .map(|i| {
                let pair = nums(i);
                (pair[0] as u16, pair[1] as u16)
            })
            .collect(),
        _ => panic!("not an array"),
    }
}

#[test]
fn sctp_sack_vectors() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../fixtures/sctp_vectors.json"
    );
    let text = std::fs::read_to_string(path).expect("read vectors");
    let root = Scanner {
        chars: text.chars().peekable(),
    }
    .value();
    let scenarios = match get(&root, "sack_scenarios") {
        Value::Arr(items) => items,
        _ => panic!("sack_scenarios not an array"),
    };
    assert!(!scenarios.is_empty(), "no sack scenarios");
    for sc in scenarios {
        let name = match get(sc, "name") {
            Value::Str(s) => s.clone(),
            _ => panic!("name"),
        };
        let initial_cum = match get(sc, "initial_cum") {
            Value::Num(n) => *n as u32,
            _ => panic!("initial_cum"),
        };
        let mut tracker = SctpSackTracker::new(initial_cum);
        let steps = match get(sc, "steps") {
            Value::Arr(items) => items,
            _ => panic!("steps"),
        };
        for (i, step) in steps.iter().enumerate() {
            if let Value::Obj(fields) = step {
                if fields.iter().any(|(k, _)| k == "recv") {
                    let tsn = match get(step, "recv") {
                        Value::Num(n) => *n as u32,
                        _ => panic!("recv"),
                    };
                    tracker.note_received(tsn);
                    assert_eq!(
                        tracker.gap_blocks(),
                        blocks(get(step, "gaps")),
                        "{name} step {i} gap_blocks"
                    );
                }
                if fields.iter().any(|(k, _)| k == "sack") {
                    let sack = get(step, "sack");
                    let cum = match get(sack, "cum") {
                        Value::Num(n) => *n as u32,
                        _ => panic!("cum"),
                    };
                    let (acked, retransmit) = tracker.note_sack(
                        cum,
                        &blocks(get(sack, "blocks")),
                        &nums(get(sack, "unacked")),
                    );
                    assert_eq!(acked, nums(get(step, "acked")), "{name} step {i} acked");
                    assert_eq!(
                        retransmit,
                        nums(get(step, "retransmit")),
                        "{name} step {i} retransmit"
                    );
                }
            }
        }
    }
}
