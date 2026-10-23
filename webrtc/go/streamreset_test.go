package dcwebrtc

import (
	"testing"
	"time"
)

// DataChannel close via SCTP stream reset (RFC 6525): the
// closing side and the remote side both observe the close, and
// a second channel on the same association keeps working.

func TestDataChannelCloseViaStreamReset(t *testing.T) {
	a, err := NewPeer(PeerOptions{LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := NewPeer(PeerOptions{LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()

	offer := a.CreateOffer()
	answer, err := b.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}
	type result struct {
		ep  *DcEndpoint
		err error
	}
	results := make(chan result, 2)
	go func() {
		ep, err := a.ConnectWithOptions(true)
		results <- result{ep, err}
	}()
	go func() {
		ep, err := b.ConnectWithOptions(true)
		results <- result{ep, err}
	}()
	var eps []*DcEndpoint
	for i := 0; i < 2; i++ {
		select {
		case r := <-results:
			if r.err != nil {
				t.Fatalf("connect: %v", r.err)
			}
			eps = append(eps, r.ep)
		case <-time.After(30 * time.Second):
			t.Fatal("connect timed out")
		}
	}
	epA, epB := eps[0], eps[1]

	remoteClosed := make(chan struct{}, 1)
	localClosed := make(chan struct{}, 1)
	messages := make(chan string, 4)
	epB.SetOnChannel(func(channel *DataChannel) {
		channel.OnMessage(func(data []byte, isText bool) { messages <- string(data) })
		channel.OnClose(func() { remoteClosed <- struct{}{} })
	})
	ch1 := epA.OpenChannel(DefaultChannelParams("one"))
	ch1.OnClose(func() { localClosed <- struct{}{} })
	ch1.Send([]byte("before-close"))
	select {
	case text := <-messages:
		if text != "before-close" {
			t.Fatalf("got %q", text)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("message before close never arrived")
	}

	ch1.Close()
	if ch1.ReadyState() != "closing" && ch1.ReadyState() != "closed" {
		t.Fatalf("ReadyState after Close = %q", ch1.ReadyState())
	}
	for name, ch := range map[string]chan struct{}{"local": localClosed, "remote": remoteClosed} {
		select {
		case <-ch:
		case <-time.After(10 * time.Second):
			t.Fatalf("%s close never fired", name)
		}
	}
	if ch1.ReadyState() != "closed" {
		t.Fatalf("ReadyState = %q, want closed", ch1.ReadyState())
	}

	// The association survives: a second channel still works.
	ch2 := epA.OpenChannel(DefaultChannelParams("two"))
	ch2.Send([]byte("after-close"))
	select {
	case text := <-messages:
		if text != "after-close" {
			t.Fatalf("got %q", text)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("second channel broken after first closed")
	}
}

// Association-level: a reset whose sender-last-assigned TSN has
// not yet been cumulatively received is deferred, then applied
// (with its response) once the gap fills.
func TestStreamResetDefersUntilCumulative(t *testing.T) {
	client := NewClientAssociation(SctpPort, SctpPort)
	server := NewServerAssociation(SctpPort, SctpPort)
	exchange := func(to *Association, packets [][]byte, now int64) ([][]byte, []SctpEvent) {
		var out [][]byte
		var events []SctpEvent
		for _, p := range packets {
			p2, e2 := to.HandlePacket(p, now)
			out = append(out, p2...)
			events = append(events, e2...)
		}
		return out, events
	}
	var now int64
	init := client.Connect(now)
	ack, _ := exchange(server, [][]byte{init}, now)
	echo, _ := exchange(client, ack, now)
	ackPackets, _ := exchange(server, echo, now)
	_, _ = exchange(client, ackPackets, now)
	if !client.IsEstablished() || !server.IsEstablished() {
		t.Fatal("not established")
	}

	// Send two ordered messages on stream 0 but deliver only the
	// first; then close the stream from the client.
	pkts1 := client.SendData(0, PpidBinary, []byte("first"), SendOptions{}, now)
	pkts2 := client.SendData(0, PpidBinary, []byte("second"), SendOptions{}, now)
	resps, events := exchange(server, pkts1, now)
	_, _ = exchange(client, resps, now)
	if len(events) != 1 || string(events[0].Payload) != "first" {
		t.Fatalf("events after first = %+v", events)
	}
	resetPkts := client.CloseStream(0)
	resps, events = exchange(server, resetPkts, now)
	// Outgoing reset is deferred until the TSN gap fills.
	for _, ev := range events {
		if ev.Type == "stream-reset" {
			t.Fatal("stream-reset fired before cumulative TSN arrived")
		}
	}
	// Deliver the missing message: the deferred reset now
	// applies and the server auto-resets its outgoing side.
	resps2, events := exchange(server, pkts2, now)
	resps = append(resps, resps2...)
	sawSecond := false
	for _, ev := range events {
		if ev.Type == "data" && string(ev.Payload) == "second" {
			sawSecond = true
		}
	}
	if !sawSecond {
		t.Fatalf("second message missing: %+v", events)
	}
	// The client completes once the deferred response and the
	// server's own outgoing reset arrive.
	clientPkts, clientEvents := exchange(client, resps, now)
	sawClientReset := false
	for _, ev := range clientEvents {
		if ev.Type == "stream-reset" {
			sawClientReset = true
		}
	}
	if !sawClientReset {
		t.Fatalf("client never saw stream-reset: %+v", clientEvents)
	}
	// One more round trip: the server's outgoing reset gets its
	// response and the server completes too.
	_, events = exchange(server, clientPkts, now)
	sawReset := false
	for _, ev := range events {
		if ev.Type == "stream-reset" {
			sawReset = true
		}
	}
	if !sawReset {
		t.Fatalf("server never completed reset: %+v", events)
	}
}
