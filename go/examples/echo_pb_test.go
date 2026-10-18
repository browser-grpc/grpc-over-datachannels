package echo

import (
	"encoding/hex"
	"reflect"
	"testing"
)

// Golden protobuf bytes (fixtures/vectors.json, asserted by every
// runtime): EchoRequest{message:"hi", count:2} == 0a0268691002.
func TestEchoRequestGoldenBytes(t *testing.T) {
	msg := &EchoRequest{Message: "hi", Count: 2}
	if got := hex.EncodeToString(msg.MarshalDC()); got != "0a0268691002" {
		t.Fatalf("encode = %s, want 0a0268691002", got)
	}
	var decoded EchoRequest
	raw, _ := hex.DecodeString("0a0268691002")
	if err := decoded.UnmarshalDC(raw); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decoded, *msg) {
		t.Fatalf("decode = %+v, want %+v", decoded, *msg)
	}
}
