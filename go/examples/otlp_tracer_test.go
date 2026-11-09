package echo

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestOtlpTracerPayload(t *testing.T) {
	tracer := NewOtlpTracer("svc", "")
	tracer.OnStart("client", "/echo.Echo/Unary",
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "")
	tracer.OnEnd("client", "/echo.Echo/Unary",
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "OK", 1.5)

	payload := tracer.Payload()
	if payload == nil {
		t.Fatal("empty payload")
	}
	text := string(payload)
	for _, want := range []string{
		`"service.name"`, `"stringValue":"svc"`,
		`"traceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`,
		`"kind":3`, `"code":1`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("payload missing %s: %s", want, text)
		}
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, ok := decoded["resourceSpans"]; !ok {
		t.Fatalf("no resourceSpans: %s", text)
	}
	if again := tracer.Payload(); again != nil {
		t.Fatal("buffer not cleared")
	}
}
