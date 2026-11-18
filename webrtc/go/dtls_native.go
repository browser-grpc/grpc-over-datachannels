//go:build dc_native

package dcwebrtc

// DTLS backend by default: the mirrored Go stack
// (dtls.go). DtlsConnection already satisfies dtlsConn.

func newDtlsClient(io PacketIO, config DtlsConfig) (dtlsConn, error) {
	return DtlsConnect(io, config)
}

func newDtlsServer(io PacketIO, config DtlsConfig) (dtlsConn, error) {
	return DtlsAccept(io, config)
}
