#lang racket

;;; template-wasm-kotlin.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-wasm-kotlin.
;;;
;;; The generated facade is a typed Kotlin client compiled
;;; with the Kotlin/Wasm backend (wasm-js) that calls the
;;; JavaScript grpc-dc implementation through
;;; wasm/kotlin/bridge.kt (which wraps js/src/wasm_bridge.js).
;;; Nothing blocks — the browser thread is single — so methods
;;; take completion callbacks. Message types live beside the
;;; facade (same package) and must provide marshalDc() /
;;; unmarshalDc(ByteArray) like the native Kotlin messages,
;;; but from common-Kotlin sources (no java.*).

(require "spec.rkt" "desc.rkt")
(provide emit-wasm-kotlin-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (wasm-kotlin-client-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        fun ~a(req: ~a, callback: (Result<~a>) -> Unit) {\n"
              "            bridge.unary(~s, req.marshalDc()) { result ->\n"
              "                callback(result.mapCatching { bytes ->\n"
              "                    ~a().apply { unmarshalDc(bytes) }\n"
              "                })\n"
              "            }\n"
              "        }\n\n")
             name req resp path resp)]
    [(server-streaming)
     (format (string-append
              "        fun ~a(\n"
              "            req: ~a,\n"
              "            onMessage: (~a) -> Unit,\n"
              "            onDone: (StatusException?) -> Unit\n"
              "        ) {\n"
              "            var finished = false\n"
              "            bridge.serverStream(~s, req.marshalDc(), { bytes ->\n"
              "                if (!finished) {\n"
              "                    try {\n"
              "                        onMessage(~a().apply { unmarshalDc(bytes) })\n"
              "                    } catch (e: Throwable) {\n"
              "                        finished = true\n"
              "                        onDone(StatusException.toStatus(e))\n"
              "                    }\n"
              "                }\n"
              "            }) { err ->\n"
              "                if (!finished) {\n"
              "                    finished = true\n"
              "                    onDone(err)\n"
              "                }\n"
              "            }\n"
              "        }\n\n")
             name req resp path resp)]
    [(client-streaming)
     (format (string-append
              "        fun ~a(reqs: List<~a>, callback: (Result<~a>) -> Unit) {\n"
              "            bridge.clientStream(~s, reqs.map { it.marshalDc() }) { result ->\n"
              "                callback(result.mapCatching { bytes ->\n"
              "                    ~a().apply { unmarshalDc(bytes) }\n"
              "                })\n"
              "            }\n"
              "        }\n\n")
             name req resp path resp)]
    [(bidi)
     (format (string-append
              "        fun ~a(\n"
              "            reqs: List<~a>,\n"
              "            onMessage: (~a) -> Unit,\n"
              "            onDone: (StatusException?) -> Unit\n"
              "        ) {\n"
              "            var finished = false\n"
              "            bridge.bidi(~s, reqs.map { it.marshalDc() }, { bytes ->\n"
              "                if (!finished) {\n"
              "                    try {\n"
              "                        onMessage(~a().apply { unmarshalDc(bytes) })\n"
              "                    } catch (e: Throwable) {\n"
              "                        finished = true\n"
              "                        onDone(StatusException.toStatus(e))\n"
              "                    }\n"
              "                }\n"
              "            }) { err ->\n"
              "                if (!finished) {\n"
              "                    finished = true\n"
              "                    onDone(err)\n"
              "                }\n"
              "            }\n"
              "        }\n\n")
             name req resp path resp)]))


(define (wasm-kotlin-server-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        fun ~a(req: ~a, metadata: Map<String, String>): ~a\n" name req resp)]
    [(server-streaming)
     (format "        fun ~a(req: ~a, metadata: Map<String, String>, sink: (~a) -> Unit)\n" name req resp)]
    [(client-streaming)
     (format "        fun ~a(reqs: List<~a>, metadata: Map<String, String>): ~a\n" name req resp)]
    [(bidi)
     (format "        fun ~a(reqs: List<~a>, metadata: Map<String, String>, sink: (~a) -> Unit)\n" name req resp)]))

(define (wasm-kotlin-register-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        bridge.unary(~s) { bytes, metadata ->\n"
              "            impl.~a(~a().apply { unmarshalDc(bytes) }, metadata).marshalDc()\n"
              "        }\n")
             path name req)]
    [(server-streaming)
     (format (string-append
              "        bridge.serverStream(~s) { bytes, metadata, sink ->\n"
              "            impl.~a(~a().apply { unmarshalDc(bytes) }, metadata) { resp -> sink(resp.marshalDc()) }\n"
              "        }\n")
             path name req)]
    [(client-streaming)
     (format (string-append
              "        bridge.clientStream(~s) { payloads, metadata ->\n"
              "            impl.~a(payloads.map { bytes -> ~a().apply { unmarshalDc(bytes) } }, metadata).marshalDc()\n"
              "        }\n")
             path name req)]
    [(bidi)
     (format (string-append
              "        bridge.bidi(~s) { payloads, metadata, sink ->\n"
              "            impl.~a(payloads.map { bytes -> ~a().apply { unmarshalDc(bytes) } }, metadata) { resp -> sink(resp.marshalDc()) }\n"
              "        }\n")
             path name req)]))

