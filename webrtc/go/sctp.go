// SCTP (RFC 9260) subset for WebRTC datachannels — a pure
// packet-in/packet-out state machine mirroring webrtc/js/sctp.ts:
// INIT/COOKIE handshake (HMAC state cookie), DATA/SACK with gap
// reports and fast retransmit, fragmentation/reassembly, ordered +
// unordered delivery, PR-SCTP FORWARD-TSN, RE-CONFIG stream
// reset (RFC 6525, for datachannel close), HEARTBEAT, SHUTDOWN,
// CRC-32C checksum. Stdlib only.
package dcwebrtc

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"sort"
)

// SctpPort is the default SCTP port in the SDP profile.
const SctpPort = 5000

const maxDataPayload = 1000
const initialRwnd = 262144

// RFC 9260 section 6.1: initial cwnd is 4 MTU here (fragment
// payload is 1000B, so ~4 fragments in flight before SACK clocking).
const initialCwnd = 4 * maxDataPayload
const initialRtoMs = 1000

// Crc32c computes the SCTP checksum (Castagnoli, reflected).
func Crc32c(buf []byte) uint32 {
	crc := uint32(0xffffffff)
	for _, b := range buf {
		crc = Crc32cTable[(crc^uint32(b))&0xff] ^ (crc >> 8)
	}
	return crc ^ 0xffffffff
}

func add32(a, b uint32) uint32 { return a + b }

// diff32 is the signed difference a-b in TSN serial arithmetic.
func diff32(a, b uint32) int32 {
	d := int64(int32(a - b))
	_ = d
	return int32(a - b)
}

func sctpChunk(chunkType byte, flags byte, body []byte) []byte {
	out := make([]byte, 4+len(body))
	out[0] = chunkType
	out[1] = flags
	binary.BigEndian.PutUint16(out[2:4], uint16(len(body)+4))
	copy(out[4:], body)
	return pad4(out)
}

func sctpParam(paramType uint16, value []byte) []byte {
	body := make([]byte, 4+len(value))
	binary.BigEndian.PutUint16(body[0:2], paramType)
	binary.BigEndian.PutUint16(body[2:4], uint16(len(value)+4))
	copy(body[4:], value)
	return pad4(body)
}

func pad4(in []byte) []byte {
	out := make([]byte, (len(in)+3)/4*4)
	copy(out, in)
	return out
}

type sctpParamView struct {
	typ   uint16
	value []byte
}

func parseSctpParams(data []byte) []sctpParamView {
	var out []sctpParamView
	for pos := 0; pos+4 <= len(data); {
		typ := binary.BigEndian.Uint16(data[pos : pos+2])
		length := int(binary.BigEndian.Uint16(data[pos+2 : pos+4]))
		if length < 4 || pos+length > len(data) {
			break
		}
		out = append(out, sctpParamView{typ, data[pos+4 : pos+length]})
		pos += (length + 3) / 4 * 4
	}
	return out
}

type sctpChunkView struct {
	typ   byte
	flags byte
	body  []byte
}

