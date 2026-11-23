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

func TestStructCorpusP2(t *testing.T) {
	golden, err := hex.DecodeString(os.Getenv("STRUCT_GOLDEN2_HEX"))
	if err != nil {
		t.Fatal(err)
	}
	m := NewP2()
	m.Name = "req"
	m.Count = 42 // explicitly the default value
	m.Greeting = "hi"
	m.Enabled = false
	m.Ratio = 2.5
	m.Nums = []int32{5, -6}
	m.ExtNote = "note!"
	if len(golden) == 0 {
		t.Fatalf("golden2: %x", m.MarshalStructDC())
	}
	if got := m.MarshalStructDC(); !bytes.Equal(got, golden) {
		t.Fatalf("marshal mismatch:\n got %x\nwant %x", got, golden)
	}
	// Decode into the zero value (not NewP2): applying proto2
	// defaults at decode would manufacture presence the struct
	// bytes do not carry (e.g. enabled=true).
	rt := &P2{}
	if err := rt.UnmarshalStructDC(golden); err != nil || !bytes.Equal(rt.MarshalStructDC(), golden) {
		t.Fatal("decode/roundtrip failed", err)
	}
	t.Log("PASS go p2")
}
