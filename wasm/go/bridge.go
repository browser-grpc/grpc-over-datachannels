//go:build js && wasm

// Bridge runtime for the generated WASM client facades: awaits JS
// promises from the grpc-dc JS bridge (js/src/wasm_bridge.js) and
// moves protobuf bytes across the boundary as Uint8Array. The JS
// implementation owns the wire; this file owns only the interop.

package echowasm

import (
	"fmt"
	"syscall/js"
)

// StatusError mirrors the JS StatusError shape ({code, message}).
type StatusError struct {
	Code    int
	Message string
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("grpc status %d: %s", e.Code, e.Message)
}

func statusFromJS(v js.Value) error {
	if v.Type() == js.TypeObject {
		code := v.Get("code")
		message := v.Get("message")
		if code.Type() == js.TypeNumber {
			text := ""
			if message.Type() == js.TypeString {
				text = message.String()
			}
			return &StatusError{Code: code.Int(), Message: text}
		}
		if v.Get("message").Type() == js.TypeString {
			return fmt.Errorf("%s", v.Get("message").String())
		}
	}
	return fmt.Errorf("js error: %s", v.String())
}

type promiseResult struct {
	value js.Value
	err   error
}

func await(promise js.Value) (js.Value, error) {
	done := make(chan promiseResult, 1)
	onOk := js.FuncOf(func(_ js.Value, args []js.Value) any {
		var v js.Value
		if len(args) > 0 {
			v = args[0]
		}
		done <- promiseResult{value: v}
		return nil
	})
	defer onOk.Release()
	onErr := js.FuncOf(func(_ js.Value, args []js.Value) any {
		var err error = fmt.Errorf("promise rejected")
		if len(args) > 0 {
			err = statusFromJS(args[0])
		}
		done <- promiseResult{err: err}
		return nil
	})
	defer onErr.Release()
	promise.Call("then", onOk, onErr)
	result := <-done
	return result.value, result.err
}

func uint8Array(b []byte) js.Value {
	array := js.Global().Get("Uint8Array").New(len(b))
	js.CopyBytesToJS(array, b)
	return array
}

func uint8ArrayList(payloads [][]byte) js.Value {
	array := js.Global().Get("Array").New(len(payloads))
	for i, p := range payloads {
		array.SetIndex(i, uint8Array(p))
	}
	return array
}

func bytesOf(v js.Value) []byte {
	out := make([]byte, v.Length())
	js.CopyBytesToGo(out, v)
	return out
}

// callUnary: bridge.unary(path, payload) -> Promise<Uint8Array>.
func callUnary(bridge js.Value, path string, payload []byte) ([]byte, error) {
	value, err := await(bridge.Call("unary", path, uint8Array(payload)))
	if err != nil {
		return nil, err
	}
	return bytesOf(value), nil
}

// bridgeOptions builds the JS bridge options object
// ({metadata, timeout, cancelAfter}); zero values are omitted.
func bridgeOptions(metadata map[string]string, timeoutMs int, cancelAfter int) js.Value {
	opts := js.Global().Get("Object").New()
	if len(metadata) > 0 {
		md := js.Global().Get("Object").New()
		for k, v := range metadata {
			md.Set(k, v)
		}
		opts.Set("metadata", md)
	}
	if timeoutMs > 0 {
		opts.Set("timeout", timeoutMs)
	}
	if cancelAfter > 0 {
		opts.Set("cancelAfter", cancelAfter)
	}
	return opts
}

// CallUnaryWithOptions is the exported options-aware unary call
// for facade entry points (metadata, deadline, raw paths): the
// generated stub covers the typed call shapes; this covers
// per-call options the stub does not take.
func CallUnaryWithOptions(bridge js.Value, path string, payload []byte, metadata map[string]string, timeoutMs int) ([]byte, error) {
	value, err := await(bridge.Call("unary", path, uint8Array(payload), bridgeOptions(metadata, timeoutMs, 0)))
	if err != nil {
		return nil, err
	}
	return bytesOf(value), nil
}

