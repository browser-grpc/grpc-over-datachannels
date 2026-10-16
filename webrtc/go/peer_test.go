package dcwebrtc

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func TestStunBindingAndFingerprint(t *testing.T) {
	msg := newStunMessage(StunTypeBindingRequest)
	msg.addAttr(StunAttrSoftware, []byte("dc-webrtc"))
	raw := msg.Encode(nil)
	parsed := DecodeStun(raw)
	if parsed == nil || parsed.Type != StunTypeBindingRequest {
		t.Fatalf("parsed %+v", parsed)
	}
	key := []byte("password1234567890")
	signed := msg.Encode(key)
	if !msg.CheckIntegrity(signed, key) {
		t.Fatal("integrity check failed")
	}
}

func TestCrc32cKnownVector(t *testing.T) {
	if got := Crc32c([]byte("123456789")); got != 0xe3069283 {
		t.Fatalf("crc32c = %08x", got)
	}
}

func TestSdpRoundTrip(t *testing.T) {
	desc := SessionDescription{
		Ufrag: "abcd", Pwd: "1234567890123456789012",
		Fingerprint: FingerprintOfDER([]byte("x")), Setup: "actpass",
		Candidates: []Candidate{HostCandidate("127.0.0.1", 5000, "1")},
		SctpPort:   SctpPort,
	}
	text := desc.Generate("offer")
	parsed, err := ParseSDP(text)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Ufrag != "abcd" || parsed.Setup != "actpass" || len(parsed.Candidates) != 1 {
		t.Fatalf("parsed %+v", parsed)
	}
	if !strings.HasPrefix(text, "v=0\r\n") {
		t.Fatal("sdp must be CRLF")
	}
}

func TestDcepOpenRoundTrip(t *testing.T) {
	params := DefaultChannelParams("echo")
	payload := EncodeOpen(params)
	msg := DecodeDcep(payload)
	if msg == nil || msg.IsAck || msg.Params.Label != "echo" || !msg.Params.Ordered {
		t.Fatalf("decoded %+v", msg)
	}
	var mr uint32 = 3
	partial := ChannelParams{Label: "p", Ordered: false, MaxRetransmits: &mr}
	msg2 := DecodeDcep(EncodeOpen(partial))
	if msg2 == nil || msg2.Params.Ordered || msg2.Params.MaxRetransmits == nil || *msg2.Params.MaxRetransmits != 3 {
		t.Fatalf("partial decoded %+v", msg2)
	}
}

// pump two associations directly against each other.
func TestSctpLoopback(t *testing.T) {
	client := NewClientAssociation(SctpPort, SctpPort)
	server := NewServerAssociation(SctpPort, SctpPort)
	exchange := func(from, to *Association, packets [][]byte, now int64) ([][]byte, []SctpEvent) {
		var out [][]byte
		var events []SctpEvent
		for _, p := range packets {
			packets2, events2 := to.HandlePacket(p, now)
			out = append(out, packets2...)
			events = append(events, events2...)
		}
		_ = from
		return out, events
	}
	var now int64
	init := client.Connect(now)
	ack, _ := exchange(client, server, [][]byte{init}, now)
	echo, serverEvents := exchange(server, client, ack, now)
	if len(serverEvents) != 0 {
		_ = serverEvents
	}
	ackPackets, clientEvents := exchange(client, server, echo, now)
	_, _ = exchange(server, client, ackPackets, now)
	if !client.IsEstablished() || !server.IsEstablished() {
		t.Fatalf("not established: client=%v server=%v events=%v", client.state, server.state, clientEvents)
	}
	data := client.SendData(0, PpidBinary, []byte("hello sctp"), SendOptions{}, now)
	_, events := exchange(client, server, data, now)
	found := false
	for _, ev := range events {
		if ev.Type == "data" && string(ev.Payload) == "hello sctp" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no data event: %+v", events)
	}
	// fragmented large payload
	big := bytes.Repeat([]byte("z"), 5000)
	data = server.SendData(1, PpidBinary, big, SendOptions{}, now)
	_, events = exchange(server, client, data, now)
	found = false
	for _, ev := range events {
		if ev.Type == "data" && bytes.Equal(ev.Payload, big) {
			found = true
		}
	}
	if !found {
		t.Fatal("fragmented payload not reassembled")
	}
}

func TestPeerEcho(t *testing.T) {
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
		endpoint *DcEndpoint
		err      error
	}
	results := make(chan result, 2)
	go func() {
		endpoint, err := a.ConnectWithOptions(true)
		results <- result{endpoint, err}
	}()
	go func() {
		endpoint, err := b.ConnectWithOptions(true)
		results <- result{endpoint, err}
	}()
	var endpoints []*DcEndpoint
	for i := 0; i < 2; i++ {
		select {
		case r := <-results:
			if r.err != nil {
				t.Fatalf("connect: %v", r.err)
			}
			endpoints = append(endpoints, r.endpoint)
		case <-time.After(30 * time.Second):
			t.Fatal("connect timed out")
		}
	}
	epA, epB := endpoints[0], endpoints[1]

	received := make(chan []byte, 1)
	epB.SetOnChannel(func(channel *DataChannel) {
		channel.OnMessage(func(data []byte, isText bool) {
			reply := append([]byte("echo:"), data...)
			channel.Send(reply)
		})
	})
	channel := epA.OpenChannel(DefaultChannelParams("echo"))
	got := make(chan []byte, 1)
	channel.OnMessage(func(data []byte, isText bool) {
		cp := make([]byte, len(data))
		copy(cp, data)
		got <- cp
	})
	channel.Send([]byte("hello go webrtc"))
	select {
	case data := <-got:
		if string(data) != "echo:hello go webrtc" {
			t.Fatalf("got %q", data)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("echo timed out")
	}
	_ = received
	_ = epA
	_ = epB
}
