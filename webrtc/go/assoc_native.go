//go:build !dc_sctp

package dcwebrtc

// Default SCTP backend: the mirrored Go stack.
func newSctpAssoc(isClient bool) sctpAssoc {
	if isClient {
		return NewClientAssociation(SctpPort, SctpPort)
	}
	return NewServerAssociation(SctpPort, SctpPort)
}
