package grpcdc

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

// Golden frame vectors from ../fixtures/vectors.json, authored by the
// Racket codec; every runtime asserts the same bytes.
type vectorsFile struct {
	Frames []struct {
		Name        string `json:"name"`
		Type        int    `json:"type"`
		Stream      uint32 `json:"stream"`
		PayloadUTF8 string `json:"payload_utf8"`
		PayloadHex  string `json:"payload_hex"`
		Hex         string `json:"hex"`
	} `json:"frames"`
	Protobuf struct {
		EchoRequest struct {
			Message string `json:"message"`
			Count   int32  `json:"count"`
			Hex     string `json:"hex"`
		} `json:"echo_request"`
	} `json:"protobuf"`
}

func loadVectors(t *testing.T) vectorsFile {
	t.Helper()
	raw, err := os.ReadFile("../fixtures/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v vectorsFile
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestGoldenFrames(t *testing.T) {
	for _, f := range loadVectors(t).Frames {
		var payload []byte
		if f.PayloadHex != "" {
			payload, _ = hex.DecodeString(f.PayloadHex)
		} else {
			payload = []byte(f.PayloadUTF8)
		}
		want, _ := hex.DecodeString(f.Hex)
		got, err := EncodeFrame(FrameType(f.Type), f.Stream, payload)
		if err != nil {
			t.Fatalf("%s: encode: %v", f.Name, err)
		}
		if string(got) != string(want) {
			t.Errorf("%s: encode = %x, want %x", f.Name, got, want)
		}
		frameType, stream, decoded, err := DecodeFrame(want)
		if err != nil {
			t.Fatalf("%s: decode: %v", f.Name, err)
		}
		if int(frameType) != f.Type || stream != f.Stream || string(decoded) != string(payload) {
			t.Errorf("%s: decode mismatch: type=%d stream=%d payload=%q",
				f.Name, frameType, stream, decoded)
		}
	}
}

func TestStatusNames(t *testing.T) {
	if CodeOk.Name() != "OK" || CodeInvalidArgument.Name() != "INVALID-ARGUMENT" {
		t.Fatalf("unexpected names: %q %q", CodeOk.Name(), CodeInvalidArgument.Name())
	}
	err := NewStatus(CodeUnavailable, "gone")
	if err.Error() != "UNAVAILABLE: gone" {
		t.Fatalf("unexpected error string: %q", err.Error())
	}
}
