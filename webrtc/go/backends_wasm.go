//go:build js && wasm

package dcwebrtc

import (
	"errors"
	"net"
	"sync"
	"time"
)

// Stubs for js/wasm: the Rust cores are cgo, so the Go
// WebRTC stack cannot run in a browser. Browser hosts
// use the Rust bridge (crates/dc-bridge-wasm) instead;
// these definitions only keep the package (and its
// importers in the go client module) compiling for
// GOOS=js. Calling them is a programming error there.

var errWasmBackend = errors.New("dcwebrtc: Rust-core backends are unavailable on js/wasm; use the browser bridge")

type wasmAssoc struct{}

func newSctpAssoc(bool) sctpAssoc { return wasmAssoc{} }

func (wasmAssoc) Connect(int64) []byte { panic(errWasmBackend) }
func (wasmAssoc) SendData(uint16, uint32, []byte, SendOptions, int64) [][]byte {
	panic(errWasmBackend)
}
func (wasmAssoc) HandlePacket([]byte, int64) ([][]byte, []SctpEvent) { panic(errWasmBackend) }
func (wasmAssoc) Tick(int64) ([][]byte, []SctpEvent)                  { panic(errWasmBackend) }
func (wasmAssoc) Stats() AssociationStats                             { return AssociationStats{} }
func (wasmAssoc) CloseStream(uint16) [][]byte                         { panic(errWasmBackend) }
func (wasmAssoc) Close(int64) [][]byte                                { panic(errWasmBackend) }
func (wasmAssoc) IsEstablished() bool                                 { return false }

// DtlsConnect is unavailable on js/wasm (see above).
func DtlsConnect(PacketIO, DtlsConfig) (DtlsConn, error) { return nil, errWasmBackend }

// DtlsAccept is unavailable on js/wasm (see above).
func DtlsAccept(PacketIO, DtlsConfig) (DtlsConn, error) { return nil, errWasmBackend }

// IceAgent stub (see file header).
type IceAgent struct {
	LocalUfrag  string
	LocalPwd    string
	RemoteUfrag string
	RemotePwd   string

	LocalCandidates  []Candidate
	RemoteCandidates []Candidate
	Nominated        *net.UDPAddr

	mu sync.Mutex
}

// NewIceAgent builds a stub agent (js/wasm only).
func NewIceAgent(bool) *IceAgent { return &IceAgent{} }

// Controlling reports the stub role.
func (a *IceAgent) Controlling() bool { return false }

// SetControlling is a no-op on the stub.
func (a *IceAgent) SetControlling(bool) {}

// SetRemote records the remote description on the stub.
func (a *IceAgent) SetRemote(ufrag, pwd string, candidates []Candidate) {
	a.RemoteUfrag = ufrag
	a.RemotePwd = pwd
	a.RemoteCandidates = candidates
}

// Restart is a no-op on the stub.
func (a *IceAgent) Restart() {}

// Generation is always 0 on the stub.
func (a *IceAgent) Generation() int { return 0 }

// Renominated is always false on the stub.
func (a *IceAgent) Renominated() bool { return false }

// NominatedAddr is always nil on the stub.
func (a *IceAgent) NominatedAddr() *net.UDPAddr { return nil }

// AddRemoteCandidate records the candidate on the stub.
func (a *IceAgent) AddRemoteCandidate(c Candidate) bool {
	a.RemoteCandidates = append(a.RemoteCandidates, c)
	return true
}

// DueChecks returns no checks on the stub.
func (a *IceAgent) DueChecks() []Check { panic(errWasmBackend) }

// HandleStun returns nothing on the stub.
func (a *IceAgent) HandleStun([]byte, *net.UDPAddr) ([]StunResponse, []IceEvent) {
	panic(errWasmBackend)
}

// ConsentCheck returns no check on the stub.
func (a *IceAgent) ConsentCheck() (Check, bool) { return Check{}, false }

// TouchConsent is a no-op on the stub.
func (a *IceAgent) TouchConsent() {}

// ConsentExpired is always false on the stub.
func (a *IceAgent) ConsentExpired(time.Duration) bool { return false }
