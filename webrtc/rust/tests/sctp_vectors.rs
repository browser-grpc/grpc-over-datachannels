//! Generated conformance vectors (fixtures/sctp_vectors.json):
//! all three mirrored SCTP stacks run
//! the same fragment-delivery scenarios. Thin interpreter only —
//! scenarios are generated data. The vector file is ours and
//! fixed-shape, so a scanner for its four value kinds suffices
//! (the crate stays dependency-free).

use dc_webrtc::sctp::{Association, Event, SendOptions};

struct Scenario {
    name: String,
    stream: u16,
    messages: Vec<(u8, usize)>,
    deliver: Vec<usize>,
    expect: Vec<usize>,
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
    fn expect(&mut self, want: char) {
        self.ws();
        assert_eq!(self.chars.next(), Some(want), "expected {want}");
    }
    fn string(&mut self) -> String {
        self.expect('"');
        let mut out = String::new();
        loop {
            match self.chars.next() {
                Some('"') => return out,
                Some(c) => out.push(c),
                None => panic!("unterminated string"),
            }
        }
    }
    fn number(&mut self) -> usize {
        self.ws();
        let mut out = String::new();
        while matches!(self.chars.peek(), Some(c) if c.is_ascii_digit()) {
            out.push(self.chars.next().unwrap());
        }
        out.parse().expect("number")
    }
    fn key(&mut self, want: &str) {
        assert_eq!(self.string(), want);
        self.expect(':');
    }
    fn int_array(&mut self) -> Vec<usize> {
        self.expect('[');
        let mut out = Vec::new();
        loop {
            self.ws();
            if self.chars.peek() == Some(&']') {
                self.chars.next();
                return out;
            }
            out.push(self.number());
            self.ws();
            if self.chars.peek() == Some(&',') {
                self.chars.next();
            }
        }
    }
}

fn parse_scenarios(text: &str) -> Vec<Scenario> {
    let mut sc = Scanner { chars: text.chars().peekable() };
    sc.expect('{');
    sc.key("scenarios");
    sc.expect('[');
    let mut scenarios = Vec::new();
    loop {
        sc.ws();
        if sc.chars.peek() == Some(&']') {
            sc.chars.next();
            break;
        }
        sc.expect('{');
        let (mut name, mut stream) = (String::new(), 0u16);
        let (mut messages, mut deliver, mut expect) = (Vec::new(), Vec::new(), Vec::new());
        loop {
            let k = sc.string();
            sc.expect(':');
            match k.as_str() {
                "name" => name = sc.string(),
                "stream" => stream = sc.number() as u16,
                "messages" => {
                    sc.expect('[');
                    loop {
                        sc.ws();
                        if sc.chars.peek() == Some(&']') {
                            sc.chars.next();
                            break;
                        }
                        sc.expect('{');
                        let (mut fill, mut size) = (0u8, 0usize);
                        loop {
                            let mk = sc.string();
                            sc.expect(':');
                            match mk.as_str() {
                                "fill" => fill = sc.string().as_bytes()[0],
                                "size" => size = sc.number(),
                                _ => panic!("bad message key {mk}"),
                            }
                            sc.ws();
                            if sc.chars.peek() == Some(&',') {
                                sc.chars.next();
                            } else {
                                break;
                            }
                        }
                        sc.expect('}');
                        messages.push((fill, size));
                        sc.ws();
                        if sc.chars.peek() == Some(&',') {
                            sc.chars.next();
                        }
                    }
                }
                "deliver" => deliver = sc.int_array(),
                "expect" => expect = sc.int_array(),
                _ => panic!("bad scenario key {k}"),
            }
            sc.ws();
            if sc.chars.peek() == Some(&',') {
                sc.chars.next();
            } else {
                break;
            }
        }
        sc.expect('}');
        scenarios.push(Scenario { name, stream, messages, deliver, expect });
        sc.ws();
        if sc.chars.peek() == Some(&',') {
            sc.chars.next();
        }
    }
    scenarios
}

#[test]
fn sctp_vectors() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/sctp_vectors.json");
    let text = std::fs::read_to_string(path).expect("read vectors");
    let scenarios = parse_scenarios(&text);
    assert!(!scenarios.is_empty());
    for sc in scenarios {
        let mut client = Association::new_client(5000, 5000);
        let mut server = Association::new_server(5000, 5000);
        let now = 0u64;
        let init = client.connect(now);
        let (replies, _) = server.handle_packet(&init, now);
        let (echo, _) = client.handle_packet(&replies[0], now);
        for p in echo {
            let (replies, _) = server.handle_packet(&p, now);
            for q in replies {
                client.handle_packet(&q, now);
            }
        }
        assert!(client.is_established() && server.is_established(), "{}: handshake", sc.name);
        let mut packets: Vec<Vec<u8>> = Vec::new();
        let mut want: Vec<Vec<u8>> = Vec::new();
        for (fill, size) in &sc.messages {
            let payload = vec![*fill; *size];
            packets.extend(client.send_data(sc.stream, 63, &payload, SendOptions::default(), now));
            want.push(payload);
        }
        let mut got: Vec<Vec<u8>> = Vec::new();
        for idx in &sc.deliver {
            let (_, events) = server.handle_packet(&packets[*idx], now);
            for ev in events {
                if let Event::Data { payload, .. } = ev {
                    got.push(payload);
                }
            }
        }
        let expected: Vec<Vec<u8>> = sc.expect.iter().map(|i| want[*i].clone()).collect();
        assert_eq!(got, expected, "scenario {}", sc.name);
    }
}
