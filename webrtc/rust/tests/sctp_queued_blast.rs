//! Bidirectional large-message blast over a queued,
//! tail-drop link (packets wait in a 64-deep queue each
//! direction, delivered in batches as virtual time
//! advances) — the shape of a peer demux queue feeding an
//! endpoint pump. Regression test for the burst-loss
//! recovery churn seen at MiB message rates: every
//! message must still arrive exactly once.
use dc_webrtc::sctp::{Association, Event, SendOptions};
use std::collections::VecDeque;

struct Link {
    client: Association,
    server: Association,
    now: u64,
    to_server: VecDeque<Vec<u8>>,
    to_client: VecDeque<Vec<u8>>,
    delivered_client: usize,
    delivered_server: usize,
    dropped: usize,
}

impl Link {
    fn new() -> Self {
        Self {
            client: Association::new_client(5000, 5000),
            server: Association::new_server(5000, 5000),
            now: 0,
            to_server: VecDeque::new(),
            to_client: VecDeque::new(),
            delivered_client: 0,
            delivered_server: 0,
            dropped: 0,
        }
    }

    fn enqueue(queue: &mut VecDeque<Vec<u8>>, packets: Vec<Vec<u8>>, dropped: &mut usize) {
        for p in packets {
            if queue.len() >= 64 {
                *dropped += 1;
                continue;
            }
            queue.push_back(p);
        }
    }

    /// Advance time 1ms: deliver up to 8 queued packets
    /// each way, then tick both associations.
    fn step(&mut self) {
        self.now += 1;
        for _ in 0..8 {
            let Some(p) = self.to_server.pop_front() else { break };
            let (replies, events) = self.server.handle_packet(&p, self.now);
            self.delivered_server += events
                .iter()
                .filter(|e| matches!(e, Event::Data { .. }))
                .count();
            Self::enqueue(&mut self.to_client, replies, &mut self.dropped);
        }
        for _ in 0..8 {
            let Some(p) = self.to_client.pop_front() else { break };
            let (replies, events) = self.client.handle_packet(&p, self.now);
            self.delivered_client += events
                .iter()
                .filter(|e| matches!(e, Event::Data { .. }))
                .count();
            Self::enqueue(&mut self.to_server, replies, &mut self.dropped);
        }
        let (p, events) = self.client.tick(self.now);
        self.delivered_client += events
            .iter()
            .filter(|e| matches!(e, Event::Data { .. }))
            .count();
        Self::enqueue(&mut self.to_server, p, &mut self.dropped);
        let (p, events) = self.server.tick(self.now);
        self.delivered_server += events
            .iter()
            .filter(|e| matches!(e, Event::Data { .. }))
            .count();
        Self::enqueue(&mut self.to_client, p, &mut self.dropped);
    }

    fn run_until(&mut self, done: impl Fn(&Self) -> bool, max_steps: usize) {
        for _ in 0..max_steps {
            if done(self) {
                return;
            }
            self.step();
        }
    }
}

#[test]
fn bidirectional_blast_queued_taildrop() {
    let mut link = Link::new();
    let init = link.client.connect(link.now);
    Link::enqueue(&mut link.to_server, vec![init], &mut link.dropped);
    link.run_until(
        |l| l.client.is_established() && l.server.is_established(),
        10_000,
    );
    assert!(link.client.is_established() && link.server.is_established());

    let msg = vec![7u8; 65538];
    for _ in 0..16 {
        let p = link.client.send_data(0, 63, &msg, SendOptions { unordered: true, ..Default::default() }, link.now);
        Link::enqueue(&mut link.to_server, p, &mut link.dropped);
        let p = link.server.send_data(0, 63, &msg, SendOptions { unordered: true, ..Default::default() }, link.now);
        Link::enqueue(&mut link.to_client, p, &mut link.dropped);
        link.step();
    }
    link.run_until(
        |l| l.delivered_client >= 16 && l.delivered_server >= 16,
        120_000,
    );
    assert_eq!(link.delivered_server, 16, "server deliveries (dropped {})", link.dropped);
    assert_eq!(link.delivered_client, 16, "client deliveries (dropped {})", link.dropped);
}
