package v1

import "testing"

// Codec allocation ruler for generator-reuse work
// (mechanical-sympathy goal): report with
// `go test -bench=. -benchmem -run=NONE ./eventbus/`.

func benchEvent() *Event {
	return &Event{
		Tags: []*TagValue{
			{Tag: Tag_TOPIC, StringValue: "orders"},
			{Tag: Tag_SOURCE, StringValue: "eu-west"},
			{Tag: Tag_KIND, IntValue: 42},
		},
		Payload:         make([]byte, 1024),
		Seq:             123456789,
		PublisherId:     "bench-publisher",
		TimestampUnixMs: 1795000000000,
	}
}

func BenchmarkEventMarshalDC(b *testing.B) {
	msg := benchEvent()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = msg.MarshalDC()
	}
}

func BenchmarkEventUnmarshalDC(b *testing.B) {
	wire := benchEvent().MarshalDC()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		var msg Event
		if err := msg.UnmarshalDC(wire); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkEventUnmarshalReuse decodes into one Reset message
// instance (the Go counterpart of JS decodeInto): repeated
// fields must not accumulate across iterations.
func BenchmarkEventUnmarshalReuse(b *testing.B) {
	wire := benchEvent().MarshalDC()
	var msg Event
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		msg.Reset()
		if err := msg.UnmarshalDC(wire); err != nil {
			b.Fatal(err)
		}
		if len(msg.Tags) != 3 {
			b.Fatalf("tags accumulated: %d", len(msg.Tags))
		}
	}
}