func parseSctpChunks(data []byte) []sctpChunkView {
	var out []sctpChunkView
	for pos := 0; pos+4 <= len(data); {
		length := int(binary.BigEndian.Uint16(data[pos+2 : pos+4]))
		if length < 4 || pos+length > len(data) {
			break
		}
		out = append(out, sctpChunkView{data[pos], data[pos+1], data[pos+4 : pos+length]})
		pos += (length + 3) / 4 * 4
	}
	return out
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

type outChunk struct {
	tsn         uint32
	stream      uint16
	ssn         uint16
	ppid        uint32
	flags       byte
	payload     []byte
	opts        SendOptions
	retransmits uint32
	bornMs      int64
	lastSentMs  int64
}

func dataChunkBytes(c *outChunk) []byte {
	body := make([]byte, 12+len(c.payload))
	binary.BigEndian.PutUint32(body[0:4], c.tsn)
	binary.BigEndian.PutUint16(body[4:6], c.stream)
	binary.BigEndian.PutUint16(body[6:8], c.ssn)
	binary.BigEndian.PutUint32(body[8:12], c.ppid)
	copy(body[12:], c.payload)
	return sctpChunk(SctpChunkData, c.flags, body)
}

type queuedMessage struct {
	stream  uint16
	ppid    uint32
	payload []byte
	opts    SendOptions
}

// Association is the SCTP state machine.
type Association struct {
	isClient   bool
	localPort  uint16
	peerPort   uint16
	myTag      uint32
	peerTag    uint32
	state      string
	nextTsn    uint32
	outCumDone uint32
	peerCumTsn uint32

	peerReceived  map[uint32]bool
	outSsn        map[uint16]uint16
	unacked       map[uint32]*outChunk
	queued        []queuedMessage
	outQueue      []*outChunk // chunks awaiting cwnd/rwnd room
	inflightBytes int
	peerRwnd      uint32
	// Congestion window (RFC 9260 section 6): without it a
	// large message bursts its fragments into kernel UDP
	// buffers faster than the peer drains them; the dropped
	// tail then recovers only at RTO granularity (1s a round).
	cwnd             int
	ssthresh         int
	reasm            *sctpReassembler
	cookieSecret     []byte
	pendingCookie    []byte
	lastInitMs       int64
	lastPacketOutMs  int64
	rtoMs            int64
	missCounts       map[uint32]int
	abandonedOrdered [][2]uint16

	// Stream reset (RFC 6525) bookkeeping.
	reconfSeq         uint32
	resets            map[uint16]*streamResetState
	pendingReconf     []pendingOutgoingReset
	localResetSeqs    map[uint32]resetDirection
	outResetDone      map[uint16]bool
	peerInitialTsn    uint32
	lastPeerReconfSeq uint32
	hasPeerReconfSeq  bool
}

type streamResetState struct {
	outDone  bool // our outgoing side of the stream is reset
	inDone   bool // peer's outgoing side (our incoming) is reset
	reported bool
}

type pendingOutgoingReset struct {
	seq     uint32
	lastTsn uint32
	streams []uint16
}

type resetDirection struct {
	stream   uint16
	outgoing bool // true: our OutgoingResetRequest; false: our IncomingResetRequest
}

func newAssociation(isClient bool, localPort, peerPort uint16) *Association {
	var tagBytes [4]byte
	_, _ = rand.Read(tagBytes[:])
	var tsnBytes [4]byte
	_, _ = rand.Read(tsnBytes[:])
	secret := make([]byte, 32)
	_, _ = rand.Read(secret)
	nextTsn := binary.BigEndian.Uint32(tsnBytes[:])
	return &Association{
		isClient:       isClient,
		localPort:      localPort,
		peerPort:       peerPort,
		myTag:          binary.BigEndian.Uint32(tagBytes[:]) | 1,
		state:          "closed",
		nextTsn:        nextTsn,
		outCumDone:     nextTsn - 1,
		peerReceived:   map[uint32]bool{},
		outSsn:         map[uint16]uint16{},
		unacked:        map[uint32]*outChunk{},
		peerRwnd:       initialRwnd,
		cwnd:           initialCwnd,
		ssthresh:       int(^uint(0) >> 1),
		reasm:          newSctpReassembler(),
		cookieSecret:   secret,
		rtoMs:          initialRtoMs,
		missCounts:     map[uint32]int{},
		reconfSeq:      nextTsn,
		resets:         map[uint16]*streamResetState{},
		localResetSeqs: map[uint32]resetDirection{},
		outResetDone:   map[uint16]bool{},
	}
}

// NewClientAssociation creates an INIT-sending association.
func NewClientAssociation(localPort, peerPort uint16) *Association {
	return newAssociation(true, localPort, peerPort)
}

// NewServerAssociation creates an INIT-answering association.
func NewServerAssociation(localPort, peerPort uint16) *Association {
	return newAssociation(false, localPort, peerPort)
}

// IsEstablished reports whether data may flow.
func (a *Association) IsEstablished() bool { return a.state == "established" }

func (a *Association) packet(vtag uint32, chunks []byte) []byte {
	out := make([]byte, 12+len(chunks))
	binary.BigEndian.PutUint16(out[0:2], a.localPort)
	binary.BigEndian.PutUint16(out[2:4], a.peerPort)
	binary.BigEndian.PutUint32(out[4:8], vtag)
	copy(out[12:], chunks)
	binary.LittleEndian.PutUint32(out[8:12], Crc32c(out))
	return out
}

func (a *Association) initBody() []byte {
	body := make([]byte, 16)
	binary.BigEndian.PutUint32(body[0:4], a.myTag)
	binary.BigEndian.PutUint32(body[4:8], initialRwnd)
	binary.BigEndian.PutUint16(body[8:10], 1024)
	binary.BigEndian.PutUint16(body[10:12], 1024)
	binary.BigEndian.PutUint32(body[12:16], a.nextTsn)
	body = append(body, sctpParam(12, []byte{0, 5, 0, 6})...)
	body = append(body, sctpParam(SctpParamForwardTsnSupported, nil)...)
	// Supported Extensions: RE-CONFIG (130) and FORWARD-TSN (192).
	return append(body, sctpParam(SctpParamSupportedExtensions, []byte{SctpChunkReConfig, SctpChunkForwardTsn})...)
}

// Connect starts the handshake (client) and returns the INIT packet.
func (a *Association) Connect(nowMs int64) []byte {
	a.state = "cookie-wait"
	a.lastInitMs = nowMs
	return a.packet(0, sctpChunk(SctpChunkInit, 0, a.initBody()))
}

func (a *Association) makeCookie(peerTag, peerTsn, myTsn uint32) []byte {
	data := make([]byte, 16)
	binary.BigEndian.PutUint32(data[0:4], peerTag)
	binary.BigEndian.PutUint32(data[4:8], a.myTag)
	binary.BigEndian.PutUint32(data[8:12], peerTsn)
	binary.BigEndian.PutUint32(data[12:16], myTsn)
	mac := hmac.New(sha256.New, a.cookieSecret)
	mac.Write(data)
	return append(data, mac.Sum(nil)[:16]...)
}

func (a *Association) checkCookie(cookie []byte) (peerTag, myTag, peerTsn, myTsn uint32, ok bool) {
	if len(cookie) != 32 {
		return 0, 0, 0, 0, false
	}
	mac := hmac.New(sha256.New, a.cookieSecret)
	mac.Write(cookie[:16])
	if !hmac.Equal(mac.Sum(nil)[:16], cookie[16:]) {
		return 0, 0, 0, 0, false
	}
	return binary.BigEndian.Uint32(cookie[0:4]), binary.BigEndian.Uint32(cookie[4:8]),
		binary.BigEndian.Uint32(cookie[8:12]), binary.BigEndian.Uint32(cookie[12:16]), true
}

// CloseStream closes one stream (RFC 8831 §6.4): reset our
// outgoing side with an Outgoing SSN Reset Request. The peer
// resets its outgoing side in turn; the "stream-reset" event
// fires once both directions are done. Unsent queued messages
// for the stream are dropped so the sender's last assigned TSN
// covers everything in flight.
func (a *Association) CloseStream(stream uint16) [][]byte {
	if pkt := a.initiateOutgoingReset(stream); pkt != nil {
		return [][]byte{pkt}
	}
	return nil
}

func (a *Association) responseSeqForOutgoing() uint32 {
	// Next expected peer request sequence minus 1 (RFC 6525
	// §4.1): the last request sequence received, or the peer's
	// initial TSN minus 1.
	if a.hasPeerReconfSeq {
		return a.lastPeerReconfSeq
	}
	return a.peerInitialTsn - 1
}

func (a *Association) initiateOutgoingReset(stream uint16) []byte {
	if a.state != "established" || a.outResetDone[stream] {
		return nil
	}
	a.outResetDone[stream] = true
	kept := a.queued[:0]
	for _, q := range a.queued {
		if q.stream != stream {
			kept = append(kept, q)
		}
	}
	a.queued = kept

	seq := a.reconfSeq
	a.reconfSeq++
	a.localResetSeqs[seq] = resetDirection{stream, true}
	a.resetStateOf(stream)

	value := make([]byte, 14)
	binary.BigEndian.PutUint32(value[0:4], seq)
	binary.BigEndian.PutUint32(value[4:8], a.responseSeqForOutgoing())
	binary.BigEndian.PutUint32(value[8:12], a.nextTsn-1)
	binary.BigEndian.PutUint16(value[12:14], stream)
	params := sctpParam(SctpReconfigOutgoingSsnResetRequest, value)
	return a.packet(a.peerTag, sctpChunk(SctpChunkReConfig, 0, params))
}

func (a *Association) resetStateOf(stream uint16) *streamResetState {
	st, ok := a.resets[stream]
	if !ok {
		st = &streamResetState{}
		a.resets[stream] = st
	}
	return st
}

func (a *Association) maybeReportReset(stream uint16, events *[]SctpEvent) {
	st := a.resetStateOf(stream)
	if st.outDone && st.inDone && !st.reported {
		st.reported = true
		*events = append(*events, SctpEvent{Type: "stream-reset", Stream: stream})
	}
}

// resetIncomingSide applies the peer's Outgoing SSN Reset for
// one stream: deliver what completed in order, then clear
// inbound SSN state. Per RFC 8831 §6.4 it also resets our
// corresponding outgoing side (packet appended to packets).
func (a *Association) resetIncomingSide(stream uint16, packets *[][]byte, events *[]SctpEvent) {
	*events = append(*events, sctpDataEvents(a.reasm.reset(stream))...)
	a.resetStateOf(stream).inDone = true
	a.maybeReportReset(stream, events)
	if packets != nil {
		if pkt := a.initiateOutgoingReset(stream); pkt != nil {
			*packets = append(*packets, pkt)
		}
	}
}

// resetOutgoingSide applies the peer's Incoming SSN Reset for
// one stream: reset our SSN counter and drop unsent data.
func (a *Association) resetOutgoingSide(stream uint16, events *[]SctpEvent) {
	a.outSsn[stream] = 0
	a.outResetDone[stream] = true
	kept := a.queued[:0]
	for _, q := range a.queued {
		if q.stream != stream {
			kept = append(kept, q)
		}
	}
	a.queued = kept
	for tsn, c := range a.unacked {
		if c.stream == stream {
			a.inflightBytes -= len(c.payload)
			delete(a.unacked, tsn)
		}
	}
	if a.inflightBytes < 0 {
		a.inflightBytes = 0
	}
	a.resetStateOf(stream).outDone = true
	a.maybeReportReset(stream, events)
}

func reconfigResponseParam(seq, result uint32) []byte {
	value := make([]byte, 8)
	binary.BigEndian.PutUint32(value[0:4], seq)
	binary.BigEndian.PutUint32(value[4:8], result)
	return sctpParam(SctpReconfigReconfigurationResponse, value)
}

// processPendingResets applies deferred Outgoing SSN Reset
// requests whose sender-last-assigned TSN is now cumulative.
func (a *Association) processPendingResets() ([][]byte, []SctpEvent) {
	if len(a.pendingReconf) == 0 {
		return nil, nil
	}
	var packets [][]byte
	var events []SctpEvent
	var remaining []pendingOutgoingReset
	for _, pending := range a.pendingReconf {
		if diff32(a.peerCumTsn, pending.lastTsn) < 0 {
			remaining = append(remaining, pending)
			continue
		}
		for _, stream := range pending.streams {
			a.resetIncomingSide(stream, &packets, &events)
		}
		packets = append(packets, a.packet(a.peerTag,
			sctpChunk(SctpChunkReConfig, 0, reconfigResponseParam(pending.seq, 1))))
	}
	a.pendingReconf = remaining
	return packets, events
}

func (a *Association) handleReconfig(body []byte) ([][]byte, []SctpEvent) {
	var packets [][]byte
	var events []SctpEvent
	var responses []byte
	for _, p := range parseSctpParams(body) {
		switch p.typ {
		case SctpReconfigOutgoingSsnResetRequest:
			// Value: request seq, response seq, sender last
			// assigned TSN, then stream numbers (RFC 6525 §4.1).
			if len(p.value) < 12 {
				continue
			}
			seq := binary.BigEndian.Uint32(p.value[0:4])
			responseSeq := binary.BigEndian.Uint32(p.value[4:8])
			lastTsn := binary.BigEndian.Uint32(p.value[8:12])
			a.lastPeerReconfSeq = seq
			a.hasPeerReconfSeq = true
			// An Outgoing request can implicitly answer our
			// Incoming request whose sequence it echoes.
			if dir, ok := a.localResetSeqs[responseSeq]; ok && !dir.outgoing {
				delete(a.localResetSeqs, responseSeq)
				a.resetStateOf(dir.stream).inDone = true
				a.maybeReportReset(dir.stream, &events)
			}
			var streams []uint16
			for pos := 12; pos+2 <= len(p.value); pos += 2 {
				streams = append(streams, binary.BigEndian.Uint16(p.value[pos:pos+2]))
			}
			if len(streams) == 0 {
				streams = a.reasm.streamIds()
			}
			if diff32(a.peerCumTsn, lastTsn) < 0 {
				// Wait until everything the sender had sent
				// has arrived before resetting (RFC 6525 §5.2).
				a.pendingReconf = append(a.pendingReconf,
					pendingOutgoingReset{seq, lastTsn, streams})
				continue
			}
			for _, stream := range streams {
				a.resetIncomingSide(stream, &packets, &events)
			}
			responses = append(responses, reconfigResponseParam(seq, 1)...)
		case SctpReconfigIncomingSsnResetRequest:
			if len(p.value) < 4 {
				continue
			}
			seq := binary.BigEndian.Uint32(p.value[0:4])
			a.lastPeerReconfSeq = seq
			a.hasPeerReconfSeq = true
			for pos := 4; pos+2 <= len(p.value); pos += 2 {
				a.resetOutgoingSide(binary.BigEndian.Uint16(p.value[pos:pos+2]), &events)
			}
			responses = append(responses, reconfigResponseParam(seq, 1)...)
		case SctpReconfigReconfigurationResponse:
			if len(p.value) < 8 {
				continue
			}
			seq := binary.BigEndian.Uint32(p.value[0:4])
			result := binary.BigEndian.Uint32(p.value[4:8])
			dir, ok := a.localResetSeqs[seq]
			if !ok {
				continue
			}
			delete(a.localResetSeqs, seq)
			if result == 0 || result == 1 {
				st := a.resetStateOf(dir.stream)
				if dir.outgoing {
					st.outDone = true
				} else {
					st.inDone = true
				}
				a.maybeReportReset(dir.stream, &events)
			}
		default:
			// SSN/TSN reset and Add-Streams are not used by
			// datachannels here; deny politely.
			if len(p.value) >= 4 {
				seq := binary.BigEndian.Uint32(p.value[0:4])
				responses = append(responses, reconfigResponseParam(seq, 2)...)
			}
		}
	}
	if len(responses) > 0 {
		packets = append(packets, a.packet(a.peerTag, sctpChunk(SctpChunkReConfig, 0, responses)))
	}
	return packets, events
}

// SendData queues or sends one message, returning packets to transmit.
func (a *Association) SendData(stream uint16, ppid uint32, payload []byte, opts SendOptions, nowMs int64) [][]byte {
	if a.outResetDone[stream] {
		return nil // stream is reset/closing: no new data
	}
	if a.state != "established" {
		// Not established yet: queue whole payloads; the flush
		// after COOKIE-ACK moves them into the chunk queue.
		cp := make([]byte, len(payload))
		copy(cp, payload)
		a.queued = append(a.queued, queuedMessage{stream, ppid, cp, opts})
		return nil
	}
	a.enqueueChunks(stream, ppid, payload, opts, nowMs)
	return a.flushOut(nowMs)
}

func (a *Association) enqueueChunks(stream uint16, ppid uint32, payload []byte, opts SendOptions, nowMs int64) {
	var ssn uint16
	if !opts.Unordered {
		ssn = a.outSsn[stream]
		a.outSsn[stream] = ssn + 1
	}
	var fragments [][]byte
	if len(payload) == 0 {
		fragments = append(fragments, nil)
	}
	for off := 0; off < len(payload); off += maxDataPayload {
		end := off + maxDataPayload
		if end > len(payload) {
			end = len(payload)
		}
		fragments = append(fragments, payload[off:end])
	}
	for i, frag := range fragments {
		var flags byte
		if opts.Unordered {
			flags |= 0x04
		}
		if i == 0 {
			flags |= 0x02
		}
		if i == len(fragments)-1 {
			flags |= 0x01
		}
		cp := make([]byte, len(frag))
		copy(cp, frag)
		c := &outChunk{
			tsn: a.nextTsn, stream: stream, ssn: ssn, ppid: ppid, flags: flags,
			payload: cp, opts: opts, bornMs: nowMs, lastSentMs: nowMs,
		}
		a.nextTsn++
		a.outQueue = append(a.outQueue, c)
	}
}

// flushOut emits queued chunks while cwnd and the peer rwnd allow.
func (a *Association) flushOut(nowMs int64) [][]byte {
	var packets [][]byte
	limit := a.cwnd
	if int(a.peerRwnd) < limit {
		limit = int(a.peerRwnd)
	}
	for len(a.outQueue) > 0 && a.inflightBytes < limit {
		c := a.outQueue[0]
		a.outQueue = a.outQueue[1:]
		a.inflightBytes += len(c.payload)
		c.lastSentMs = nowMs
		packets = append(packets, a.packet(a.peerTag, dataChunkBytes(c)))
		a.unacked[c.tsn] = c
	}
	if len(packets) > 0 {
		a.lastPacketOutMs = nowMs
	}
	return packets
}

func (a *Association) flushQueue(nowMs int64) [][]byte {
	for len(a.queued) > 0 {
		m := a.queued[0]
		a.queued = a.queued[1:]
		a.enqueueChunks(m.stream, m.ppid, m.payload, m.opts, nowMs)
	}
	return a.flushOut(nowMs)
}

func (a *Association) sackPacket() []byte {
	var sorted []uint32
	for tsn := range a.peerReceived {
		if diff32(tsn, a.peerCumTsn) > 0 {
			sorted = append(sorted, tsn)
		}
	}
	sort.Slice(sorted, func(i, j int) bool { return diff32(sorted[i], sorted[j]) < 0 })
	type gap struct{ start, end uint16 }
	var gaps []gap
	for i := 0; i < len(sorted); {
		start := sorted[i]
		end := start
		for i+1 < len(sorted) && sorted[i+1] == end+1 {
			end = sorted[i+1]
			i++
		}
		gaps = append(gaps, gap{uint16(diff32(start, a.peerCumTsn)), uint16(diff32(end, a.peerCumTsn))})
		i++
	}
	body := make([]byte, 12+len(gaps)*4)
	binary.BigEndian.PutUint32(body[0:4], a.peerCumTsn)
	binary.BigEndian.PutUint32(body[4:8], initialRwnd)
	binary.BigEndian.PutUint16(body[8:10], uint16(len(gaps)))
	for idx, g := range gaps {
		binary.BigEndian.PutUint16(body[12+idx*4:14+idx*4], g.start)
		binary.BigEndian.PutUint16(body[14+idx*4:16+idx*4], g.end)
	}
	return a.packet(a.peerTag, sctpChunk(SctpChunkSack, 0, body))
}

// HandlePacket processes one inbound packet.
func (a *Association) HandlePacket(packet []byte, nowMs int64) ([][]byte, []SctpEvent) {
	var packets [][]byte
	var events []SctpEvent
	if len(packet) < 12 {
		return packets, events
	}
	check := make([]byte, len(packet))
	copy(check, packet)
	binary.LittleEndian.PutUint32(check[8:12], 0)
	if Crc32c(check) != binary.LittleEndian.Uint32(packet[8:12]) {
		return packets, events
	}
	vtag := binary.BigEndian.Uint32(packet[4:8])
	for _, view := range parseSctpChunks(packet[12:]) {
		switch view.typ {
		case SctpChunkInit:
			if a.isClient || len(view.body) < 16 {
				break
			}
			peerTag := binary.BigEndian.Uint32(view.body[0:4])
			peerTsn := binary.BigEndian.Uint32(view.body[12:16])
			a.peerInitialTsn = peerTsn
			cookie := a.makeCookie(peerTag, peerTsn, a.nextTsn)
			body := append(a.initBody(), sctpParam(7, cookie)...)
			packets = append(packets, a.packet(peerTag, sctpChunk(SctpChunkInitAck, 0, body)))
		case SctpChunkInitAck:
			if !a.isClient || a.state != "cookie-wait" || len(view.body) < 16 {
				break
			}
			a.peerTag = binary.BigEndian.Uint32(view.body[0:4])
			a.peerInitialTsn = binary.BigEndian.Uint32(view.body[12:16])
			a.peerCumTsn = a.peerInitialTsn - 1
			for _, p := range parseSctpParams(view.body[16:]) {
				if p.typ == 7 {
					a.pendingCookie = p.value
				}
			}
			a.state = "cookie-echoed"
			a.lastInitMs = nowMs
			packets = append(packets, a.packet(a.peerTag, sctpChunk(SctpChunkCookieEcho, 0, a.pendingCookie)))
		case SctpChunkCookieEcho:
			if a.isClient {
				break
			}
			peerTag, myTag, peerTsn, myTsn, ok := a.checkCookie(view.body)
			if !ok {
				break
			}
			a.peerTag, a.myTag = peerTag, myTag
			a.peerInitialTsn = peerTsn
			a.peerCumTsn = peerTsn - 1
			a.nextTsn = myTsn
			a.outCumDone = myTsn - 1
			a.state = "established"
			packets = append(packets, a.packet(a.peerTag, sctpChunk(SctpChunkCookieAck, 0, nil)))
			events = append(events, SctpEvent{Type: "connected"})
			packets = append(packets, a.flushQueue(nowMs)...)
		case SctpChunkCookieAck:
			if a.isClient && a.state == "cookie-echoed" {
				a.state = "established"
				events = append(events, SctpEvent{Type: "connected"})
				packets = append(packets, a.flushQueue(nowMs)...)
			}
		case SctpChunkData:
			if vtag != a.myTag && a.state == "established" {
				break
			}
			events = append(events, a.handleData(view.flags, view.body)...)
			packets = append(packets, a.sackPacket())
		case SctpChunkSack:
			packets = append(packets, a.handleSack(view.body, nowMs)...)
		case SctpChunkHeartbeat:
			packets = append(packets, a.packet(a.peerTag, sctpChunk(SctpChunkHeartbeatAck, 0, view.body)))
		case SctpChunkReConfig:
			rp, rev := a.handleReconfig(view.body)
			packets = append(packets, rp...)
			events = append(events, rev...)
		case SctpChunkForwardTsn:
			events = append(events, a.handleForwardTsn(view.body)...)
			packets = append(packets, a.sackPacket())
		case SctpChunkShutdown:
			packets = append(packets, a.packet(a.peerTag, sctpChunk(SctpChunkShutdownAck, 0, nil)))
			a.state = "closed"
			events = append(events, SctpEvent{Type: "closed"})
		case SctpChunkShutdownAck:
			packets = append(packets, a.packet(a.peerTag, sctpChunk(SctpChunkShutdownComplete, 0, nil)))
			a.state = "closed"
			events = append(events, SctpEvent{Type: "closed"})
		case SctpChunkShutdownComplete, SctpChunkAbort:
			a.state = "closed"
			events = append(events, SctpEvent{Type: "closed"})
		}
	}
	// Cumulative TSN may have advanced: apply deferred resets.
	rp, rev := a.processPendingResets()
	packets = append(packets, rp...)
	events = append(events, rev...)
	return packets, events
}

func sctpDataEvents(deliveries []sctpDelivery) []SctpEvent {
	var events []SctpEvent
	for _, d := range deliveries {
		events = append(events, SctpEvent{Type: "data", Stream: d.Stream, Ppid: d.Ppid, Payload: d.Payload})
	}
	return events
}

func (a *Association) handleData(flags byte, body []byte) []SctpEvent {
	if len(body) < 12 {
		return nil
	}
	tsn := binary.BigEndian.Uint32(body[0:4])
	stream := binary.BigEndian.Uint16(body[4:6])
	ssn := binary.BigEndian.Uint16(body[6:8])
	ppid := binary.BigEndian.Uint32(body[8:12])
	payload := body[12:]
	unordered := flags&0x04 != 0
	isBegin := flags&0x02 != 0
	isEnd := flags&0x01 != 0

	if diff32(tsn, a.peerCumTsn) > 0 {
		a.peerReceived[tsn] = true
		for a.peerReceived[a.peerCumTsn+1] {
			a.peerCumTsn++
			delete(a.peerReceived, a.peerCumTsn)
		}
	}

	return sctpDataEvents(a.reasm.feed(tsn, stream, ssn, ppid, unordered, isBegin, isEnd, payload))
}

func (a *Association) handleForwardTsn(body []byte) []SctpEvent {
	if len(body) < 4 {
		return nil
	}
	newCum := binary.BigEndian.Uint32(body[0:4])
	if diff32(newCum, a.peerCumTsn) > 0 {
		for tsn := range a.peerReceived {
			if diff32(tsn, newCum) <= 0 {
				delete(a.peerReceived, tsn)
			}
		}
		a.peerCumTsn = newCum
	}
	var events []SctpEvent
	for pos := 4; pos+4 <= len(body); pos += 4 {
		stream := binary.BigEndian.Uint16(body[pos : pos+2])
		ssn := binary.BigEndian.Uint16(body[pos+2 : pos+4])
		events = append(events, sctpDataEvents(a.reasm.skip(stream, ssn))...)
	}
	return events
}

func sortedUnackedTsns(a *Association) []uint32 {
	tsns := make([]uint32, 0, len(a.unacked))
	for tsn := range a.unacked {
		tsns = append(tsns, tsn)
	}
	sort.Slice(tsns, func(i, j int) bool { return diff32(tsns[i], tsns[j]) < 0 })
	return tsns
}

func (a *Association) handleSack(body []byte, nowMs int64) [][]byte {
	if len(body) < 12 {
		return nil
	}
	cum := binary.BigEndian.Uint32(body[0:4])
	a.peerRwnd = binary.BigEndian.Uint32(body[4:8])
	numGaps := int(binary.BigEndian.Uint16(body[8:10]))
	type gapRange struct{ start, end uint32 }
	var gaps []gapRange
	for i, pos := 0, 12; i < numGaps && pos+4 <= len(body); i, pos = i+1, pos+4 {
		s := binary.BigEndian.Uint16(body[pos : pos+2])
		e := binary.BigEndian.Uint16(body[pos+2 : pos+4])
		gaps = append(gaps, gapRange{cum + uint32(s), cum + uint32(e)})
	}
	freed := 0
	for _, tsn := range sortedUnackedTsns(a) {
		c := a.unacked[tsn]
		inGap := false
		for _, g := range gaps {
			if diff32(tsn, g.start) >= 0 && diff32(tsn, g.end) <= 0 {
				inGap = true
				break
			}
		}
		if diff32(tsn, cum) <= 0 || inGap {
			freed += len(c.payload)
			delete(a.unacked, tsn)
			delete(a.missCounts, tsn)
		}
	}
	a.inflightBytes -= freed
	if a.inflightBytes < 0 {
		a.inflightBytes = 0
	}
	if freed > 0 {
		// RFC 9260 section 6.2: slow start grows cwnd by up to
		// one MTU per SACK; congestion avoidance ~MTU per RTT.
		if a.cwnd < a.ssthresh {
			grow := freed
			if grow > maxDataPayload {
				grow = maxDataPayload
			}
			a.cwnd += grow
		} else {
			grow := maxDataPayload * maxDataPayload / a.cwnd
			if grow < 1 {
				grow = 1
			}
			a.cwnd += grow
		}
	}
	a.advanceOutCum()
	var packets [][]byte
	if len(gaps) > 0 {
		firstStart := gaps[0].start
		for _, tsn := range sortedUnackedTsns(a) {
			c := a.unacked[tsn]
			if c == nil {
				continue
			}
			if diff32(tsn, cum) > 0 && diff32(tsn, firstStart) < 0 {
				a.missCounts[tsn]++
				if a.missCounts[tsn] >= 3 {
					delete(a.missCounts, tsn)
					packets = append(packets, a.packet(a.peerTag, dataChunkBytes(c)))
					c.retransmits++
					c.lastSentMs = nowMs
				}
			}
		}
	}
	packets = append(packets, a.flushQueue(nowMs)...)
	return packets
}

func (a *Association) advanceOutCum() {
	for {
		next := a.outCumDone + 1
		if next == a.nextTsn {
			return
		}
		if _, ok := a.unacked[next]; ok {
			return
		}
		a.outCumDone = next
	}
}

// Tick drives retransmission timers; returns packets to transmit.
func (a *Association) Tick(nowMs int64) ([][]byte, []SctpEvent) {
	var packets [][]byte
	var events []SctpEvent
	if (a.state == "cookie-wait" || a.state == "cookie-echoed") && nowMs-a.lastInitMs >= a.rtoMs {
		a.lastInitMs = nowMs
		if a.state == "cookie-wait" {
			packets = append(packets, a.packet(0, sctpChunk(SctpChunkInit, 0, a.initBody())))
		} else {
			packets = append(packets, a.packet(a.peerTag, sctpChunk(SctpChunkCookieEcho, 0, a.pendingCookie)))
		}
	}
	if a.state == "established" {
		abandonedAny := false
		var toRetransmit []*outChunk
		for _, tsn := range sortedUnackedTsns(a) {
			c := a.unacked[tsn]
			expired := nowMs-c.lastSentMs >= a.rtoMs
			lifetimeOut := c.opts.MaxLifetimeMs != nil && nowMs-c.bornMs > *c.opts.MaxLifetimeMs
			budgetOut := expired && c.opts.MaxRetransmits != nil && c.retransmits >= *c.opts.MaxRetransmits
			if lifetimeOut || budgetOut {
				delete(a.unacked, tsn)
				a.inflightBytes -= len(c.payload)
				if a.inflightBytes < 0 {
					a.inflightBytes = 0
				}
				if !c.opts.Unordered {
					a.abandonedOrdered = append(a.abandonedOrdered, [2]uint16{c.stream, c.ssn})
				}
				abandonedAny = true
			} else if expired {
				toRetransmit = append(toRetransmit, c)
			}
		}
		if abandonedAny {
			a.advanceOutCum()
			var body []byte
			var cumBytes [4]byte
			binary.BigEndian.PutUint32(cumBytes[:], a.outCumDone)
			body = append(body, cumBytes[:]...)
			for _, pair := range a.abandonedOrdered {
				var b [4]byte
				binary.BigEndian.PutUint16(b[0:2], pair[0])
				binary.BigEndian.PutUint16(b[2:4], pair[1])
				body = append(body, b[:]...)
			}
			a.abandonedOrdered = nil
			packets = append(packets, a.packet(a.peerTag, sctpChunk(SctpChunkForwardTsn, 0, body)))
		}
		if len(toRetransmit) > 0 {
			// RFC 9260 section 6.2: a retransmit timeout collapses cwnd.
			a.ssthresh = a.cwnd / 2
			if a.ssthresh < 4*maxDataPayload {
				a.ssthresh = 4 * maxDataPayload
			}
			a.cwnd = maxDataPayload
		}
		for _, c := range toRetransmit {
			packets = append(packets, a.packet(a.peerTag, dataChunkBytes(c)))
			c.retransmits++
			c.lastSentMs = nowMs
		}
		packets = append(packets, a.flushOut(nowMs)...)
		if nowMs-a.lastPacketOutMs >= 30000 {
			a.lastPacketOutMs = nowMs
			info := make([]byte, 8)
			binary.BigEndian.PutUint64(info, uint64(nowMs))
			packets = append(packets, a.packet(a.peerTag, sctpChunk(SctpChunkHeartbeat, 0, sctpParam(1, info))))
		}
	}
	return packets, events
}

// Close begins shutdown, returning the SHUTDOWN packet if established.
func (a *Association) Close(nowMs int64) [][]byte {
	_ = nowMs
	if a.state != "established" {
		return nil
	}
	a.state = "shutdown-sent"
	body := make([]byte, 4)
	binary.BigEndian.PutUint32(body, a.peerCumTsn)
	return [][]byte{a.packet(a.peerTag, sctpChunk(SctpChunkShutdown, 0, body))}
}
