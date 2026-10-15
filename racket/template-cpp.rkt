#lang racket

;;; template-cpp.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-cpp.
;;;
;;; Generated code is one struct <Base>GrpcDc in the proto package's
;;; namespace, beside hand-written message types implementing
;;; grpcdc::Marshaler / grpcdc::Unmarshaler. Method names keep the
;;; proto spelling, mirroring the Go/Java/C# stubs.

(require "spec.rkt" "desc.rkt")
(provide emit-cpp-file)

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

(define (cpp-client-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    ~a ~a(~a req,\n"
              "                       const grpcdc::Metadata* metadata = nullptr) {\n"
              "      ~a resp;\n"
              "      channel_->Unary(~s, req, resp, metadata);\n"
              "      return resp;\n"
              "    }\n\n")
             resp name req resp path)]
    [(server-streaming)
     (format (string-append
              "    ~a~aStream ~a(\n"
              "        ~a req, const grpcdc::Metadata* metadata = nullptr) {\n"
              "      return ~a~aStream(\n"
              "          channel_->ServerStream(~s, req, metadata));\n"
              "    }\n\n")
             svc name name req svc name path)]
    [(client-streaming)
     (format (string-append
              "    ~a ~a(std::vector<~a> reqs,\n"
              "                              const grpcdc::Metadata* metadata = nullptr) {\n"
              "      std::vector<const grpcdc::Marshaler*> ptrs;\n"
              "      for (auto& r : reqs) ptrs.push_back(&r);\n"
              "      ~a resp;\n"
              "      channel_->ClientStreamCall(~s, ptrs, resp, metadata);\n"
              "      return resp;\n"
              "    }\n\n")
             resp name req resp path)]
    [(bidi)
     (format (string-append
              "    ~a~aStream ~a(std::vector<~a> reqs,\n"
              "                        const grpcdc::Metadata* metadata = nullptr) {\n"
              "      std::vector<const grpcdc::Marshaler*> ptrs;\n"
              "      for (auto& r : reqs) ptrs.push_back(&r);\n"
              "      return ~a~aStream(channel_->Bidi(~s, ptrs, metadata));\n"
              "    }\n\n")
             svc name name req svc name path)]))

(define (cpp-client-method m)
  (string-append (cpp-deprecated m "    ") (cpp-client-method/raw m)))

(define (cpp-client-stream-class m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming bidi)
     (format (string-append
              "    class ~a~aStream {\n"
              "     public:\n"
              "      explicit ~a~aStream(grpcdc::Channel::ClientStream stream)\n"
              "          : stream_(std::move(stream)) {}\n"
              "      ~a Recv() {\n"
              "        ~a resp;\n"
              "        stream_.Recv(resp);\n"
              "        return resp;\n"
              "      }\n\n"
              "     private:\n"
              "      grpcdc::Channel::ClientStream stream_;\n"
              "    };\n\n")
             svc name svc name resp resp)]
    [else ""]))

(define (cpp-client-async-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    std::future<~a> ~aAsync(\n"
              "        ~a req, const grpcdc::Metadata* metadata = nullptr) {\n"
              "      return std::async(std::launch::async,\n"
              "                        [this, req, metadata] { return ~a(req, metadata); });\n"
              "    }\n\n")
             resp name req name)]
    [(server-streaming)
     (format (string-append
              "    std::future<std::vector<~a>> ~aAsync(\n"
              "        ~a req, const grpcdc::Metadata* metadata = nullptr) {\n"
              "      return std::async(std::launch::async, [this, req, metadata] {\n"
              "        auto stream = ~a(req, metadata);\n"
              "        std::vector<~a> out;\n"
              "        while (true) {\n"
              "          try {\n"
              "            out.push_back(stream.Recv());\n"
              "          } catch (const grpcdc::EndOfStream&) {\n"
              "            break;\n"
              "          }\n"
              "        }\n"
              "        return out;\n"
              "      });\n"
              "    }\n\n")
             resp name req name resp)]
    [(client-streaming)
     (format (string-append
              "    std::future<~a> ~aAsync(\n"
              "        std::vector<~a> reqs,\n"
              "        const grpcdc::Metadata* metadata = nullptr) {\n"
              "      return std::async(\n"
              "          std::launch::async,\n"
              "          [this, reqs, metadata] { return ~a(reqs, metadata); });\n"
              "    }\n\n")
             resp name req name)]
    [(bidi)
     (format (string-append
              "    std::future<std::vector<~a>> ~aAsync(\n"
              "        std::vector<~a> reqs,\n"
              "        const grpcdc::Metadata* metadata = nullptr) {\n"
              "      return std::async(std::launch::async, [this, reqs, metadata] {\n"
              "        auto stream = ~a(reqs, metadata);\n"
              "        std::vector<~a> out;\n"
              "        while (true) {\n"
              "          try {\n"
              "            out.push_back(stream.Recv());\n"
              "          } catch (const grpcdc::EndOfStream&) {\n"
              "            break;\n"
              "          }\n"
              "        }\n"
              "        return out;\n"
              "      });\n"
              "    }\n\n")
             resp name req name resp)]))

