package dcwebrtc

import (
	"testing"
	"time"
)

type chanIO struct {
	in  chan []byte
	out chan []byte
}

func (c *chanIO) Send(b []byte) error {
	cp := make([]byte, len(b))
	copy(cp, b)
	c.out <- cp
	return nil
}

func (c *chanIO) Recv(timeoutMs int) []byte {
	select {
	case m := <-c.in:
		return m
	case <-time.After(time.Duration(timeoutMs) * time.Millisecond):
		return nil
	}
}

func TestDtlsLoopbackPair(t *testing.T) {
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
		role string
	}
	results := make(chan res, 2)
	go func() {
		conn, err := DtlsAccept(serverIO, DtlsConfig{Certificate: serverCert, RequirePeerCertificate: true})
		results <- res{conn, err, "server"}
	}()
	go func() {
		conn, err := DtlsConnect(clientIO, DtlsConfig{Certificate: clientCert})
		results <- res{conn, err, "client"}
	}()
	var conns []*DtlsConnection
	for i := 0; i < 2; i++ {
		select {
		case r := <-results:
			if r.err != nil {
				t.Fatalf("%s: %v", r.role, r.err)
			}
			t.Logf("%s ok, srtp=%d", r.role, r.conn.SrtpProfile())
			conns = append(conns, r.conn)
		case <-time.After(20 * time.Second):
			t.Fatal("timeout")
		}
	}
}
