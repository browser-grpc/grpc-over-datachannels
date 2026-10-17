#lang racket

;;; template-wasm-go.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-wasm-go.
;;;
;;; The generated facade is a typed Go client that runs under
;;; GOOS=js/GOARCH=wasm and calls the JavaScript grpc-dc implementation
;;; through a syscall/js bridge object (see js/src/wasm_bridge.js and
;;; wasm/go/bridge.go for the runtime helpers). Generated code lives in
;;; package `echowasm` by default (plugin parameter `go_package`),
;;; importing message types from `messages_import`
;;; (default grpcdc/examples).

(require "spec.rkt" "desc.rkt")
(provide emit-wasm-go-file)

(define current-service (make-parameter ""))

(define (wasm-client-method* m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "func (c *~aClient) ~a(req *echo.~a) (*echo.~a, error) {\n"
              "\tpayload, err := callUnary(c.bridge, ~s, req.MarshalDC())\n"
              "\tif err != nil {\n\t\treturn nil, err\n\t}\n"
              "\tresp := new(echo.~a)\n"
              "\tif err := resp.UnmarshalDC(payload); err != nil {\n\t\treturn nil, err\n\t}\n"
              "\treturn resp, nil\n"
              "}\n")
             svc name req resp path resp)]
    [(server-streaming)
     (format (string-append
              "func (c *~aClient) ~a(req *echo.~a, onResp func(*echo.~a) error) error {\n"
              "\treturn callStream(c.bridge, \"serverStream\", ~s, req.MarshalDC(), func(payload []byte) error {\n"
              "\t\tresp := new(echo.~a)\n"
              "\t\tif err := resp.UnmarshalDC(payload); err != nil {\n\t\t\treturn err\n\t\t}\n"
              "\t\treturn onResp(resp)\n"
              "\t})\n"
              "}\n")
             svc name req resp path resp)]
    [(client-streaming)
     (format (string-append
              "func (c *~aClient) ~a(reqs ...*echo.~a) (*echo.~a, error) {\n"
              "\tpayloads := make([][]byte, len(reqs))\n"
              "\tfor i, r := range reqs {\n\t\tpayloads[i] = r.MarshalDC()\n\t}\n"
              "\tpayload, err := callClientStream(c.bridge, ~s, payloads)\n"
              "\tif err != nil {\n\t\treturn nil, err\n\t}\n"
              "\tresp := new(echo.~a)\n"
              "\tif err := resp.UnmarshalDC(payload); err != nil {\n\t\treturn nil, err\n\t}\n"
              "\treturn resp, nil\n"
              "}\n")
             svc name req resp path resp)]
    [(bidi)
     (format (string-append
              "func (c *~aClient) ~a(reqs []*echo.~a, onResp func(*echo.~a) error) error {\n"
              "\tpayloads := make([][]byte, len(reqs))\n"
              "\tfor i, r := range reqs {\n\t\tpayloads[i] = r.MarshalDC()\n\t}\n"
              "\treturn callStreamPayloads(c.bridge, \"bidi\", ~s, payloads, func(payload []byte) error {\n"
              "\t\tresp := new(echo.~a)\n"
              "\t\tif err := resp.UnmarshalDC(payload); err != nil {\n\t\t\treturn err\n\t\t}\n"
              "\t\treturn onResp(resp)\n"
              "\t})\n"
              "}\n")
             svc name req resp path resp)]))

(define (wasm-server-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "\t~a(req *echo.~a, metadata [][2]string) (*echo.~a, error)\n" name req resp)]
    [(server-streaming)
     (format "\t~a(req *echo.~a, metadata [][2]string, sink *~aServerSink) error\n" name req svc)]
    [(client-streaming)
     (format "\t~a(reqs []*echo.~a, metadata [][2]string) (*echo.~a, error)\n" name req resp)]
    [(bidi)
     (format "\t~a(reqs []*echo.~a, metadata [][2]string, sink *~aServerSink) error\n" name req svc)]))

(define (wasm-register-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "\tregisterUnaryHandler(bridge, ~s, func(payload []byte, metadata [][2]string) ([]byte, error) {\n"
              "\t\treq := new(echo.~a)\n"
              "\t\tif err := req.UnmarshalDC(payload); err != nil {\n\t\t\treturn nil, err\n\t\t}\n"
              "\t\tresp, err := impl.~a(req, metadata)\n"
              "\t\tif err != nil {\n\t\t\treturn nil, err\n\t\t}\n"
              "\t\treturn resp.MarshalDC(), nil\n"
              "\t})\n")
             path req name)]
    [(server-streaming)
     (format (string-append
              "\tregisterServerStreamHandler(bridge, ~s, func(payload []byte, metadata [][2]string, sink *ServerSink) error {\n"
              "\t\treq := new(echo.~a)\n"
              "\t\tif err := req.UnmarshalDC(payload); err != nil {\n\t\t\treturn err\n\t\t}\n"
              "\t\treturn impl.~a(req, metadata, &~aServerSink{sink: sink})\n"
              "\t})\n")
             path req name (current-service))]
    [(client-streaming)
     (format (string-append
              "\tregisterClientStreamHandler(bridge, ~s, func(payloads [][]byte, metadata [][2]string) ([]byte, error) {\n"
              "\t\treqs := make([]*echo.~a, len(payloads))\n"
              "\t\tfor i, payload := range payloads {\n"
              "\t\t\treqs[i] = new(echo.~a)\n"
              "\t\t\tif err := reqs[i].UnmarshalDC(payload); err != nil {\n\t\t\t\treturn nil, err\n\t\t\t}\n"
              "\t\t}\n"
              "\t\tresp, err := impl.~a(reqs, metadata)\n"
              "\t\tif err != nil {\n\t\t\treturn nil, err\n\t\t}\n"
              "\t\treturn resp.MarshalDC(), nil\n"
              "\t})\n")
             path req req name)]
    [(bidi)
     (format (string-append
              "\tregisterBidiHandler(bridge, ~s, func(payloads [][]byte, metadata [][2]string, sink *ServerSink) error {\n"
              "\t\treqs := make([]*echo.~a, len(payloads))\n"
              "\t\tfor i, payload := range payloads {\n"
              "\t\t\treqs[i] = new(echo.~a)\n"
              "\t\t\tif err := reqs[i].UnmarshalDC(payload); err != nil {\n\t\t\t\treturn err\n\t\t\t}\n"
              "\t\t}\n"
              "\t\treturn impl.~a(reqs, metadata, &~aServerSink{sink: sink})\n"
              "\t})\n")
             path req req name (current-service))]))