(define (cpp-server-stream-iface m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "  /// Server-streaming sink passed to service implementations.\n"
              "  struct ~a~aServer {\n"
              "    virtual ~~~a~aServer() = default;\n"
              "    virtual void Send(~a& resp) = 0;\n"
              "    virtual grpcdc::Endpoint::CallContext& Context() = 0;\n"
              "  };\n\n")
             svc name svc name resp)]
    [(client-streaming)
     (format (string-append
              "  /// Client-streaming stream passed to service implementations.\n"
              "  struct ~a~aServer {\n"
              "    virtual ~~~a~aServer() = default;\n"
              "    virtual ~a Recv() = 0;\n"
              "    virtual void SendAndClose(~a& resp) = 0;\n"
              "    virtual grpcdc::Endpoint::CallContext& Context() = 0;\n"
              "  };\n\n")
             svc name svc name req resp)]
    [(bidi)
     (format (string-append
              "  /// Bidi stream passed to service implementations.\n"
              "  struct ~a~aServer {\n"
              "    virtual ~~~a~aServer() = default;\n"
              "    virtual void Send(~a& resp) = 0;\n"
              "    virtual ~a Recv() = 0;\n"
              "    virtual grpcdc::Endpoint::CallContext& Context() = 0;\n"
              "  };\n\n")
             svc name svc name resp req)]))

(define (cpp-server-iface-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "    virtual ~a ~a(grpcdc::Endpoint::CallContext& ctx,\n                               ~a& req) = 0;\n" resp name req)]
    [(server-streaming)
     (format "    virtual void ~a(~a& req,\n                              ~a~aServer& stream) = 0;\n" name req svc name)]
    [(client-streaming)
     (format "    virtual void ~a(~a~aServer& stream) = 0;\n" name svc name)]
    [(bidi)
     (format "    virtual void ~a(~a~aServer& stream) = 0;\n" name svc name)]))

(define (cpp-server-iface-method m)
  (string-append (cpp-deprecated m "    ") (cpp-server-iface-method/raw m)))

(define (cpp-server-async-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "    virtual std::future<~a> ~aAsync(\n        grpcdc::Endpoint::CallContext& ctx, ~a& req) = 0;\n" resp name req)]
    [(server-streaming)
     (format "    virtual std::future<void> ~aAsync(\n        ~a& req, ~a~aServer& stream) = 0;\n" name req svc name)]
    [(client-streaming)
     (format "    virtual std::future<void> ~aAsync(\n        ~a~aServer& stream) = 0;\n" name svc name)]
    [(bidi)
     (format "    virtual std::future<void> ~aAsync(~a~aServer& stream) = 0;\n" name svc name)]))

(define (cpp-server-async-adapter-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    ~a ~a(grpcdc::Endpoint::CallContext& ctx,\n"
              "                       ~a& req) override {\n"
              "      return impl_->~aAsync(ctx, req).get();\n"
              "    }\n")
             resp name req name)]
    [(server-streaming)
     (format (string-append
              "    void ~a(~a& req,\n"
              "                      ~a~aServer& stream) override {\n"
              "      impl_->~aAsync(req, stream).get();\n"
              "    }\n")
             name req svc name name)]
    [(client-streaming)
     (format (string-append
              "    void ~a(~a~aServer& stream) override {\n"
              "      impl_->~aAsync(stream).get();\n"
              "    }\n")
             name svc name name)]
    [(bidi)
     (format (string-append
              "    void ~a(~a~aServer& stream) override { impl_->~aAsync(stream).get(); }\n")
             name svc name name)]))

