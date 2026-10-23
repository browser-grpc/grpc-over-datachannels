#lang racket

;;; template-wasm-swift.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-wasm-swift.
;;;
;;; The generated facade is a typed Swift client compiled as
;;; Embedded Swift (wasm32-unknown-none-wasm, no Foundation)
;;; that calls the JavaScript grpc-dc implementation through
;;; wasm/swift/bridge.swift (which wraps js/src/wasm_bridge.js).
;;; Nothing blocks — the browser thread is single — so methods
;;; take completion callbacks. Hand-written message types must
;;; provide MarshalDc()/UnmarshalDc(_:) like the native Swift
;;; messages; they compile against the bridge's leaf protocols.

(require "spec.rkt" "desc.rkt")
(provide emit-wasm-swift-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (wasm-swift-client-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        func ~a(_ req: ~a, _ callback: @escaping (Result<~a, StatusException>) -> Void) {\n"
              "            bridge.unary(~s, req.MarshalDc()) { result in\n"
              "                callback(result.map { bytes in\n"
              "                    let resp = ~a()\n"
              "                    resp.UnmarshalDc(bytes)\n"
              "                    return resp\n"
              "                })\n"
              "            }\n"
              "        }\n\n")
             name req resp path resp)]
    [(server-streaming)
     (format (string-append
              "        func ~a(_ req: ~a, _ onMessage: @escaping (~a) -> Void,\n"
              "                _ onDone: @escaping (StatusException?) -> Void) {\n"
              "            bridge.serverStream(~s, req.MarshalDc(), { bytes in\n"
              "                let resp = ~a()\n"
              "                resp.UnmarshalDc(bytes)\n"
              "                onMessage(resp)\n"
              "            }, onDone)\n"
              "        }\n\n")
             name req resp path resp)]
    [(client-streaming)
     (format (string-append
              "        func ~a(_ reqs: [~a], _ callback: @escaping (Result<~a, StatusException>) -> Void) {\n"
              "            bridge.clientStream(~s, reqs.map { $0.MarshalDc() }) { result in\n"
              "                callback(result.map { bytes in\n"
              "                    let resp = ~a()\n"
              "                    resp.UnmarshalDc(bytes)\n"
              "                    return resp\n"
              "                })\n"
              "            }\n"
              "        }\n\n")
             name req resp path resp)]
    [(bidi)
     (format (string-append
              "        func ~a(_ reqs: [~a], _ onMessage: @escaping (~a) -> Void,\n"
              "                _ onDone: @escaping (StatusException?) -> Void) {\n"
              "            bridge.bidi(~s, reqs.map { $0.MarshalDc() }, { bytes in\n"
              "                let resp = ~a()\n"
              "                resp.UnmarshalDc(bytes)\n"
              "                onMessage(resp)\n"
              "            }, onDone)\n"
              "        }\n\n")
             name req resp path resp)]))


(define (wasm-swift-server-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        func ~a(_ req: ~a, _ metadata: [(String, String)]) -> Result<~a, StatusException>\n" name req resp)]
    [(server-streaming)
     (format "        func ~a(_ req: ~a, _ metadata: [(String, String)], _ sink: ~aServerSink) -> StatusException?\n" name req (current-service))]
    [(client-streaming)
     (format "        func ~a(_ reqs: [~a], _ metadata: [(String, String)]) -> Result<~a, StatusException>\n" name req resp)]
    [(bidi)
     (format "        func ~a(_ reqs: [~a], _ metadata: [(String, String)], _ sink: ~aServerSink) -> StatusException?\n" name req (current-service))]))

