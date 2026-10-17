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
(define current-struct (make-parameter ""))

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


(define (wasm-cpp-server-export m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define export-name
    (let* ([raw (hash-ref m 'name)]
           [n (if (symbol? raw) (symbol->string raw) raw)])
      (string-append "serve_" (string (char-downcase (string-ref n 0))) (substring n 1))))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "extern \"C\" void ~a(std::uint32_t call_id, const std::uint8_t* payload_ptr, std::size_t payload_len, const std::uint8_t* md_ptr, std::size_t md_len) {\n"
              "  auto md = grpcdc_wasm::DecodeMetadata(grpcdc_wasm::Bytes(md_ptr, md_ptr + md_len));\n"
              "  ~a req;\n"
              "  if (!req.UnmarshalDc(grpcdc_wasm::Bytes(payload_ptr, payload_ptr + payload_len))) { grpcdc_wasm::ServerFail(call_id, {3, \"malformed request payload\"}); return; }\n"
              "  auto result = ~a::g_impl->~a(req, md);\n"
              "  if (!result.first.ok()) { grpcdc_wasm::ServerFail(call_id, result.first); return; }\n"
              "  grpcdc_wasm::ServerRespond(call_id, result.second.MarshalDc());\n"
              "}\n\n")
             export-name req (current-struct) name)]
    [(server-streaming)
     (format (string-append
              "extern \"C\" void ~a(std::uint32_t call_id, const std::uint8_t* payload_ptr, std::size_t payload_len, const std::uint8_t* md_ptr, std::size_t md_len) {\n"
              "  auto md = grpcdc_wasm::DecodeMetadata(grpcdc_wasm::Bytes(md_ptr, md_ptr + md_len));\n"
              "  ~a req;\n"
              "  if (!req.UnmarshalDc(grpcdc_wasm::Bytes(payload_ptr, payload_ptr + payload_len))) { grpcdc_wasm::ServerFail(call_id, {3, \"malformed request payload\"}); return; }\n"
              "  ~a::~aServerSink sink{call_id};\n"
              "  auto st = ~a::g_impl->~a(req, md, sink);\n"
              "  if (st.ok()) grpcdc_wasm::ServerComplete(call_id); else grpcdc_wasm::ServerFail(call_id, st);\n"
              "}\n\n")
             export-name req (current-struct) (current-service) (current-struct) name)]
    [(client-streaming)
     (format (string-append
              "extern \"C\" void ~a(std::uint32_t call_id, const std::uint8_t* payload_ptr, std::size_t payload_len, const std::uint8_t* md_ptr, std::size_t md_len) {\n"
              "  auto md = grpcdc_wasm::DecodeMetadata(grpcdc_wasm::Bytes(md_ptr, md_ptr + md_len));\n"
              "  std::vector<~a> reqs;\n"
              "  for (const auto& chunk : grpcdc_wasm::Unpack(grpcdc_wasm::Bytes(payload_ptr, payload_ptr + payload_len))) { ~a req; if (!req.UnmarshalDc(chunk)) { grpcdc_wasm::ServerFail(call_id, {3, \"malformed request payload\"}); return; } reqs.push_back(req); }\n"
              "  auto result = ~a::g_impl->~a(reqs, md);\n"
              "  if (!result.first.ok()) { grpcdc_wasm::ServerFail(call_id, result.first); return; }\n"
              "  grpcdc_wasm::ServerRespond(call_id, result.second.MarshalDc());\n"
              "}\n\n")
             export-name req req (current-struct) name)]
    [(bidi)
     (format (string-append
              "extern \"C\" void ~a(std::uint32_t call_id, const std::uint8_t* payload_ptr, std::size_t payload_len, const std::uint8_t* md_ptr, std::size_t md_len) {\n"
              "  auto md = grpcdc_wasm::DecodeMetadata(grpcdc_wasm::Bytes(md_ptr, md_ptr + md_len));\n"
              "  std::vector<~a> reqs;\n"
              "  for (const auto& chunk : grpcdc_wasm::Unpack(grpcdc_wasm::Bytes(payload_ptr, payload_ptr + payload_len))) { ~a req; if (!req.UnmarshalDc(chunk)) { grpcdc_wasm::ServerFail(call_id, {3, \"malformed request payload\"}); return; } reqs.push_back(req); }\n"
              "  ~a::~aServerSink sink{call_id};\n"
              "  auto st = ~a::g_impl->~a(reqs, md, sink);\n"
              "  if (st.ok()) grpcdc_wasm::ServerComplete(call_id); else grpcdc_wasm::ServerFail(call_id, st);\n"
              "}\n\n")
             export-name req req (current-struct) (current-service) (current-struct) name)]))


