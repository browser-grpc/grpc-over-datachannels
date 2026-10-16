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

(define (wasm-kotlin-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "    /** Client for ~a (browser/WASM facade; see file doc). */\n" (hash-ref svc 'full-name))
     (format "    class ~aClient(private val bridge: GrpcdcWasmBridge) {\n" sname)
     (apply string-append
            (map wasm-kotlin-client-method (append methods (alias-client-methods svc))))
     "    }\n\n")))

(define (emit-wasm-kotlin-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define object-name (string-append (pascal (string->symbol base)) "WasmGrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define bridge-package (hash-ref params 'bridge_package "grpcdcwasm"))
  (cons (string-append object-name ".kt")
        (string-append
         "// @generated by protoc-gen-grpc-dc-wasm-kotlin (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         (format "package ~a\n\n" (if (string=? pkg "") "proto" pkg))
         (format "import ~a.GrpcdcWasmBridge\n" bridge-package)
         (format "import ~a.StatusException\n\n" bridge-package)
         (format "/** Generated WASM facade stubs for ~a. */\n" (hash-ref file-model 'name))
         (format "object ~a {\n" object-name)
         (apply string-append
                (map wasm-kotlin-service (hash-ref file-model 'services)))
         "}\n")))