(define (wasm-kotlin-stream-iface-method m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (format "        fun ~a(source: ~aSource, metadata: Map<String, String>, respond: (~a) -> Unit, fail: (StatusException) -> Unit)\n"
             name (hash-ref m 'input) resp)]
    [(bidi)
     (format "        fun ~a(source: ~aSource, metadata: Map<String, String>, sink: (~a) -> Unit, done: () -> Unit, fail: (StatusException) -> Unit)\n"
             name (hash-ref m 'input) resp)]
    [else ""]))

(define (wasm-kotlin-stream-register-method m)
  (define name (hash-ref m 'name))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (format (string-append
              "        bridge.clientStreamInc(~s) { source, metadata, respond, fail ->\n"
              "            impl.~a(~aSource(source), metadata, { resp -> respond(resp.marshalDc()) }, fail)\n"
              "        }\n")
             path name (hash-ref m 'input))]
    [(bidi)
     (format (string-append
              "        bridge.bidiInc(~s) { source, metadata, sink, done, fail ->\n"
              "            impl.~a(~aSource(source), metadata, { resp -> sink(resp.marshalDc()) }, done, fail)\n"
              "        }\n")
             path name (hash-ref m 'input))]
    [else ""]))

(define (wasm-kotlin-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "    /** Client for ~a (browser/WASM facade; see file doc). */\n" (hash-ref svc 'full-name))
     (format "    class ~aClient(private val bridge: GrpcdcWasmBridge) {\n" sname)
     (apply string-append
            (map wasm-kotlin-client-method (append methods (alias-client-methods svc))))
     "    }\n\n"
     (format "    /** Service implementation interface for ~a (browser/WASM facade). */\n" (hash-ref svc 'full-name))
     (format "    interface ~aServer {\n" sname)
     (apply string-append (map wasm-kotlin-server-iface-method methods))
     "    }\n\n"
     (format "    /** Register an implementation of ~a on a server bridge. */\n" (hash-ref svc 'full-name))
     (format "    fun register~aServer(bridge: GrpcdcWasmServerBridge, impl: ~aServer) {\n" sname sname)
     (apply string-append
            (map wasm-kotlin-register-method (append methods (alias-server-methods svc))))
     (format "        bridge.start(~s)\n" (hash-ref svc 'full-name))
     "    }\n\n"
     ;; One typed pull source per distinct request type used by
     ;; the incremental (client-streaming/bidi) methods.
     (apply string-append
            (for/list ([in (in-list (remove-duplicates
                                     (map (lambda (m) (hash-ref m 'input))
                                          (filter (lambda (m) (memq (hash-ref m 'kind) '(client-streaming bidi))) methods))))])
              (string-append
               (format "    /** Typed pull source for incremental server handlers. */\n")
               (format "    class ~aSource internal constructor(private val raw: GrpcdcRequestSource) {\n" in)
               (format "        fun next(onRequest: ((~a?) -> Unit), onError: (StatusException) -> Unit) {\n" in)
               (format "            raw.next({ bytes -> onRequest(bytes?.let { ~a().apply { unmarshalDc(it) } }) }, onError)\n" in)
               "        }\n"
               "    }\n\n")))
     (format "    /** Incremental service implementation for ~a: requests arrive one at a time. */\n" (hash-ref svc 'full-name))
     (format "    interface ~aStreamServer {\n" sname)
     (apply string-append (map wasm-kotlin-stream-iface-method methods))
     "    }\n\n"
     (format "    /** Register an incremental implementation; call bridge.start after all registrations. */\n")
     (format "    fun register~aStreamServer(bridge: GrpcdcWasmServerBridge, impl: ~aStreamServer) {\n" sname sname)
     (apply string-append
            (map wasm-kotlin-stream-register-method (append methods (alias-server-methods svc))))
     "    }\n")))

(define (emit-wasm-kotlin-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define object-name (string-append (pascal (string->symbol base)) "WasmGrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define bridge-package (hash-ref params 'bridge_package "grpcdcwasm"))
  (cons (string-append object-name ".kt")
        (string-append
         "// @generated by protoc-gen-grpc-dc-wasm-kotlin. DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         (format "package ~a\n\n" (if (string=? pkg "") "proto" pkg))
         (format "import ~a.GrpcdcWasmBridge\n" bridge-package)
         (format "import ~a.GrpcdcWasmServerBridge\n" bridge-package)
         (format "import ~a.GrpcdcRequestSource\n" bridge-package)
         (format "import ~a.StatusException\n\n" bridge-package)
         (format "/** Generated WASM facade stubs for ~a. */\n" (hash-ref file-model 'name))
         (format "object ~a {\n" object-name)
         (apply string-append
                (map wasm-kotlin-service (hash-ref file-model 'services)))
         "}\n")))
