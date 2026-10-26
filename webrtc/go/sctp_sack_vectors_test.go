package dcwebrtc

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// Phase 3 conformance vectors (fixtures/sctp_vectors.json,
// sack_scenarios): all three mirrored SCTP stacks run the same
// SACK/gap/retransmit scenarios against the generated tracker.
// Thin interpreter only — scenarios are generated data.

type sackVectorFile struct {
	SackScenarios []struct {
		Name       string `json:"name"`
		InitialCum uint32 `json:"initial_cum"`
		Steps      []struct {
			Recv *uint32 `json:"recv"`
			Gaps [][2]uint16 `json:"gaps"`
			Sack *struct {
				Cum     uint32      `json:"cum"`
				Blocks  [][2]uint16 `json:"blocks"`
				Unacked []uint32    `json:"unacked"`
			} `json:"sack"`
			Acked      []uint32 `json:"acked"`
			Retransmit []uint32 `json:"retransmit"`
		} `json:"steps"`
	} `json:"sack_scenarios"`
}

func TestSctpSackVectors(t *testing.T) {
	raw, err := os.ReadFile("../../fixtures/sctp_vectors.json")
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}
	var file sackVectorFile
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatalf("parse vectors: %v", err)
	}
	if len(file.SackScenarios) == 0 {
		t.Fatal("no sack scenarios")
	}
	for _, sc := range file.SackScenarios {
		t.Run(sc.Name, func(t *testing.T) {
			tracker := newSackTracker(sc.InitialCum)
			for i, step := range sc.Steps {
				if step.Recv != nil {
					tracker.noteReceived(*step.Recv)
					if got := tracker.gapBlocks(); !reflect.DeepEqual(got, step.Gaps) && !(len(got) == 0 && len(step.Gaps) == 0) {
						t.Fatalf("step %d: gapBlocks = %v, want %v", i, got, step.Gaps)
					}
				}
				if step.Sack != nil {
					acked, retransmit := tracker.noteSack(step.Sack.Cum, step.Sack.Blocks, step.Sack.Unacked)
					if !reflect.DeepEqual(acked, step.Acked) && !(len(acked) == 0 && len(step.Acked) == 0) {
						t.Fatalf("step %d: acked = %v, want %v", i, acked, step.Acked)
					}
					if !reflect.DeepEqual(retransmit, step.Retransmit) && !(len(retransmit) == 0 && len(step.Retransmit) == 0) {
						t.Fatalf("step %d: retransmit = %v, want %v", i, retransmit, step.Retransmit)
					}
				}
			}
		})
	}
}