(define (wasm-swift-serve-export enum-name m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define export-name
    (let* ([raw (hash-ref m 'name)]
           [n (if (symbol? raw) (symbol->string raw) raw)])
      (string-append "serve_" (string (char-downcase (string-ref n 0))) (substring n 1))))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "@_cdecl(~s)\n"
              "public func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n"
              "    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n"
              "    let req = ~a()\n"
              "    req.UnmarshalDc(Array(UnsafeBufferPointer(start: payload, count: payloadLen)))\n"
              "    switch ~a.serverImpl!.~a(req, metadata) {\n"
              "    case .success(let resp): ServerRespond(callId, resp.MarshalDc())\n"
              "    case .failure(let st): ServerFail(callId, st)\n"
              "    }\n"
              "}\n\n")
             export-name export-name req enum-name name)]
    [(server-streaming)
     (format (string-append
              "@_cdecl(~s)\n"
              "public func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n"
              "    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n"
              "    let req = ~a()\n"
              "    req.UnmarshalDc(Array(UnsafeBufferPointer(start: payload, count: payloadLen)))\n"
              "    if let st = ~a.serverImpl!.~a(req, metadata, ~a.~aServerSink(callId: callId)) {\n"
              "        ServerFail(callId, st)\n"
              "    } else {\n"
              "        ServerComplete(callId)\n"
              "    }\n"
              "}\n\n")
             export-name export-name req enum-name name enum-name (current-service))]
    [(client-streaming)
     (format (string-append
              "@_cdecl(~s)\n"
              "public func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n"
              "    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n"
              "    let reqs = UnpackPacked(Array(UnsafeBufferPointer(start: payload, count: payloadLen))).map { bytes -> ~a in let req = ~a(); req.UnmarshalDc(bytes); return req }\n"
              "    switch ~a.serverImpl!.~a(reqs, metadata) {\n"
              "    case .success(let resp): ServerRespond(callId, resp.MarshalDc())\n"
              "    case .failure(let st): ServerFail(callId, st)\n"
              "    }\n"
              "}\n\n")
             export-name export-name req req enum-name name)]
    [(bidi)
     (format (string-append
              "@_cdecl(~s)\n"
              "public func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n"
              "    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n"
              "    let reqs = UnpackPacked(Array(UnsafeBufferPointer(start: payload, count: payloadLen))).map { bytes -> ~a in let req = ~a(); req.UnmarshalDc(bytes); return req }\n"
              "    if let st = ~a.serverImpl!.~a(reqs, metadata, ~a.~aServerSink(callId: callId)) {\n"
              "        ServerFail(callId, st)\n"
              "    } else {\n"
              "        ServerComplete(callId)\n"
              "    }\n"
              "}\n\n")
             export-name export-name req req enum-name name enum-name (current-service))]))


(define (wasm-swift-stream-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (string-append
      (format "        func ~aBegin(_ callId: UInt32, _ metadata: [(String, String)])\n" name)
      (format "        func ~aRequest(_ callId: UInt32, _ req: ~a)\n" name req)
      (format "        func ~aEnd(_ callId: UInt32) -> Result<~a, StatusException>\n" name resp))]
    [(bidi)
     (string-append
      (format "        func ~aBegin(_ callId: UInt32, _ metadata: [(String, String)])\n" name)
      (format "        func ~aRequest(_ callId: UInt32, _ req: ~a, _ sink: ~aServerSink) -> StatusException?\n" name req svc)
      (format "        func ~aEnd(_ callId: UInt32) -> StatusException?\n" name))]
    [else ""]))

(define (wasm-swift-export-name m)
  (let* ([raw (hash-ref m 'name)]
         [n (if (symbol? raw) (symbol->string raw) raw)])
    (string-append "serve_" (string (char-downcase (string-ref n 0))) (substring n 1))))

(define (wasm-swift-stream-feed-export enum-name m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define export-name (wasm-swift-export-name m))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (string-append
      (format (string-append
               "@_cdecl(~s)\n"
               "public func ~a(_ callId: UInt32, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n"
               "    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n"
               "    ~a.streamImpl!.~aBegin(callId, metadata)\n"
               "}\n\n")
              (string-append export-name "Start") (string-append export-name "Start") enum-name name)
      (format (string-append
               "@_cdecl(~s)\n"
               "public func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int) {\n"
               "    let req = ~a()\n"
               "    req.UnmarshalDc(Array(UnsafeBufferPointer(start: payload, count: payloadLen)))\n"
               "    ~a.streamImpl!.~aRequest(callId, req)\n"
               "}\n\n")
              (string-append export-name "Feed") (string-append export-name "Feed") req enum-name name)
      (format (string-append
               "@_cdecl(~s)\n"
               "public func ~a(_ callId: UInt32) {\n"
               "    switch ~a.streamImpl!.~aEnd(callId) {\n"
               "    case .success(let resp): ServerRespond(callId, resp.MarshalDc())\n"
               "    case .failure(let st): ServerFail(callId, st)\n"
               "    }\n"
               "}\n\n")
              (string-append export-name "End") (string-append export-name "End") enum-name name))]
    [(bidi)
     (string-append
      (format (string-append
               "@_cdecl(~s)\n"
               "public func ~a(_ callId: UInt32, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n"
               "    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n"
               "    ~a.streamImpl!.~aBegin(callId, metadata)\n"
               "}\n\n")
              (string-append export-name "Start") (string-append export-name "Start") enum-name name)
      (format (string-append
               "@_cdecl(~s)\n"
               "public func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int) {\n"
               "    let req = ~a()\n"
               "    req.UnmarshalDc(Array(UnsafeBufferPointer(start: payload, count: payloadLen)))\n"
               "    if let st = ~a.streamImpl!.~aRequest(callId, req, ~a.~aServerSink(callId: callId)) {\n"
               "        ServerFail(callId, st)\n"
               "    }\n"
               "}\n\n")
              (string-append export-name "Feed") (string-append export-name "Feed") req enum-name name enum-name (current-service))
      (format (string-append
               "@_cdecl(~s)\n"
               "public func ~a(_ callId: UInt32) {\n"
               "    if let st = ~a.streamImpl!.~aEnd(callId) {\n"
               "        ServerFail(callId, st)\n"
               "    } else {\n"
               "        ServerComplete(callId)\n"
               "    }\n"
               "}\n\n")
              (string-append export-name "End") (string-append export-name "End") enum-name name))]
    [else ""]))