// CallServerStreamCancelAfter runs a server-streaming call that
// aborts after cancelAfter responses (the bridge breaks the
// iteration, tearing the call down) and reports how many
// responses were seen.
func CallServerStreamCancelAfter(bridge js.Value, path string, payload []byte, cancelAfter int, onPayload func([]byte) error) error {
	var firstErr error
	onMessage := js.FuncOf(func(_ js.Value, args []js.Value) any {
		if len(args) > 0 && firstErr == nil {
			firstErr = onPayload(bytesOf(args[0]))
		}
		return nil
	})
	defer onMessage.Release()
	_, err := await(bridge.Call("serverStream", path, uint8Array(payload), onMessage, bridgeOptions(nil, 0, cancelAfter)))
	if err != nil {
		return err
	}
	return firstErr
}

// callClientStream: bridge.clientStream(path, payloads) -> Promise<Uint8Array>.
func callClientStream(bridge js.Value, path string, payloads [][]byte) ([]byte, error) {
	value, err := await(bridge.Call("clientStream", path, uint8ArrayList(payloads)))
	if err != nil {
		return nil, err
	}
	return bytesOf(value), nil
}

// callStream: bridge[method](path, payload, onMessage) -> Promise<void>
// for server-streaming (a single request payload).
func callStream(bridge js.Value, method, path string, payload []byte, onPayload func([]byte) error) error {
	var firstErr error
	onMessage := js.FuncOf(func(_ js.Value, args []js.Value) any {
		if len(args) > 0 && firstErr == nil {
			firstErr = onPayload(bytesOf(args[0]))
		}
		return nil
	})
	defer onMessage.Release()
	_, err := await(bridge.Call(method, path, uint8Array(payload), onMessage))
	if err != nil {
		return err
	}
	return firstErr
}

// callStreamPayloads: bridge[method](path, payloads, onMessage) for bidi.
func callStreamPayloads(bridge js.Value, method, path string, payloads [][]byte, onPayload func([]byte) error) error {
	var firstErr error
	onMessage := js.FuncOf(func(_ js.Value, args []js.Value) any {
		if len(args) > 0 && firstErr == nil {
			firstErr = onPayload(bytesOf(args[0]))
		}
		return nil
	})
	defer onMessage.Release()
	_, err := await(bridge.Call(method, path, uint8ArrayList(payloads), onMessage))
	if err != nil {
		return err
	}
	return firstErr
}

// ---- server side: Register*Server in the generated stub hands
// typed handlers to the page's JS server bridge
// (createGrpcDcServerBridge); the JS Server owns the wire. ----

// ServerSink sends one response message on a server-streaming
// or bidi call.
type ServerSink struct {
	onMessage js.Value
}

// Send marshals and forwards one response payload.
func (s *ServerSink) Send(payload []byte) {
	s.onMessage.Invoke(uint8Array(payload))
}

func metadataPairsOf(v js.Value) [][2]string {
	n := v.Length()
	var out [][2]string
	for i := 0; i+1 < n; i += 2 {
		out = append(out, [2]string{v.Index(i).String(), v.Index(i + 1).String()})
	}
	return out
}

func payloadsOf(v js.Value) [][]byte {
	n := v.Length()
	out := make([][]byte, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, bytesOf(v.Index(i)))
	}
	return out
}

func statusObject(err error) js.Value {
	obj := js.Global().Get("Object").New()
	if se, ok := err.(*StatusError); ok {
		obj.Set("code", se.Code)
		obj.Set("message", se.Message)
	} else {
		obj.Set("code", 13)
		obj.Set("message", err.Error())
	}
	return obj
}

func promiseOf(fn func(resolve, reject js.Value)) js.Value {
	executor := js.FuncOf(func(_ js.Value, args []js.Value) any {
		fn(args[0], args[1])
		return nil
	})
	promise := js.Global().Get("Promise").New(executor)
	executor.Release()
	return promise
}

func registerUnaryHandler(bridge js.Value, path string, handler func([]byte, [][2]string) ([]byte, error)) {
	fn := js.FuncOf(func(_ js.Value, args []js.Value) any {
		payload := bytesOf(args[0])
		metadata := metadataPairsOf(args[1])
		return promiseOf(func(resolve, reject js.Value) {
			go func() {
				resp, err := handler(payload, metadata)
				if err != nil {
					reject.Invoke(statusObject(err))
					return
				}
				resolve.Invoke(uint8Array(resp))
			}()
		})
	})
	bridge.Call("registerUnary", path, fn)
}

