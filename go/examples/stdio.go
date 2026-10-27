package echo

import (
	"encoding/binary"
	"io"
	"sync"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
)

// StdioTransport frames DataChannel messages over a byte stream with
// a 4-byte big-endian length prefix (the prefix exists only to frame
// messages on stdio; each framed unit is exactly one DataChannel
// message). Used by the cross-language interop harnesses.
type StdioTransport struct {
	// OnEOF, when set, fires once when the read side reaches EOF —
	// harness mains use it to exit when their driver goes away.
	OnEOF func()

	writer  io.Writer
	reader  io.Reader
	mu      sync.Mutex
	eofOnce sync.Once
}

// NewStdioTransport builds a transport over rw (e.g. os.Stdout/os.Stdin
// split across two values — pass the same file for both if desired).
func NewStdioTransport(writer io.Writer, reader io.Reader) *StdioTransport {
	return &StdioTransport{writer: writer, reader: reader}
}

// Send writes one framed message.
func (t *StdioTransport) Send(data []byte) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(data)))
	if _, err := t.writer.Write(header[:]); err != nil {
		return grpcdc.NewStatus(grpcdc.CodeUnavailable, "stdio write: "+err.Error())
	}
	if _, err := t.writer.Write(data); err != nil {
		return grpcdc.NewStatus(grpcdc.CodeUnavailable, "stdio write: "+err.Error())
	}
	return nil
}

// Recv reads one framed message.
func (t *StdioTransport) Recv() ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(t.reader, header[:]); err != nil {
		if t.OnEOF != nil {
			t.eofOnce.Do(t.OnEOF)
		}
		return nil, err
	}
	buf := make([]byte, binary.BigEndian.Uint32(header[:]))
	if _, err := io.ReadFull(t.reader, buf); err != nil {
		return nil, err
	}
	return buf, nil
}
