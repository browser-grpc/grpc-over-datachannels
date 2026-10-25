// DataChannel endpoint: owns a DTLS connection and the SCTP
// association, exposes DCEP channels with an RTCDataChannel-shaped
// surface so grpc-dc-style framing can run on it unchanged.
// Mirrors webrtc/js/endpoint.js.
package dcwebrtc

import (
	"sync"
	"sync/atomic"
	"time"
)

type pendingMessage struct {
	data   []byte
	isText bool
}

// DataChannel is one DCEP channel.
type DataChannel struct {
	ID         uint16
	Label      string
	Params     ChannelParams
	readyState string

	endpoint *DcEndpoint
	mu       sync.Mutex
	handler  func(data []byte, isText bool)
	pending  []pendingMessage

	closeHandler func()
	pendingClose bool
}

// OnMessage registers the message handler; queued messages flush.
func (c *DataChannel) OnMessage(fn func(data []byte, isText bool)) {
	c.mu.Lock()
	c.handler = fn
	pending := c.pending
	c.pending = nil
	c.mu.Unlock()
	for _, msg := range pending {
		fn(msg.data, msg.isText)
	}
}

// Send sends binary data.
func (c *DataChannel) Send(data []byte) {
	c.endpoint.sendData(c, data, false)
}

// SendString sends text data.
func (c *DataChannel) SendString(text string) {
	c.endpoint.sendData(c, []byte(text), true)
}

// OnClose registers the close handler (local or remote close);
// an already-occurred close is delivered immediately.
func (c *DataChannel) OnClose(fn func()) {
	c.mu.Lock()
	c.closeHandler = fn
	pending := c.pendingClose
	c.pendingClose = false
	c.mu.Unlock()
	if pending && fn != nil {
		fn()
	}
}

func (c *DataChannel) emitClose() {
	c.mu.Lock()
	handler := c.closeHandler
	if handler == nil {
		c.pendingClose = true
	}
	c.mu.Unlock()
	if handler != nil {
		handler()
	}
}

// ReadyState reports the channel state ("open", "closing",
// or "closed"); safe to call from any goroutine.
func (c *DataChannel) ReadyState() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.readyState
}

// Close closes the channel: an SCTP stream reset is signaled
// to the peer (ReadyState "closing" until both directions are
// reset, then "closed" and the close handler fires).
func (c *DataChannel) Close() {
	c.mu.Lock()
	if c.readyState != "open" {
		c.mu.Unlock()
		return
	}
	c.readyState = "closing"
	c.mu.Unlock()
	c.endpoint.closeChannel(c)
}

func (c *DataChannel) emitMessage(data []byte, isText bool) {
	c.mu.Lock()
	handler := c.handler
	if handler == nil {
		c.pending = append(c.pending, pendingMessage{data, isText})
		c.mu.Unlock()
		return
	}
	c.mu.Unlock()
	handler(data, isText)
}

// DcEndpoint is a DTLS+SCTP association with DCEP channels.
type DcEndpoint struct {
	// onChannel fires for inbound channels.
	onChannel atomic.Value // func(*DataChannel)

	dtls       *DtlsConnection
	assoc      *Association
	role       string
	channels   map[uint16]*DataChannel
	nextStream uint16
	start      time.Time
	closed     atomic.Bool
	mu         sync.Mutex
	// assocMu serializes every Association call: the
	// association is a single-threaded state machine, but the
	// pump goroutine (HandlePacket/Tick) races application
	// goroutines (SendData/CloseStream/Close) without it.
	assocMu sync.Mutex
	done    chan struct{}
}

// NewDcEndpoint wraps an established DTLS connection. Role "client"
// sends the SCTP INIT and opens even streams; "server" answers and
// opens odd streams.
func NewDcEndpoint(dtls *DtlsConnection, role string) *DcEndpoint {
	isClient := role == "client"
	var assoc *Association
	if isClient {
		assoc = NewClientAssociation(SctpPort, SctpPort)
	} else {
		assoc = NewServerAssociation(SctpPort, SctpPort)
	}
	endpoint := &DcEndpoint{
		dtls: dtls, assoc: assoc, role: role,
		channels: map[uint16]*DataChannel{}, start: time.Now(),
		done: make(chan struct{}),
	}
	if isClient {
		endpoint.nextStream = 0
	} else {
		endpoint.nextStream = 1
	}
	if isClient {
		_ = dtls.SendApp(assoc.Connect(endpoint.now()))
	}
	go endpoint.pump()
	return endpoint
}

func (e *DcEndpoint) now() int64 {
	return time.Since(e.start).Milliseconds()
}

func (e *DcEndpoint) assocSendData(stream uint16, ppid uint32, data []byte, opts SendOptions) [][]byte {
	e.assocMu.Lock()
	defer e.assocMu.Unlock()
	return e.assoc.SendData(stream, ppid, data, opts, e.now())
}