(define (cpp-stream-impl m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "  class ~a~aServerImpl : public ~a~aServer {\n"
              "   public:\n"
              "    ~a~aServerImpl(grpcdc::Endpoint::CallContext& ctx,\n"
              "                               grpcdc::Server::ServerSink& sink)\n"
              "        : ctx_(ctx), sink_(sink) {}\n"
              "    void Send(~a& resp) override { sink_(resp.MarshalDc()); }\n"
              "    grpcdc::Endpoint::CallContext& Context() override { return ctx_; }\n\n"
              "   private:\n"
              "    grpcdc::Endpoint::CallContext& ctx_;\n"
              "    grpcdc::Server::ServerSink& sink_;\n"
              "  };\n\n")
             svc name svc name svc name resp)]
    [(client-streaming)
     (format (string-append
              "  class ~a~aServerImpl : public ~a~aServer {\n"
              "   public:\n"
              "    ~a~aServerImpl(grpcdc::Endpoint::CallContext& ctx,\n"
              "                               grpcdc::Server::RequestStream& reqs)\n"
              "        : ctx_(ctx), reqs_(reqs) {}\n"
              "    ~a Recv() override {\n"
              "      ~a req;\n"
              "      reqs_.RecvInto(req);\n"
              "      return req;\n"
              "    }\n"
              "    void SendAndClose(~a& resp) override {\n"
              "      resp_ = resp;\n"
              "      has_resp_ = true;\n"
              "    }\n"
              "    grpcdc::Endpoint::CallContext& Context() override { return ctx_; }\n"
              "    ~a Resp() const { return resp_; }\n"
              "    bool HasResp() const { return has_resp_; }\n\n"
              "   private:\n"
              "    grpcdc::Endpoint::CallContext& ctx_;\n"
              "    grpcdc::Server::RequestStream& reqs_;\n"
              "    ~a resp_;\n"
              "    bool has_resp_ = false;\n"
              "  };\n\n")
             svc name svc name svc name req req resp resp resp)]
    [(bidi)
     (format (string-append
              "  class ~a~aServerImpl : public ~a~aServer {\n"
              "   public:\n"
              "    ~a~aServerImpl(grpcdc::Endpoint::CallContext& ctx,\n"
              "                       grpcdc::Server::RequestStream& reqs,\n"
              "                       grpcdc::Server::ServerSink& sink)\n"
              "        : ctx_(ctx), reqs_(reqs), sink_(sink) {}\n"
              "    void Send(~a& resp) override { sink_(resp.MarshalDc()); }\n"
              "    ~a Recv() override {\n"
              "      ~a req;\n"
              "      reqs_.RecvInto(req);\n"
              "      return req;\n"
              "    }\n"
              "    grpcdc::Endpoint::CallContext& Context() override { return ctx_; }\n\n"
              "   private:\n"
              "    grpcdc::Endpoint::CallContext& ctx_;\n"
              "    grpcdc::Server::RequestStream& reqs_;\n"
              "    grpcdc::Server::ServerSink& sink_;\n"
              "  };\n\n")
             svc name svc name svc name resp req req)]))

