package echo

// OTLP/JSON exporter as an example span observer (not in the
// runtime). The generated runtimes stay dependency-free and
// SDK-free; this example shows the hooks are sufficient for a
// real backend. Ended spans are buffered and POSTed as
// OTLP/JSON to an OpenTelemetry collector (default
// http://localhost:4318/v1/traces) with net/http. Export
// failures are swallowed: tracing must never break the call.
//
// Usage:
//
//	tracer := NewOtlpTracer("echo-client", "")
//	grpcdc.SetTracer(tracer)
//	... make calls ...
//	tracer.Flush()

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"
)

// OtlpTracer buffers ended spans and exports them in batches.
type OtlpTracer struct {
	Endpoint    string
	ServiceName string
	BatchSize   int
	Client      *http.Client

	mu    sync.Mutex
	open  map[string]*otlpSpan
	ended []*otlpSpan
}

type otlpSpan struct {
	TraceID           string          `json:"traceId"`
	SpanID            string          `json:"spanId"`
	ParentSpanID      string          `json:"parentSpanId,omitempty"`
	Name              string          `json:"name"`
	Kind              int             `json:"kind"`
	StartTimeUnixNano string          `json:"startTimeUnixNano"`
	EndTimeUnixNano   string          `json:"endTimeUnixNano,omitempty"`
	Attributes        []otlpAttribute `json:"attributes"`
	Status            *otlpStatus     `json:"status,omitempty"`
	started           time.Time
}

type otlpAttribute struct {
	Key   string          `json:"key"`
	Value otlpStringValue `json:"value"`
}

type otlpStringValue struct {
	StringValue string `json:"stringValue"`
}

type otlpStatus struct {
	Code    int    `json:"code"`
	Message string `json:"message,omitempty"`
}

// NewOtlpTracer creates a tracer; empty endpoint uses the
// default OTLP/HTTP traces endpoint.
func NewOtlpTracer(serviceName, endpoint string) *OtlpTracer {
	if endpoint == "" {
		endpoint = "http://localhost:4318/v1/traces"
	}
	if serviceName == "" {
		serviceName = "grpcdc"
	}
	return &OtlpTracer{
		Endpoint:    endpoint,
		ServiceName: serviceName,
		BatchSize:   32,
		Client:      &http.Client{Timeout: 5 * time.Second},
		open:        map[string]*otlpSpan{},
	}
}

func otlpKind(kind string) int {
	switch kind {
	case "client":
		return 3
	case "server":
		return 2
	default:
		return 1
	}
}

func (t *OtlpTracer) OnStart(kind, method, traceID, spanID, parentSpanID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.open[spanID] = &otlpSpan{
		TraceID:           traceID,
		SpanID:            spanID,
		ParentSpanID:      parentSpanID,
		Name:              method,
		Kind:              otlpKind(kind),
		StartTimeUnixNano: formatUnixNano(time.Now()),
		Attributes:        []otlpAttribute{{Key: "grpcdc.kind", Value: otlpStringValue{StringValue: kind}}},
		started:           time.Now(),
	}
}

func (t *OtlpTracer) OnEnd(kind, method, traceID, spanID, status string, durationMs float64) {
	t.mu.Lock()
	span := t.open[spanID]
	if span == nil {
		t.mu.Unlock()
		return
	}
	delete(t.open, spanID)
	span.EndTimeUnixNano = formatUnixNano(span.started.Add(time.Duration(durationMs * float64(time.Millisecond))))
	if status == "OK" {
		span.Status = &otlpStatus{Code: 1}
	} else {
		span.Status = &otlpStatus{Code: 2, Message: status}
	}
	t.ended = append(t.ended, span)
	flush := len(t.ended) >= t.BatchSize
	t.mu.Unlock()
	if flush {
		t.Flush()
	}
}

func formatUnixNano(t time.Time) string {
	return strings.TrimSpace(strings.Replace(
		jsonNumber(t.UnixNano()), " ", "", -1))
}

func jsonNumber(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}

// Payload renders the buffered ended spans as an OTLP/JSON
// ExportTraceServiceRequest and clears the buffer.
func (t *OtlpTracer) Payload() []byte {
	t.mu.Lock()
	spans := t.ended
	t.ended = nil
	t.mu.Unlock()
	if len(spans) == 0 {
		return nil
	}
	type resourceSpans struct {
		Resource struct {
			Attributes []otlpAttribute `json:"attributes"`
		} `json:"resource"`
		ScopeSpans []struct {
			Spans []*otlpSpan `json:"spans"`
		} `json:"scopeSpans"`
	}
	rs := resourceSpans{}
	rs.Resource.Attributes = []otlpAttribute{
		{Key: "service.name", Value: otlpStringValue{StringValue: t.ServiceName}},
	}
	rs.ScopeSpans = []struct {
		Spans []*otlpSpan `json:"spans"`
	}{{Spans: spans}}
	payload, _ := json.Marshal(struct {
		ResourceSpans []resourceSpans `json:"resourceSpans"`
	}{ResourceSpans: []resourceSpans{rs}})
	return payload
}

// Flush POSTs any buffered spans; errors are swallowed.
func (t *OtlpTracer) Flush() {
	payload := t.Payload()
	if payload == nil {
		return
	}
	req, err := http.NewRequest(http.MethodPost, t.Endpoint, bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := t.Client.Do(req)
	if err != nil {
		return
	}
	_ = resp.Body.Close()
}
