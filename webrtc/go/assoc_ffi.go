//go:build !js

package dcwebrtc

import "github.com/browser-grpc/grpc-over-datachannels/webrtc/go/sctpffi"

// SCTP backend: the shared Rust core
// (crates/dc-sctp-ffi). The endpoint pump drives it
// through the sctpAssoc seam; events and stats are
// translated here.
type ffiAssoc struct {
	a *sctpffi.Association
}

func newSctpAssoc(isClient bool) sctpAssoc {
	if isClient {
		return &ffiAssoc{a: sctpffi.NewClient(SctpPort, SctpPort)}
	}
	return &ffiAssoc{a: sctpffi.NewServer(SctpPort, SctpPort)}
}

func ffiOpts(opts SendOptions) sctpffi.SendOptions {
	out := sctpffi.Reliable
	out.Unordered = opts.Unordered
	if opts.MaxRetransmits != nil {
		out.MaxRetransmits = int32(*opts.MaxRetransmits)
	}
	if opts.MaxLifetimeMs != nil {
		out.MaxLifetimeMs = *opts.MaxLifetimeMs
	}
	return out
}

func ffiEvents(events []sctpffi.Event) []SctpEvent {
	out := make([]SctpEvent, 0, len(events))
	for _, ev := range events {
		var typ string
		switch ev.Kind {
		case sctpffi.EventConnected:
			typ = "connected"
		case sctpffi.EventData:
			typ = "data"
		case sctpffi.EventStreamReset:
			typ = "stream-reset"
		case sctpffi.EventClosed:
			typ = "closed"
		default:
			continue
		}
		out = append(out, SctpEvent{
			Type:    typ,
			Stream:  ev.Stream,
			Ppid:    ev.Ppid,
			Payload: ev.Payload,
		})
	}
	return out
}

func (f *ffiAssoc) Connect(nowMs int64) []byte {
	packet, err := f.a.Connect(uint64(nowMs))
	if err != nil {
		return nil
	}
	return packet
}

func (f *ffiAssoc) SendData(stream uint16, ppid uint32, payload []byte, opts SendOptions, nowMs int64) [][]byte {
	packets, err := f.a.SendData(stream, ppid, payload, ffiOpts(opts), uint64(nowMs))
	if err != nil {
		return nil
	}
	return packets
}

func (f *ffiAssoc) HandlePacket(packet []byte, nowMs int64) ([][]byte, []SctpEvent) {
	packets, events, err := f.a.HandlePacket(packet, uint64(nowMs))
	if err != nil {
		return nil, nil
	}
	return packets, ffiEvents(events)
}

func (f *ffiAssoc) Tick(nowMs int64) ([][]byte, []SctpEvent) {
	packets, events, err := f.a.Tick(uint64(nowMs))
	if err != nil {
		return nil, nil
	}
	return packets, ffiEvents(events)
}

func (f *ffiAssoc) Stats() AssociationStats {
	vals, err := f.a.Stats()
	if err != nil {
		return AssociationStats{}
	}
	return AssociationStats{
		PacketsSent:     int64(vals[0]),
		PacketsReceived: int64(vals[1]),
		ChunksSent:      int64(vals[2]),
		ChunksReceived:  int64(vals[3]),
		Retransmits:     int64(vals[4]),
		FastRetransmits: int64(vals[5]),
		DupChunks:       int64(vals[6]),
	}
}

func (f *ffiAssoc) CloseStream(id uint16) [][]byte {
	packets, err := f.a.CloseStream(id)
	if err != nil {
		return nil
	}
	return packets
}

func (f *ffiAssoc) Close(nowMs int64) [][]byte {
	packets, err := f.a.Shutdown(uint64(nowMs))
	if err != nil {
		return nil
	}
	return packets
}

func (f *ffiAssoc) IsEstablished() bool {
	return f.a.Established()
}