func registerServerStreamHandler(bridge js.Value, path string, handler func([]byte, [][2]string, *ServerSink) error) {
	fn := js.FuncOf(func(_ js.Value, args []js.Value) any {
		payload := bytesOf(args[0])
		metadata := metadataPairsOf(args[1])
		sink := &ServerSink{onMessage: args[2]}
		return promiseOf(func(resolve, reject js.Value) {
			go func() {
				if err := handler(payload, metadata, sink); err != nil {
					reject.Invoke(statusObject(err))
					return
				}
				resolve.Invoke(js.Undefined())
			}()
		})
	})
	bridge.Call("registerServerStream", path, fn)
}

func registerClientStreamHandler(bridge js.Value, path string, handler func([][]byte, [][2]string) ([]byte, error)) {
	fn := js.FuncOf(func(_ js.Value, args []js.Value) any {
		payloads := payloadsOf(args[0])
		metadata := metadataPairsOf(args[1])
		return promiseOf(func(resolve, reject js.Value) {
			go func() {
				resp, err := handler(payloads, metadata)
				if err != nil {
					reject.Invoke(statusObject(err))
					return
				}
				resolve.Invoke(uint8Array(resp))
			}()
		})
	})
	bridge.Call("registerClientStream", path, fn)
}

func registerBidiHandler(bridge js.Value, path string, handler func([][]byte, [][2]string, *ServerSink) error) {
	fn := js.FuncOf(func(_ js.Value, args []js.Value) any {
		payloads := payloadsOf(args[0])
		metadata := metadataPairsOf(args[1])
		sink := &ServerSink{onMessage: args[2]}
		return promiseOf(func(resolve, reject js.Value) {
			go func() {
				if err := handler(payloads, metadata, sink); err != nil {
					reject.Invoke(statusObject(err))
					return
				}
				resolve.Invoke(js.Undefined())
			}()
		})
	})
	bridge.Call("registerBidi", path, fn)
}

// RequestSource pulls requests one at a time from the JS
// bridge's incremental source ({next(): Promise<bytes|null>}):
// Next returns (nil, nil) at end of stream. Nothing is
// collected up front, so handlers may answer as requests land.
type RequestSource struct {
	source js.Value
}

// Next awaits the next request payload.
func (s *RequestSource) Next() ([]byte, error) {
	value, err := await(s.source.Call("next"))
	if err != nil {
		return nil, err
	}
	if value.Type() == js.TypeNull || value.Type() == js.TypeUndefined {
		return nil, nil
	}
	return bytesOf(value), nil
}

func registerClientStreamIncHandler(bridge js.Value, path string, handler func(*RequestSource, [][2]string) ([]byte, error)) {
	fn := js.FuncOf(func(_ js.Value, args []js.Value) any {
		source := &RequestSource{source: args[0]}
		metadata := metadataPairsOf(args[1])
		return promiseOf(func(resolve, reject js.Value) {
			go func() {
				resp, err := handler(source, metadata)
				if err != nil {
					reject.Invoke(statusObject(err))
					return
				}
				resolve.Invoke(uint8Array(resp))
			}()
		})
	})
	bridge.Call("registerClientStreamInc", path, fn)
}

func registerBidiIncHandler(bridge js.Value, path string, handler func(*RequestSource, [][2]string, *ServerSink) error) {
	fn := js.FuncOf(func(_ js.Value, args []js.Value) any {
		source := &RequestSource{source: args[0]}
		metadata := metadataPairsOf(args[1])
		sink := &ServerSink{onMessage: args[2]}
		return promiseOf(func(resolve, reject js.Value) {
			go func() {
				if err := handler(source, metadata, sink); err != nil {
					reject.Invoke(statusObject(err))
					return
				}
				resolve.Invoke(js.Undefined())
			}()
		})
	})
	bridge.Call("registerBidiInc", path, fn)
}
