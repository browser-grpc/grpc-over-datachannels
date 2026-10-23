// Direct DTLS connection-id check: two stacks negotiate
// RFC 9146 cids (different lengths per direction) and move
// data over the resulting channel.
package dcwebrtc

import (
	"bytes"
	"testing"
	"time"
)

func TestDtlsWithConnectionIds(t *testing.T) {
	ab := make(chan []byte, 256)
	ba := make(chan []byte, 256)
	clientIO := &chanIO{in: ba, out: ab}
	serverIO := &chanIO{in: ab, out: ba}
	clientCert, err := GenerateCertificate()
	if err != nil {
		t.Fatal(err)
	}
	serverCert, err := GenerateCertificate()
	if err != nil {
		t.Fatal(err)
	}
	type res struct {
		conn *DtlsConnection
		err  error
	}
	results := make(chan res, 2)
	go func() {
		conn, err := DtlsAccept(serverIO, DtlsConfig{
			Certificate:            serverCert,
			RequirePeerCertificate: true,
			ConnectionID:           []byte{9, 9, 9, 9, 9, 9},
		})
		results <- res{conn, err}
	}()
	go func() {
		conn, err := DtlsConnect(clientIO, DtlsConfig{
			Certificate:  clientCert,
			ConnectionID: []byte{7, 7, 7, 7},
		})
		results <- res{conn, err}
	}()
	var conns []*DtlsConnection
	for i := 0; i < 2; i++ {
		select {
		case r := <-results:
			if r.err != nil {
				t.Fatalf("handshake: %v", r.err)
			}
			conns = append(conns, r.conn)
		case <-time.After(20 * time.Second):
			t.Fatal("handshake timed out")
		}
	}
	// ends[0]/ends[1] in completion order; echo both ways.
	for _, pair := range [][2]int{{0, 1}, {1, 0}} {
		if err := conns[pair[0]].SendApp([]byte("ping")); err != nil {
			t.Fatal(err)
		}
		got, err := conns[pair[1]].RecvAppTimeout(5000)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, []byte("ping")) {
			t.Fatalf("echo mismatch: %q", got)
		}
	}
}