(define (wasm-cpp-server-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(unary)
     (format "    virtual std::pair<grpcdc_wasm::Status, ~a> ~a(const ~a& req, const std::vector<grpcdc_wasm::MdPair>& md) = 0;\n" resp name req)]
    [(server-streaming)
     (format "    virtual grpcdc_wasm::Status ~a(const ~a& req, const std::vector<grpcdc_wasm::MdPair>& md, ~aServerSink& sink) = 0;\n" name req (current-service))]
    [(client-streaming)
     (format "    virtual std::pair<grpcdc_wasm::Status, ~a> ~a(const std::vector<~a>& reqs, const std::vector<grpcdc_wasm::MdPair>& md) = 0;\n" resp name req)]
    [(bidi)
     (format "    virtual grpcdc_wasm::Status ~a(const std::vector<~a>& reqs, const std::vector<grpcdc_wasm::MdPair>& md, ~aServerSink& sink) = 0;\n" name req (current-service))]))


(define (wasm-cpp-export-name m)
  (let* ([raw (hash-ref m 'name)]
         [n (if (symbol? raw) (symbol->string raw) raw)])
    (string-append "serve_" (string (char-downcase (string-ref n 0))) (substring n 1))))

(define (wasm-cpp-stream-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (string-append
      (format "    virtual void ~aBegin(std::uint32_t call_id, const std::vector<grpcdc_wasm::MdPair>& md) = 0;\n" name)
      (format "    virtual void ~aRequest(std::uint32_t call_id, const ~a& req) = 0;\n" name req)
      (format "    virtual std::pair<grpcdc_wasm::Status, ~a> ~aEnd(std::uint32_t call_id) = 0;\n" resp name))]
    [(bidi)
     (string-append
      (format "    virtual void ~aBegin(std::uint32_t call_id, const std::vector<grpcdc_wasm::MdPair>& md) = 0;\n" name)
      (format "    virtual grpcdc_wasm::Status ~aRequest(std::uint32_t call_id, const ~a& req, ~aServerSink& sink) = 0;\n" name req (current-service))
      (format "    virtual grpcdc_wasm::Status ~aEnd(std::uint32_t call_id) = 0;\n" name))]
    [else ""]))

(define (wasm-cpp-stream-feed-export m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define export-name (wasm-cpp-export-name m))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (string-append
      (format (string-append
               "extern \"C\" void ~aStart(std::uint32_t call_id, const std::uint8_t* md_ptr, std::size_t md_len) {\n"
               "  auto md = grpcdc_wasm::DecodeMetadata(grpcdc_wasm::Bytes(md_ptr, md_ptr + md_len));\n"
               "  ~a::g_stream_impl->~aBegin(call_id, md);\n"
               "}\n\n")
              export-name (current-struct) name)
      (format (string-append
               "extern \"C\" void ~aFeed(std::uint32_t call_id, const std::uint8_t* payload_ptr, std::size_t payload_len) {\n"
               "  ~a req;\n"
               "  if (!req.UnmarshalDc(grpcdc_wasm::Bytes(payload_ptr, payload_ptr + payload_len))) { grpcdc_wasm::ServerFail(call_id, {3, \"malformed request payload\"}); return; }\n"
               "  ~a::g_stream_impl->~aRequest(call_id, req);\n"
               "}\n\n")
              export-name req (current-struct) name)
      (format (string-append
               "extern \"C\" void ~aEnd(std::uint32_t call_id) {\n"
               "  auto result = ~a::g_stream_impl->~aEnd(call_id);\n"
               "  if (!result.first.ok()) { grpcdc_wasm::ServerFail(call_id, result.first); return; }\n"
               "  grpcdc_wasm::ServerRespond(call_id, result.second.MarshalDc());\n"
               "}\n\n")
              export-name (current-struct) name))]
    [(bidi)
     (string-append
      (format (string-append
               "extern \"C\" void ~aStart(std::uint32_t call_id, const std::uint8_t* md_ptr, std::size_t md_len) {\n"
               "  auto md = grpcdc_wasm::DecodeMetadata(grpcdc_wasm::Bytes(md_ptr, md_ptr + md_len));\n"
               "  ~a::g_stream_impl->~aBegin(call_id, md);\n"
               "}\n\n")
              export-name (current-struct) name)
      (format (string-append
               "extern \"C\" void ~aFeed(std::uint32_t call_id, const std::uint8_t* payload_ptr, std::size_t payload_len) {\n"
               "  ~a req;\n"
               "  if (!req.UnmarshalDc(grpcdc_wasm::Bytes(payload_ptr, payload_ptr + payload_len))) { grpcdc_wasm::ServerFail(call_id, {3, \"malformed request payload\"}); return; }\n"
               "  ~a::~aServerSink sink{call_id};\n"
               "  auto st = ~a::g_stream_impl->~aRequest(call_id, req, sink);\n"
               "  if (!st.ok()) grpcdc_wasm::ServerFail(call_id, st);\n"
               "}\n\n")
              export-name req (current-struct) (current-service) (current-struct) name)
      (format (string-append
               "extern \"C\" void ~aEnd(std::uint32_t call_id) {\n"
               "  auto st = ~a::g_stream_impl->~aEnd(call_id);\n"
               "  if (st.ok()) grpcdc_wasm::ServerComplete(call_id); else grpcdc_wasm::ServerFail(call_id, st);\n"
               "}\n\n")
              export-name (current-struct) name))]
    [else ""]))

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
     "  };\n\n"
     (format "  /// Streaming response sink for server handlers.\n")
     (format "  struct ~aServerSink {\n" sname)
     "    std::uint32_t call_id;\n\n"
     ;; One Send overload per distinct response type (first-use
     ;; order): the sink must accept every method's response, not
     ;; just the first method's.
     (apply string-append
            (for/list ([resp (in-list (remove-duplicates (map (lambda (m) (hash-ref m 'output)) methods)))])
              (format "    grpcdc_wasm::Status Send(const ~a& resp) {\n      grpcdc_wasm::ServerSend(call_id, resp.MarshalDc());\n      return grpcdc_wasm::Status::Ok();\n    }\n" resp)))
     "  };\n\n"
     (format "  /// Service implementation for ~a (browser/WASM facade).\n" (hash-ref svc 'full-name))
     (format "  class ~aServer {\n   public:\n" sname)
     "    virtual ~" sname "Server() = default;\n"
     (apply string-append (map wasm-cpp-server-iface-method methods))
     "  };\n\n"
     (format "  static inline ~aServer* g_impl = nullptr;\n\n" sname)
     (format "  /// Register the service implementation used by the serve_* exports.\n")
     (format "  static void register~aServer(~aServer& impl) { g_impl = &impl; }\n\n" sname sname)
     (format "  /// Incremental service implementation for ~a: requests arrive one at a time via serve_*Start/Feed/End.\n" (hash-ref svc 'full-name))
     (format "  class ~aStreamServer {\n   public:\n" sname)
     (string-append "    virtual ~" sname "StreamServer() = default;\n")
     (apply string-append (map wasm-cpp-stream-iface-method methods))
     "  };\n\n"
     (format "  static inline ~aStreamServer* g_stream_impl = nullptr;\n\n" sname)
     (format "  /// Register the incremental implementation used by the serve_*Start/Feed/End exports.\n")
     (format "  static void register~aStreamServer(~aStreamServer& impl) { g_stream_impl = &impl; }\n" sname sname)
     "};\n\n"
     (apply string-append (map wasm-cpp-server-export methods))
     (apply string-append (map wasm-cpp-stream-feed-export methods)))))

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
                (map (lambda (svc) (parameterize ([current-struct struct-name]) (wasm-cpp-service svc))) (hash-ref file-model 'services)))
         (format "}  // namespace ~a\n" ns))))