func (e *DcEndpoint) assocHandlePacket(packet []byte) ([][]byte, []SctpEvent) {
	e.assocMu.Lock()
	defer e.assocMu.Unlock()
	return e.assoc.HandlePacket(packet, e.now())
}

func (e *DcEndpoint) assocTick() ([][]byte, []SctpEvent) {
	e.assocMu.Lock()
	defer e.assocMu.Unlock()
	return e.assoc.Tick(e.now())
}

func (e *DcEndpoint) assocCloseStream(id uint16) [][]byte {
	e.assocMu.Lock()
	defer e.assocMu.Unlock()
	return e.assoc.CloseStream(id)
}

func (e *DcEndpoint) assocClose() [][]byte {
	e.assocMu.Lock()
	defer e.assocMu.Unlock()
	return e.assoc.Close(e.now())
}

// SetOnChannel registers the inbound-channel callback. It is
// safe to call after Connect (the pump goroutine reads it
// atomically).
func (e *DcEndpoint) SetOnChannel(fn func(*DataChannel)) {
	e.onChannel.Store(fn)
}

// OpenChannel opens a channel via DCEP.
func (e *DcEndpoint) OpenChannel(params ChannelParams) *DataChannel {
	e.mu.Lock()
	stream := e.nextStream
	e.nextStream += 2
	channel := &DataChannel{ID: stream, Label: params.Label, Params: params, readyState: "open", endpoint: e}
	e.channels[stream] = channel
	e.mu.Unlock()
	packets := e.assocSendData(stream, PpidDcep, EncodeOpen(params), SendOptions{})
	e.sendPackets(packets)
	return channel
}

func (e *DcEndpoint) sendPackets(packets [][]byte) {
	for _, p := range packets {
		_ = e.dtls.SendApp(p)
	}
}

func (e *DcEndpoint) sendData(channel *DataChannel, data []byte, isText bool) {
	var ppid uint32
	switch {
	case isText && len(data) == 0:
		ppid = PpidStringEmpty
	case isText:
		ppid = PpidString
	case len(data) == 0:
		ppid = PpidBinaryEmpty
	default:
		ppid = PpidBinary
	}
	packets := e.assocSendData(channel.ID, ppid, data, channel.Params.SendOptions())
	e.sendPackets(packets)
}

func (e *DcEndpoint) closeChannel(channel *DataChannel) {
	// Keep the channel registered until the reset completes so
	// in-flight messages still deliver; onSctpEvent removes it.
	e.sendPackets(e.assocCloseStream(channel.ID))
}

func (e *DcEndpoint) pump() {
	defer close(e.done)
	for !e.closed.Load() {
		packet, err := e.dtls.RecvAppTimeout(10)
		if err != nil {
			return
		}
		// Drain any backlog without waiting: a paced sender can
		// have many records queued in the socket, and processing
		// one per 10ms wakeup lets the kernel buffer overflow
		// (tail drops then cost a full RTO to recover).
		for packet != nil {
			packets, events := e.assocHandlePacket(packet)
			e.sendPackets(packets)
			for _, event := range events {
				e.onSctpEvent(event)
			}
			if e.closed.Load() {
				return
			}
			packet, err = e.dtls.RecvAppTimeout(0)
			if err != nil {
				return
			}
		}
		packets, events := e.assocTick()
		e.sendPackets(packets)
		for _, event := range events {
			e.onSctpEvent(event)
		}
	}
}

func (e *DcEndpoint) onSctpEvent(event SctpEvent) {
	if event.Type == "stream-reset" {
		e.mu.Lock()
		channel := e.channels[event.Stream]
		delete(e.channels, event.Stream)
		e.mu.Unlock()
		if channel != nil {
			channel.mu.Lock()
			channel.readyState = "closed"
			channel.mu.Unlock()
			channel.emitClose()
		}
		return
	}
	if event.Type != "data" {
		return
	}
	if event.Ppid == PpidDcep {
		msg := DecodeDcep(event.Payload)
		if msg == nil || msg.IsAck {
			return
		}
		channel := &DataChannel{ID: event.Stream, Label: msg.Params.Label, Params: msg.Params, readyState: "open", endpoint: e}
		e.mu.Lock()
		e.channels[event.Stream] = channel
		e.mu.Unlock()
		packets := e.assocSendData(event.Stream, PpidDcep, EncodeAck(), SendOptions{})
		e.sendPackets(packets)
		if fn := e.onChannel.Load(); fn != nil {
			fn.(func(*DataChannel))(channel)
		}
		return
	}
	e.mu.Lock()
	channel := e.channels[event.Stream]
	e.mu.Unlock()
	if channel == nil {
		return
	}
	isText := event.Ppid == PpidString || event.Ppid == PpidStringEmpty
	channel.emitMessage(event.Payload, isText)
}

// Close shuts down the association.
func (e *DcEndpoint) Close() {
	e.closed.Store(true)
	e.sendPackets(e.assocClose())
}
