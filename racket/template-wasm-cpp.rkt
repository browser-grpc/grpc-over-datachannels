#lang racket

;;; template-wasm-cpp.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-wasm-cpp.
;;;
;;; The generated facade is a typed C++ client compiled to
;;; wasm32-wasi (reactor, -fno-exceptions: Zig's wasm32 libc++
;;; has no exception runtime) that calls the JavaScript
;;; grpc-dc implementation through wasm/cpp/bridge.{hpp,cpp},
;;; which wraps js/src/wasm_bridge.js. Nothing blocks — the
;;; browser is single-threaded — so methods take completion
;;; callbacks. Message types live beside the facade and must
;;; provide exception-free MarshalDc() -> Bytes and
;;; UnmarshalDc(Bytes) -> bool (see wasm/cpp/echo_messages.hpp);
;;; the threaded native endpoint/channel runtime stays native.

(require "spec.rkt" "desc.rkt")
(provide emit-wasm-cpp-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (cpp-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a[[deprecated(\"deprecated in the proto schema\")]]\n" indent)
      ""))

(define (wasm-cpp-client-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    void ~a(~a req,\n"
              "            std::function<void(grpcdc_wasm::Status,\n"
              "                               std::optional<~a>)> callback) {\n"
              "      bridge_->Unary(~s, req.MarshalDc(),\n"
              "                     [callback](grpcdc_wasm::Status st,\n"
              "                                const grpcdc_wasm::Bytes* bytes) {\n"
              "                       HandleUnary<~a>(std::move(st), bytes, callback);\n"
              "                     });\n"
              "    }\n\n")
             name req resp path resp)]
    [(server-streaming)
     (format (string-append
              "    void ~a(~a req,\n"
              "            std::function<void(~a)> on_message,\n"
              "            grpcdc_wasm::DoneCallback on_done) {\n"
              "      auto finished = std::make_shared<bool>(false);\n"
              "      bridge_->ServerStream(\n"
              "          ~s, req.MarshalDc(),\n"
              "          [on_message, on_done, finished](const grpcdc_wasm::Bytes& bytes) {\n"
              "            HandleMessage<~a>(bytes, on_message, on_done, finished);\n"
              "          },\n"
              "          [on_done, finished](grpcdc_wasm::Status st) {\n"
              "            if (*finished) return;\n"
              "            *finished = true;\n"
              "            on_done(std::move(st));\n"
              "          });\n"
              "    }\n\n")
             name req resp path resp)]
    [(client-streaming)
     (format (string-append
              "    void ~a(std::vector<~a> reqs,\n"
              "            std::function<void(grpcdc_wasm::Status,\n"
              "                               std::optional<~a>)> callback) {\n"
              "      bridge_->ClientStream(\n"
              "          ~s, MarshalAll(reqs),\n"
              "          [callback](grpcdc_wasm::Status st,\n"
              "                     const grpcdc_wasm::Bytes* bytes) {\n"
              "            HandleUnary<~a>(std::move(st), bytes, callback);\n"
              "          });\n"
              "    }\n\n")
             name req resp path resp)]
    [(bidi)
     (format (string-append
              "    void ~a(std::vector<~a> reqs,\n"
              "            std::function<void(~a)> on_message,\n"
              "            grpcdc_wasm::DoneCallback on_done) {\n"
              "      auto finished = std::make_shared<bool>(false);\n"
              "      bridge_->Bidi(\n"
              "          ~s, MarshalAll(reqs),\n"
              "          [on_message, on_done, finished](const grpcdc_wasm::Bytes& bytes) {\n"
              "            HandleMessage<~a>(bytes, on_message, on_done, finished);\n"
              "          },\n"
              "          [on_done, finished](grpcdc_wasm::Status st) {\n"
              "            if (*finished) return;\n"
              "            *finished = true;\n"
              "            on_done(std::move(st));\n"
              "          });\n"
              "    }\n\n")
             name req resp path resp)]))

