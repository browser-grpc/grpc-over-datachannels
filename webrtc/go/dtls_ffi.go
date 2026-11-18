//go:build dc_dtls

package dcwebrtc

import (
	"errors"
	"fmt"
	"time"

	"github.com/browser-grpc/grpc-over-datachannels/webrtc/go/dtlsffi"
)

// DTLS backend under the dc_dtls tag: the shared Rust core
// (crates/dc-dtls-ffi) instead of the mirrored Go stack.
// The core is sans-io; this seam pumps it over the same
// PacketIO the native handshake drives, then serves the
// established phase through EncryptApp/HandleApp.

type ffiDtls struct {
	conn *dtlsffi.Connection
	io   PacketIO
	t0   time.Time
}

func (f *ffiDtls) nowMs() uint64 {
	return uint64(time.Since(f.t0) / time.Millisecond)
}

func ffiDtlsConfig(config DtlsConfig) (dtlsffi.Config, error) {
	if config.Certificate == nil || config.Certificate.PrivateKey == nil {
		return dtlsffi.Config{}, errors.New("dtlsffi: certificate with private key required")
	}
	scalar := make([]byte, 32)
	config.Certificate.PrivateKey.D.FillBytes(scalar)
	return dtlsffi.Config{
		CertDER:                config.Certificate.DER,
		KeyScalar:              scalar,
		ExpectedFingerprint:    config.ExpectedPeerFingerprint,
		RequirePeerCertificate: config.RequirePeerCertificate,
		ConnectionID:           config.ConnectionID,
		PairHint:               config.PairHint,
	}, nil
}

func (f *ffiDtls) sendAll(packets [][]byte) error {
	for _, p := range packets {
		if err := f.io.Send(p); err != nil {
			return err
		}
	}
	return nil
}

// handshake pumps the core until established: send the
// initial flight, then alternate Recv (bounded by the
// core's next timeout) and Tick.
func (f *ffiDtls) handshake() error {
	flights, err := f.conn.Start()
	if err != nil {
		return err
	}
	if err := f.sendAll(flights); err != nil {
		return err
	}
	deadline := time.Now().Add(30 * time.Second)
	for !f.conn.Established() {
		if time.Now().After(deadline) {
			return errors.New("dtlsffi: handshake timed out")
		}
		timeout := f.conn.NextTimeout(f.nowMs())
		if timeout < 0 {
			if msg := f.conn.Failure(); msg != "" {
				return fmt.Errorf("dtlsffi: handshake failed: %s", msg)
			}
			return errors.New("dtlsffi: handshake failed")
		}
		packet := f.io.Recv(int(timeout))
		var out [][]byte
		if packet != nil {
			out, err = f.conn.HandleDatagram(packet, f.nowMs())
		} else {
			out, err = f.conn.Tick(f.nowMs())
		}
		if err != nil {
			return err
		}
		if err := f.sendAll(out); err != nil {
			return err
		}
	}
	return nil
}

func newFfiDtls(io PacketIO, config DtlsConfig, server bool) (dtlsConn, error) {
	cfg, err := ffiDtlsConfig(config)
	if err != nil {
		return nil, err
	}
	f := &ffiDtls{io: io, t0: time.Now()}
	if server {
		f.conn, err = dtlsffi.NewServer(cfg, 0)
	} else {
		f.conn, err = dtlsffi.NewClient(cfg, 0)
	}
	if err != nil {
		return nil, err
	}
	if err := f.handshake(); err != nil {
		f.conn.Close()
		return nil, err
	}
	return f, nil
}

func newDtlsClient(io PacketIO, config DtlsConfig) (dtlsConn, error) {
	return newFfiDtls(io, config, false)
}

func newDtlsServer(io PacketIO, config DtlsConfig) (dtlsConn, error) {
	return newFfiDtls(io, config, true)
}

// SendApp seals and sends one application record.
func (f *ffiDtls) SendApp(data []byte) error {
	record, err := f.conn.EncryptApp(data)
	if err != nil {
		return err
	}
	return f.io.Send(record)
}

// RecvAppTimeout returns one application payload, nil on
// timeout; non-app records are skipped like the native
// stack skips them.
func (f *ffiDtls) RecvAppTimeout(timeoutMs int) ([]byte, error) {
	deadline := time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)
	for {
		remaining := int(time.Until(deadline) / time.Millisecond)
		if remaining <= 0 {
			return nil, nil
		}
		packet := f.io.Recv(remaining)
		if packet == nil {
			return nil, nil
		}
		payload, err := f.conn.HandleApp(packet)
		if errors.Is(err, dtlsffi.ErrNoData) {
			continue
		}
		if err != nil {
			return nil, err
		}
		return payload, nil
	}
}

// PeerFingerprint returns the peer certificate's SDP
// fingerprint from the core.
func (f *ffiDtls) PeerFingerprint() string {
	return f.conn.PeerFingerprint()
}
