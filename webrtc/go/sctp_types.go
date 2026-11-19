package dcwebrtc

// Shared SCTP-adjacent types: the seam's options/events/
// stats (endpoint.go) and the CRC32C checksum. The SCTP
// implementation itself is the Rust core
// (crates/dc-sctp-ffi) behind sctpAssoc; see assoc_ffi.go.

// AssociationStats holds counters for one association,
// exposed for packet-loss instrumentation. Retransmits
// increments on every retransmitted DATA chunk (fast
// retransmit and timeout alike), FastRetransmits only on
// gap-triggered fast retransmit, DupChunks on every DATA
// chunk whose TSN had already been seen.
type AssociationStats struct {
	PacketsSent     int64
	PacketsReceived int64
	ChunksSent      int64
	ChunksReceived  int64
	Retransmits     int64
	FastRetransmits int64
	DupChunks       int64
}

// SendOptions controls reliability of one message (PR-SCTP).
type SendOptions struct {
	Unordered      bool
	MaxRetransmits *uint32
	MaxLifetimeMs  *int64
}

// SctpEvent is emitted by the association (connected, data, closed).
type SctpEvent struct {
	Type    string
	Stream  uint16
	Ppid    uint32
	Payload []byte
}

// SctpPort is the default SCTP port in the SDP profile.
const SctpPort = 5000

// Crc32c computes the SCTP checksum (Castagnoli, reflected).
func Crc32c(buf []byte) uint32 {
	return crc32cState(0xffffffff, buf) ^ 0xffffffff
}

func crc32cState(crc uint32, buf []byte) uint32 {
	for _, b := range buf {
		crc = Crc32cTable[(crc^uint32(b))&0xff] ^ (crc >> 8)
	}
	return crc
}