(define (wasm-cpp-client-method m)
  (string-append (cpp-deprecated m "    ") (wasm-cpp-client-method/raw m)))

(define wasm-cpp-helpers
  (string-append
   "   private:\n"
   "    template <typename Resp, typename Callback>\n"
   "    static void HandleUnary(grpcdc_wasm::Status st,\n"
   "                            const grpcdc_wasm::Bytes* bytes,\n"
   "                            Callback callback) {\n"
   "      if (!st.ok()) {\n"
   "        callback(std::move(st), std::nullopt);\n"
   "        return;\n"
   "      }\n"
   "      Resp resp;\n"
   "      if (!resp.UnmarshalDc(bytes ? *bytes : grpcdc_wasm::Bytes{})) {\n"
   "        callback({3, \"malformed response payload\"}, std::nullopt);\n"
   "        return;\n"
   "      }\n"
   "      callback(grpcdc_wasm::Status::Ok(), resp);\n"
   "    }\n\n"
   "    template <typename Resp, typename OnMessage>\n"
   "    static void HandleMessage(const grpcdc_wasm::Bytes& bytes,\n"
   "                              OnMessage on_message,\n"
   "                              grpcdc_wasm::DoneCallback on_done,\n"
   "                              std::shared_ptr<bool> finished) {\n"
   "      if (*finished) return;\n"
   "      Resp resp;\n"
   "      if (!resp.UnmarshalDc(bytes)) {\n"
   "        *finished = true;\n"
   "        on_done({3, \"malformed response payload\"});\n"
   "        return;\n"
   "      }\n"
   "      on_message(resp);\n"
   "    }\n\n"
   "    template <typename Req>\n"
   "    static std::vector<grpcdc_wasm::Bytes> MarshalAll(\n"
   "        const std::vector<Req>& reqs) {\n"
   "      std::vector<grpcdc_wasm::Bytes> payloads;\n"
   "      for (const auto& req : reqs) payloads.push_back(req.MarshalDc());\n"
   "      return payloads;\n"
   "    }\n\n"))

(define (wasm-cpp-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "  /// Client for ~a (browser/WASM facade; see file doc).\n" (hash-ref svc 'full-name))
     (format "  class ~aClient {\n" sname)
     "   public:\n"
     (format "    explicit ~aClient(grpcdc_wasm::Bridge& bridge =\n                          grpcdc_wasm::Bridge::Shared())\n        : bridge_(&bridge) {}\n\n" sname)
     (apply string-append
            (map wasm-cpp-client-method (append methods (alias-client-methods svc))))
     wasm-cpp-helpers
     "    grpcdc_wasm::Bridge* bridge_;\n"
     "  };\n\n")))

(define (emit-wasm-cpp-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define struct-name (string-append (pascal (string->symbol base)) "WasmGrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define ns (if (string=? pkg "") "proto" pkg))
  (define messages-include
    (hash-ref params 'messages_include (format "~a_messages.hpp" base)))
  (define bridge-include (hash-ref params 'bridge_include "bridge.hpp"))
  (cons (string-append base "_wasm_dc.hpp")
        (string-append
         "// @generated by protoc-gen-grpc-dc-wasm-cpp (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         "#pragma once\n\n"
         "#include <functional>\n"
         "#include <memory>\n"
         "#include <optional>\n"
         "#include <utility>\n"
         "#include <vector>\n\n"
         (format "#include ~s\n" bridge-include)
         (format "#include ~s\n\n" messages-include)
         (format "namespace ~a {\n\n" ns)
         (format "/// Generated WASM facade stubs for ~a.\n" (hash-ref file-model 'name))
         (format "struct ~a {\n" struct-name)
         (apply string-append
                (map wasm-cpp-service (hash-ref file-model 'services)))
         "};\n\n"
         (format "}  // namespace ~a\n" ns))))
