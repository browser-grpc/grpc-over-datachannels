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