(define (wasm-swift-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "    /// Client for ~a (browser/WASM facade; see file doc).\n" (hash-ref svc 'full-name))
     (format "    final class ~aClient {\n" sname)
     "        private let bridge: GrpcDcWasmBridge\n\n"
     "        init(_ bridge: GrpcDcWasmBridge = .shared) {\n"
     "            self.bridge = bridge\n"
     "        }\n\n"
     (apply string-append
            (map wasm-swift-client-method (append methods (alias-client-methods svc))))
     "    }\n\n"
     (format "    /// Streaming response sink for server handlers.\n")
     (format "    struct ~aServerSink {\n" sname)
     "        let callId: UInt32\n\n"
     ;; One Send overload per distinct response type (first-use order).
     (apply string-append
            (for/list ([resp (in-list (remove-duplicates (map (lambda (m) (hash-ref m 'output)) methods)))])
              (format "        func Send(_ resp: ~a) {\n            ServerSend(callId, resp.MarshalDc())\n        }\n" resp)))
     "    }\n\n"
     (format "    /// Service implementation for ~a (browser/WASM facade).\n" (hash-ref svc 'full-name))
     (format "    protocol ~aServer {\n" sname)
     (apply string-append (map wasm-swift-server-iface-method methods))
     "    }\n\n"
     (format "    static var serverImpl: ~aServer?\n\n" sname)
     (format "    /// Register the service implementation used by the serve_* exports.\n")
     (format "    static func register~aServer(_ impl: ~aServer) {\n" sname sname)
     (format "        serverImpl = impl\n")
     "    }\n\n"
     (format "    /// Incremental service implementation for ~a: requests arrive one at a time.\n" (hash-ref svc 'full-name))
     (format "    protocol ~aStreamServer {\n" sname)
     (apply string-append (map wasm-swift-stream-iface-method methods))
     "    }\n\n"
     (format "    static var streamImpl: ~aStreamServer?\n\n" sname)
     (format "    /// Register the incremental implementation used by the serve_*Start/Feed/End exports.\n")
     (format "    static func register~aStreamServer(_ impl: ~aStreamServer) {\n" sname sname)
     (format "        streamImpl = impl\n")
     "    }\n")))

(define (emit-wasm-swift-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define enum-name (string-append (pascal (string->symbol base)) "WasmGrpcDc"))
  (cons (string-append (pascal (string->symbol base)) "WasmGrpcDc.swift")
        (string-append
         "// @generated by protoc-gen-grpc-dc-wasm-swift. DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         (format "/// Generated WASM facade stubs for ~a.\n" (hash-ref file-model 'name))
         (format "enum ~a {\n" enum-name)
         (apply string-append
                (map wasm-swift-service (hash-ref file-model 'services)))
         "}\n\n"
         (apply string-append
                (for/list ([svc (in-list (hash-ref file-model 'services))])
                  (parameterize ([current-service (hash-ref svc 'name)])
                    (string-append
                     (apply string-append
                            (map (lambda (m) (wasm-swift-serve-export enum-name m))
                                 (hash-ref svc 'methods)))
                     (apply string-append
                            (map (lambda (m) (wasm-swift-stream-feed-export enum-name m))
                                 (hash-ref svc 'methods))))))))))