(define (wasm-stream-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (format "\t~a(source *~aSource, metadata [][2]string) (*echo.~a, error)\n" name req resp)]
    [(bidi)
     (format "\t~a(source *~aSource, metadata [][2]string, sink *~aServerSink) error\n" name req svc)]
    [else ""]))

(define (wasm-stream-register-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (format (string-append
              "\tregisterClientStreamIncHandler(bridge, ~s, func(source *RequestSource, metadata [][2]string) ([]byte, error) {\n"
              "\t\tresp, err := impl.~a(&~aSource{raw: source}, metadata)\n"
              "\t\tif err != nil {\n\t\t\treturn nil, err\n\t\t}\n"
              "\t\treturn resp.MarshalDC(), nil\n"
              "\t})\n")
             path name req)]
    [(bidi)
     (format (string-append
              "\tregisterBidiIncHandler(bridge, ~s, func(source *RequestSource, metadata [][2]string, sink *ServerSink) error {\n"
              "\t\treturn impl.~a(&~aSource{raw: source}, metadata, &~aServerSink{sink: sink})\n"
              "\t})\n")
             path name req (current-service))]
    [else ""]))

(define (wasm-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "type ~aClient struct {\n\tbridge js.Value\n}\n\n" sname)
     (format "func New~aClient(bridge js.Value) *~aClient {\n\treturn &~aClient{bridge: bridge}\n}\n\n"
             sname sname sname)
     (apply string-append (map wasm-client-method* methods))
     (format "\n// ~aServer is the service implementation for ~a.\n" sname (hash-ref svc 'full-name))
     (format "type ~aServer interface {\n" sname)
     (apply string-append (map wasm-server-iface-method methods))
     "}\n\n"
     (format "// ~aServerSink sends responses on streaming calls.\n" sname)
     (format "type ~aServerSink struct {\n\tsink *ServerSink\n}\n\n" sname)
     (format "// Send marshals and forwards one response.\n")
     (format "func (s *~aServerSink) Send(resp *echo.~a) error {\n\ts.sink.Send(resp.MarshalDC())\n\treturn nil\n}\n\n"
             sname (hash-ref (car methods) 'output))
     (format "// Register~aServer registers impl on the JS server bridge and starts serving.\n" sname)
     (format "func Register~aServer(bridge js.Value, impl ~aServer) {\n" sname sname)
     (apply string-append (map wasm-register-method methods))
     (format "\tbridge.Call(\"start\", ~s)\n}\n" (hash-ref svc 'full-name))
     (format "\n// ~aSource pulls typed requests one at a time for incremental handlers.\n"
             (hash-ref (car methods) 'input))
     (format "type ~aSource struct {\n\traw *RequestSource\n}\n\n" (hash-ref (car methods) 'input))
     (format "// Next returns the next request, or (nil, nil) at end of stream.\n")
     (format "func (s *~aSource) Next() (*echo.~a, error) {\n" (hash-ref (car methods) 'input) (hash-ref (car methods) 'input))
     "\tpayload, err := s.raw.Next()\n"
     "\tif err != nil || payload == nil {\n\t\treturn nil, err\n\t}\n"
     (format "\treq := new(echo.~a)\n" (hash-ref (car methods) 'input))
     "\tif err := req.UnmarshalDC(payload); err != nil {\n\t\treturn nil, err\n\t}\n"
     "\treturn req, nil\n"
     "}\n\n"
     (format "// ~aStreamServer is the incremental implementation for ~a: requests arrive one at a time.\n" sname (hash-ref svc 'full-name))
     (format "type ~aStreamServer interface {\n" sname)
     (apply string-append (map wasm-stream-iface-method methods))
     "}\n\n"
     (format "// Register~aStreamServer registers an incremental impl; call bridge start after all registrations.\n" sname)
     (format "func Register~aStreamServer(bridge js.Value, impl ~aStreamServer) {\n" sname sname)
     (apply string-append (map wasm-stream-register-method methods))
     "}\n")))

(define (emit-wasm-go-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define pkg (hash-ref params 'go_package "echowasm"))
  (define messages-import (hash-ref params 'messages_import "grpcdc/examples"))
  (cons (string-append base "_wasm_dc.go")
        (string-append
         "// @generated by protoc-gen-grpc-dc-wasm-go (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "//go:build js && wasm\n\n"
         (format "package ~a\n\n" pkg)
         "import (\n\t\"syscall/js\"\n\n"
         (format "\techo ~s\n" messages-import)
         ")\n\n"
         (apply string-append
                (map wasm-service (hash-ref file-model 'services))))))