(define (cpp-register-method m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (define kind-const
    (case (hash-ref m 'kind)
      [(unary) "kKindUnary"]
      [(server-streaming) "kKindServerStreaming"]
      [(client-streaming) "kKindClientStreaming"]
      [(bidi) "kKindBidi"]))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "            {~s, ~s, grpcdc::Server::~a,\n"
              "             [&impl](const grpcdc::Endpoint::CallContext& ctx,\n"
              "                     grpcdc::Server::RequestStream& reqs,\n"
              "                     grpcdc::Server::ServerSink& sink) {\n"
              "               ~a req;\n"
              "               reqs.RecvInto(req);\n"
              "               auto mutable_ctx = const_cast<grpcdc::Endpoint::CallContext&>(ctx);\n"
              "               ~a resp = impl.~a(mutable_ctx, req);\n"
              "               sink(resp.MarshalDc());\n"
              "             }},\n")
             name (hash-ref m 'path) kind-const req resp impl-name)]
    [(server-streaming)
     (format (string-append
              "            {~s, ~s,\n"
              "             grpcdc::Server::~a,\n"
              "             [&impl](const grpcdc::Endpoint::CallContext& ctx,\n"
              "                     grpcdc::Server::RequestStream& reqs,\n"
              "                     grpcdc::Server::ServerSink& sink) {\n"
              "               ~a req;\n"
              "               reqs.RecvInto(req);\n"
              "               ~a~aServerImpl stream(\n"
              "                   const_cast<grpcdc::Endpoint::CallContext&>(ctx), sink);\n"
              "               impl.~a(req, stream);\n"
              "             }},\n")
             name (hash-ref m 'path) kind-const req svc name impl-name)]
    [(client-streaming)
     (format (string-append
              "            {~s, ~s,\n"
              "             grpcdc::Server::~a,\n"
              "             [&impl](const grpcdc::Endpoint::CallContext& ctx,\n"
              "                     grpcdc::Server::RequestStream& reqs,\n"
              "                     grpcdc::Server::ServerSink& sink) {\n"
              "               ~a~aServerImpl stream(\n"
              "                   const_cast<grpcdc::Endpoint::CallContext&>(ctx), reqs);\n"
              "               impl.~a(stream);\n"
              "               if (!stream.HasResp()) {\n"
              "                 throw grpcdc::StatusException(\n"
              "                     grpcdc::wire::kCodeInternal,\n"
              "                     \"client-streaming handler never called SendAndClose\");\n"
              "               }\n"
              "               ~a resp = stream.Resp();\n"
              "               sink(resp.MarshalDc());\n"
              "             }},\n")
             name (hash-ref m 'path) kind-const svc name impl-name resp)]
    [(bidi)
     (format (string-append
              "            {~s, ~s, grpcdc::Server::~a,\n"
              "             [&impl](const grpcdc::Endpoint::CallContext& ctx,\n"
              "                     grpcdc::Server::RequestStream& reqs,\n"
              "                     grpcdc::Server::ServerSink& sink) {\n"
              "               ~a~aServerImpl stream(\n"
              "                   const_cast<grpcdc::Endpoint::CallContext&>(ctx), reqs, sink);\n"
              "               impl.~a(stream);\n"
              "             }},\n")
             name (hash-ref m 'path) kind-const svc name impl-name)]))

(define (cpp-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "  /// Client for ~a.\n" (hash-ref svc 'full-name))
     (format "  class ~aClient {\n" sname)
     "   public:\n"
     (format "    explicit ~aClient(std::shared_ptr<grpcdc::Channel> channel)\n        : channel_(std::move(channel)) {}\n\n" sname)
     (apply string-append (map cpp-client-stream-class methods))
     (apply string-append (map cpp-client-method (append methods (alias-client-methods svc))))
     "    // -- async (std::future) surface -------------------------------------\n\n"
     (apply string-append (map cpp-client-async-method (append methods (alias-client-methods svc))))
     "   private:\n    std::shared_ptr<grpcdc::Channel> channel_;\n  };\n\n"
     (apply string-append (map cpp-server-stream-iface methods))
     (format "  /// Service implementation interface for ~a.\n" (hash-ref svc 'full-name))
     (format "  struct ~aServer {\n    virtual ~~~aServer() = default;\n" sname sname)
     (apply string-append (map cpp-server-iface-method methods))
     "  };\n\n"
     (format "  /// Async service implementation interface for ~a.\n" (hash-ref svc 'full-name))
     (format "  struct ~aServerAsync {\n    virtual ~~~aServerAsync() = default;\n" sname sname)
     (apply string-append (map cpp-server-async-iface-method methods))
     "  };\n\n"
     " private:\n"
     (apply string-append (map cpp-stream-impl methods))
     (format "  class ~aServerAsyncAdapter : public ~aServer {\n" sname sname)
     (format "   public:\n    explicit ~aServerAsyncAdapter(~aServerAsync* impl) : impl_(impl) {}\n" sname sname)
     (apply string-append (map cpp-server-async-adapter-method methods))
     (format "\n   private:\n    ~aServerAsync* impl_;\n  };\n\n" sname)
     " public:\n"
     (format "  /// Register an implementation of ~a on a Server.\n" (hash-ref svc 'full-name))
     (format "  static void Register~aServer(grpcdc::Server& server, ~aServer& impl) {\n" sname sname)
     (format "    server.RegisterService(grpcdc::Server::ServiceDesc{\n        ~s,\n        {\n"
             (hash-ref svc 'full-name))
     (apply string-append (map cpp-register-method (append methods (alias-server-methods svc))))
     "        }});\n  }\n\n"
     (format "  /// Register an async implementation of ~a on a Server.\n" (hash-ref svc 'full-name))
     (format "  static void Register~aServerAsync(grpcdc::Server& server,\n                                      ~aServerAsync& impl) {\n" sname sname)
     "    // Adapters are retained for the process lifetime: registration is\n"
     "    // once-per-process and bounded by service count.\n"
     (format "    static std::vector<std::shared_ptr<~aServerAsyncAdapter>> adapters;\n" sname)
     (format "    auto adapter = std::make_shared<~aServerAsyncAdapter>(&impl);\n" sname)
     "    adapters.push_back(adapter);\n"
     (format "    Register~aServer(server, *adapter);\n  }\n" sname))))

(define (emit-cpp-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define struct-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define ns (if (string=? pkg "") "proto" pkg))
  (cons (string-append base "_grpc_dc.hpp")
        (string-append
         "// @generated by protoc-gen-grpc-dc-cpp (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         "#pragma once\n\n"
         "#include <future>\n"
         "#include <memory>\n"
         "#include <vector>\n\n"
         (format "#include \"examples/~a_messages.hpp\"\n" base)
         "#include \"grpcdc/channel.hpp\"\n"
         "#include \"grpcdc/server.hpp\"\n\n"
         (format "namespace ~a {\n\n" ns)
         (format "/// Generated gRPC-over-DataChannels stubs for ~a.\n" (hash-ref file-model 'name))
         (format "struct ~a {\n" struct-name)
         (apply string-append
                (map cpp-service (hash-ref file-model 'services)))
         "};\n\n"
         (format "}  // namespace ~a\n" ns))))
