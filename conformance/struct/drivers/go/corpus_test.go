package shapes

import (
	"bytes"
	"encoding/hex"
	"os"
	"testing"
)

func TestStructCorpus(t *testing.T) {
	golden, err := hex.DecodeString(os.Getenv("STRUCT_GOLDEN_HEX"))
	if err != nil {
		t.Fatal(err)
	}
	m := &Outer{
		Inner:  &Inner{V: "x", N: -3},
		Hue:    Hue_RED,
		Nums:   []int32{1, -2, 300},
		ByName: map[string]*Inner{"b": {V: "second"}, "a": {V: "first", N: 9}},
		S:      "picked",
		Blob:   []byte{1, 2, 3},
		Names:  []string{"n1", "n2"},
		Inners: []*Inner{{V: "i1"}, {V: "i2"}, {V: "i3"}},
		ById:   map[int32]string{7: "seven", 2: "two"},
		Score:  3.5, Ratio: 0.25, Flag: true, Stamp: 123456789, Delta: -77,
	}
	if got := m.MarshalStructDC(); !bytes.Equal(got, golden) {
		t.Fatalf("marshal mismatch:\n got %x\nwant %x", got, golden)
	}
	rt := &Outer{}
	if err := rt.UnmarshalStructDC(golden); err != nil || !bytes.Equal(rt.MarshalStructDC(), golden) {
		t.Fatal("decode/roundtrip failed", err)
	}
	t.Log("PASS go")
}
