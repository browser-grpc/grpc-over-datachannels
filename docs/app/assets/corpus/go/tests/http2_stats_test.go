package grpcdc_test

// HTTP/2 leg counters for LinkStats (Go): Http2Transport
// counts frames written/parsed and HEADERS streams over a
// live call. The server is a minimal manual HTTP/2 responder
// (SETTINGS handshake, indexed :status HEADERS, one DATA
// message, literal trailers) — enough for the generated
// transport to complete one unary call.

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

func h2Frame(ftype byte, streamID uint32, flags byte, payload []byte) []byte {
	out := []byte{byte(len(payload) >> 16), byte(len(payload) >> 8), byte(len(payload)), ftype, flags,
		byte(streamID >> 24), byte(streamID >> 16), byte(streamID >> 8), byte(streamID)}
	return append(out, payload...)
}

func TestHttp2StatsFillOnLiveCall(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		preface := make([]byte, 24)
		if _, err := io.ReadFull(conn, preface); err != nil {
			return
		}
		header := make([]byte, 9)
		readFrame := func() (byte, uint32, byte, []byte, error) {
			if _, err := io.ReadFull(conn, header); err != nil {
				return 0, 0, 0, nil, err
			}
			length := int(header[0])<<16 | int(header[1])<<8 | int(header[2])
			payload := make([]byte, length)
			_, err := io.ReadFull(conn, payload)
			return header[3], binary.BigEndian.Uint32(header[5:9]) & 0x7fffffff, header[4], payload, err
		}
		// Client SETTINGS.
		if _, _, _, _, err := readFrame(); err != nil {
			return
		}
		_, _ = conn.Write(h2Frame(4, 0, 0, nil)) // SETTINGS
		_, _ = conn.Write(h2Frame(4, 0, 1, nil)) // SETTINGS ACK
		var streamID uint32
		for {
			ftype, id, flags, _, err := readFrame()
			if err != nil {
				return
			}
			switch ftype {
			case 4: // SETTINGS (ack from client) / WINDOW_UPDATE etc.
				if flags&0x1 == 0 {
					_, _ = conn.Write(h2Frame(4, 0, 1, nil))
				}
			case 0, 8: // DATA / WINDOW_UPDATE: wait for END_STREAM on DATA
				if ftype == 0 && flags&0x1 != 0 {
					streamID = id
					// :status 200 (indexed field 8).
					_, _ = conn.Write(h2Frame(1, streamID, 0x4, []byte{0x88}))
					resp := (&echo.EchoResponse{Message: "echo: hi"}).MarshalDC()
					lpm := append([]byte{0, 0, 0, 0, byte(len(resp))}, resp...)
					_, _ = conn.Write(h2Frame(0, streamID, 0, lpm))
					// Trailers: literal grpc-status: 0.
					block := []byte{0x00, 11}
					block = append(block, "grpc-status"...)
					block = append(block, 1, '0')
					_, _ = conn.Write(h2Frame(1, streamID, 0x5, block))
					return
				}
			case 1: // HEADERS without END_STREAM: keep reading for DATA
				streamID = id
			}
		}
	}()

	transport, err := grpcdc.DialHttp2(fmt.Sprintf("127.0.0.1:%d", ln.Addr().(*net.TCPAddr).Port), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer transport.Close()
	channel := grpcdc.NewChannel(transport)
	client := echo.NewEchoClient(channel)
	resp, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "hi"})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hi" {
		t.Fatalf("resp = %q", resp.Message)
	}
	stats := transport.Stats()
	if stats.StreamsOpened < 1 || stats.FramesSent < 2 || stats.FramesReceived < 2 {
		t.Fatalf("stats not filled: %+v", stats)
	}
}
