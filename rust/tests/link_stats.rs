//! LinkStats: one snapshot shape over the wrapper legs.

use grpc_dc::link_stats::{H2Stats, LinkStats, SctpStats, TcpStats};

#[test]
fn link_stats_aggregates_legs() {
    let stats = LinkStats::new()
        .with_sctp(SctpStats { retransmits: 3, ..Default::default() })
        .with_tcp(TcpStats { tcp_retransmits: 4, ..Default::default() })
        .with_http2(H2Stats { frames_sent: 10, frames_received: 9, streams_opened: 2 });
    assert_eq!(stats.retransmits(), 7);
    assert_eq!(stats.http2.unwrap().streams_opened, 2);
    assert_eq!(LinkStats::new().retransmits(), 0);
}
