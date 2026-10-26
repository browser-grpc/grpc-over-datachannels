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
              "                       const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      ~a resp;\n"
              "      channel_->Unary(~s, req, resp, metadata, timeout);\n"
              "      return resp;\n"
              "    }\n\n")
             resp name req resp path)]
    [(server-streaming)
     (format (string-append
              "    ~a~aStream ~a(\n"
              "        ~a req, const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      return ~a~aStream(\n"
              "          channel_->ServerStream(~s, req, metadata, timeout));\n"
              "    }\n\n")
             svc name name req svc name path)]
    [(client-streaming)
     (format (string-append
              "    ~a ~a(std::vector<~a> reqs,\n"
              "                              const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      std::vector<const grpcdc::Marshaler*> ptrs;\n"
              "      for (auto& r : reqs) ptrs.push_back(&r);\n"
              "      ~a resp;\n"
              "      channel_->ClientStreamCall(~s, ptrs, resp, metadata, timeout);\n"
              "      return resp;\n"
              "    }\n\n")
             resp name req resp path)]
    [(bidi)
     (format (string-append
              "    ~a~aStream ~a(std::vector<~a> reqs,\n"
              "                        const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      std::vector<const grpcdc::Marshaler*> ptrs;\n"
              "      for (auto& r : reqs) ptrs.push_back(&r);\n"
              "      return ~a~aStream(channel_->Bidi(~s, ptrs, metadata, timeout));\n"
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
              "      /// Initial metadata (response headers).\n"
              "      const grpcdc::Metadata& Headers() const { return stream_.headers().metadata; }\n\n"
              "      /// Trailing metadata of the terminal status.\n"
              "      const grpcdc::Metadata& Trailers() const { return stream_.trailers(); }\n\n"
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
              "        ~a req, const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      return std::async(std::launch::async,\n"
              "                        [this, req, metadata, timeout] { return ~a(req, metadata, timeout); });\n"
              "    }\n\n")
             resp name req name)]
    [(server-streaming)
     (format (string-append
              "    std::future<std::vector<~a>> ~aAsync(\n"
              "        ~a req, const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      return std::async(std::launch::async, [this, req, metadata, timeout] {\n"
              "        auto stream = ~a(req, metadata, timeout);\n"
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
              "        const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      return std::async(\n"
              "          std::launch::async,\n"
              "          [this, reqs, metadata, timeout] { return ~a(reqs, metadata, timeout); });\n"
              "    }\n\n")
             resp name req name)]
    [(bidi)
     (format (string-append
              "    std::future<std::vector<~a>> ~aAsync(\n"
              "        std::vector<~a> reqs,\n"
              "        const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      return std::async(std::launch::async, [this, reqs, metadata, timeout] {\n"
              "        auto stream = ~a(reqs, metadata, timeout);\n"
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

(define (cpp-client-coro-stream-class m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming bidi)
     (format (string-append
              "    class ~a~aStream {\n"
              "     public:\n"
              "      explicit ~a~aStream(grpcdc::AsyncClientStream stream)\n"
              "          : stream_(std::move(stream)) {}\n"
              "      /// Next response, or std::nullopt when the call completed OK.\n"
              "      grpcdc::Task<std::optional<~a>> Recv() {\n"
              "        ~a resp;\n"
              "        try {\n"
              "          co_await stream_.Recv(resp);\n"
              "        } catch (const grpcdc::EndOfStream&) {\n"
              "          co_return std::nullopt;\n"
              "        }\n"
              "        co_return resp;\n"
              "      }\n"
              "      void Cancel() { stream_.Cancel(); }\n"
              "\n"
              "     private:\n"
              "      grpcdc::AsyncClientStream stream_;\n"
              "    };\n\n")
             svc name svc name resp resp)]
    [else ""]))

(define (cpp-client-coro-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    grpcdc::Task<~a> ~a(~a req,\n"
              "                       const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      ~a resp;\n"
              "      co_await channel_->Unary(~s, req, resp, metadata, timeout);\n"
              "      co_return resp;\n"
              "    }\n\n")
             resp name req resp path)]
    [(server-streaming)
     (format (string-append
              "    grpcdc::Task<~a~aStream> ~a(\n"
              "        ~a req, const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      co_return ~a~aStream(\n"
              "          co_await channel_->ServerStream(~s, req, metadata, timeout));\n"
              "    }\n\n")
             svc name name req svc name path)]
    [(client-streaming)
     (format (string-append
              "    grpcdc::Task<~a> ~a(std::vector<~a> reqs,\n"
              "                              const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      std::vector<const grpcdc::Marshaler*> ptrs;\n"
              "      for (auto& r : reqs) ptrs.push_back(&r);\n"
              "      ~a resp;\n"
              "      co_await channel_->ClientStreamCall(~s, ptrs, resp, metadata, timeout);\n"
              "      co_return resp;\n"
              "    }\n\n")
             resp name req resp path)]
    [(bidi)
     (format (string-append
              "    grpcdc::Task<~a~aStream> ~a(std::vector<~a> reqs,\n"
              "                        const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n"
              "      std::vector<const grpcdc::Marshaler*> ptrs;\n"
              "      for (auto& r : reqs) ptrs.push_back(&r);\n"
              "      co_return ~a~aStream(\n"
              "          co_await channel_->Bidi(~s, ptrs, metadata, timeout));\n"
              "    }\n\n")
             svc name name req svc name path)]))

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
     "#if __cplusplus >= 202002L\n"
     (format "  /// C++20 coroutine client for ~a (co_await / grpcdc::Task).\n" (hash-ref svc 'full-name))
     (format "  class ~aClientCoro {\n" sname)
     "   public:\n"
     (format "    explicit ~aClientCoro(std::shared_ptr<grpcdc::AsyncChannel> channel)\n        : channel_(std::move(channel)) {}\n" sname)
     (format "    explicit ~aClientCoro(std::shared_ptr<grpcdc::Channel> channel)\n        : channel_(std::make_shared<grpcdc::AsyncChannel>(std::move(channel))) {}\n\n" sname)
     (apply string-append (map cpp-client-coro-stream-class (append methods (alias-client-methods svc))))
     (apply string-append (map cpp-client-coro-method (append methods (alias-client-methods svc))))
     "   private:\n    std::shared_ptr<grpcdc::AsyncChannel> channel_;\n  };\n"
     "#endif  // __cplusplus >= 202002L\n\n"
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

;; ---------------------------------------------------------------------------
;; C++ message types (<base>_messages.hpp, matching the stub's
;; include): classes implementing grpcdc::Marshaler/Unmarshaler
;; plus a pb_<base> wire-support namespace per proto file.
;; Dependency-free (std only). Mirrors the Java emitter on the
;; shared desc.rkt model.
;; ---------------------------------------------------------------------------

(define cpp-pb-varint-types '(5 3 13 4 17 18 8 14))
(define cpp-pb-fixed '((2 4 "Float") (1 8 "Double") (7 4 "Int32") (15 4 "Int32") (6 8 "Int64") (16 8 "Int64")))

(define (cpp-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-cpp-pb-file "unresolved type ~a" type-name))))

(define (cpp-pb-ns pkg)
  (if (string=? pkg "") "proto" (string-join (string-split pkg ".") "::")))

(define (cpp-pb-rel pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "::"))

(define (cpp-pb-entry-ref model entry)
  (define rel
    (if (eq? (hash-ref entry 'kind) 'enum)
        (let ([e (hash-ref entry 'enum)])
          (if (hash-ref entry 'msg)
              (string-append (cpp-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)) "::" (hash-ref e 'name))
              (cpp-pb-rel (hash-ref entry 'pkg) (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name)))))
        (cpp-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (equal? (hash-ref entry 'file) (hash-ref model 'name))
      rel
      (string-append "::" (cpp-pb-ns (hash-ref entry 'pkg)) "::" rel)))

(define (cpp-pb-scalar f)
  (case (hash-ref f 'type)
    [(1) '("double" "0")] [(2) '("float" "0")] [(3) '("std::int64_t" "0")] [(4) '("std::uint64_t" "0")]
    [(5) '("std::int32_t" "0")] [(6) '("std::uint64_t" "0")] [(7) '("std::uint32_t" "0")]
    [(8) '("bool" "false")] [(9) '("std::string" "\"\"")] [(12) '("std::vector<std::uint8_t>" "{}")]
    [(13) '("std::uint32_t" "0")] [(15) '("std::int32_t" "0")] [(16) '("std::int64_t" "0")]
    [(17) '("std::int32_t" "0")] [(18) '("std::int64_t" "0")]
    [else #f]))

(define (cpp-pb-type model f)
  (define type (hash-ref f 'type))
  (define singular
    (cond [(= type 11)
           (define entry (cpp-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (let* ([em (hash-ref entry 'msg)]
                      [kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields))]
                      [vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields))])
                 (format "std::map<~a, ~a>" (cpp-pb-type model (hash-set kf 'label 1))
                         (if (= (hash-ref vf 'type) 11)
                             (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref vf 'type-name)))
                             (cpp-pb-type model (hash-set vf 'label 1)))))
               (format "std::optional<~a>" (cpp-pb-entry-ref model entry)))]
          [(= type 14) (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref f 'type-name)))]
          [else (first (cpp-pb-scalar f))]))
  (cond [(and (= type 11)
              (eq? (hash-ref (cpp-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         singular]
        [(= (hash-ref f 'label) 3)
         (if (= type 11)
             (format "std::vector<~a>" (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref f 'type-name))))
             (format "std::vector<~a>" (cpp-pb-type model (hash-set f 'label 1))))]
        [else singular]))

(define (cpp-pb-explicit-literal model f)
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(8) d]
         [(14) (format "~a::~a" (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref f 'type-name))) d)]
         [(2) (format "~a" d)]
         [else d])))

(define (cpp-pb-default model f)
  (cond [(cpp-pb-explicit-literal model f) => (lambda (lit) lit)]
        [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (cpp-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         "{}"]
        [(= (hash-ref f 'label) 3) "{}"]
        [(= (hash-ref f 'type) 11) "std::nullopt"]
        [(= (hash-ref f 'type) 14)
         (define entry (cpp-pb-resolve model (hash-ref f 'type-name)))
         (format "~a::~a" (cpp-pb-entry-ref model entry) (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'name))]
        [else (second (cpp-pb-scalar f))]))

(define (cpp-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a ? 1 : 0)" v)]
    [(17) (format "static_cast<std::uint64_t>((~a << 1) ^ (~a >> 31))" v v)]
    [(18) (format "static_cast<std::uint64_t>((~a << 1) ^ (~a >> 63))" v v)]
    [(14) (format "static_cast<std::int32_t>(~a)" v)]
    [(5) (format "static_cast<std::int64_t>(~a)" v)]
    [else (format "static_cast<std::uint64_t>(~a)" v)]))

(define (cpp-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "static_cast<std::int32_t>(~a)" v)]
    [(13 7) (format "static_cast<std::uint32_t>(~a)" v)]
    [(3) (format "static_cast<std::int64_t>(~a)" v)]
    [(4 6) v]
    [(8) (format "~a != 0" v)]
    [(17) (format "static_cast<std::int32_t>((~a >> 1) ^ -static_cast<std::int64_t>(~a & 1))" v v)]
    [(18) (format "static_cast<std::int64_t>((~a >> 1) ^ -static_cast<std::int64_t>(~a & 1))" v v)]))

(define (cpp-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [(14) (format "static_cast<std::int32_t>(~a) != 0" v)]
    [else (format "~a != 0" v)]))

(define (cpp-pb-encode-singular model f v indent support)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type cpp-pb-varint-types)
         (if proto2?
             (format "~a{ w.Tag(~a, 0); w.Varint(~a); }\n" indent n (cpp-pb-varint-expr f v))
             (format "~aif (~a) { w.Tag(~a, 0); w.Varint(~a); }\n" indent (cpp-pb-nonzero f v) n (cpp-pb-varint-expr f v)))]
        [(assv type cpp-pb-fixed)
         => (lambda (info)
              (if proto2?
                  (format "~a{ w.Tag(~a, ~a); w.Fixed~a(~a); }\n" indent n
                          (if (= (second info) 8) 1 5) (third info) v)
                  (format "~aif (~a) { w.Tag(~a, ~a); w.Fixed~a(~a); }\n" indent (cpp-pb-nonzero f v) n
                          (if (= (second info) 8) 1 5) (third info) v)))]
        [(= type 9)
         (if proto2?
             (format "~aw.BytesField(~a, grpcdc::Bytes(~a.begin(), ~a.end()));\n" indent n v v)
             (format "~aw.StringField(~a, ~a);\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~aw.BytesField(~a, ~a);\n" indent n v)
             (format "~aif (!~a.empty()) w.BytesField(~a, ~a);\n" indent v n v))]
        [(= type 11) (format "~aif (~a) w.BytesField(~a, ~a->MarshalDc());\n" indent v n v)]
        [else (error 'emit-cpp-pb-file "unsupported field type ~a (groups)" type)]))

(define (cpp-pb-set-expr sib)
  (define v (hash-ref sib 'name))
  (case (hash-ref sib 'type)
    [(11 10) (format "~a.has_value()" v)]
    [(9 12) (format "!~a.empty()" v)]
    [else (cpp-pb-nonzero sib v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (cpp-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "    if (!(~a)) {\n~a    }\n"
              (string-join (map cpp-pb-set-expr later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (cpp-pb-encode-field model f support)
  (define v (hash-ref f 'name))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (cpp-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (cpp-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a::~aEncode" support (cpp-pb-map-helper-name model entry)))
         (format "    if (!~a.empty()) for (const auto& e : ~a) w.BytesField(~a, ~a(e.first, e.second));\n" v v n helper)]
        [(not (= (hash-ref f 'label) 3)) (cpp-pb-encode-singular model f v "    " support)]
        [(memv type cpp-pb-varint-types)
         (string-append
          (format "    if (!~a.empty()) {\n" v)
          (format "        ~a::Writer payload;\n" support)
          (format "        for (auto x : ~a) payload.Varint(~a);\n" v (cpp-pb-varint-expr f "x"))
          (format "        w.BytesField(~a, payload.ToBytes());\n    }\n" n))]
        [(assv type cpp-pb-fixed)
         => (lambda (info)
              (string-append
               (format "    if (!~a.empty()) {\n" v)
               (format "        ~a::Writer payload;\n" support)
               (format "        for (auto x : ~a) payload.Fixed~a(x);\n" v (third info))
               (format "        w.BytesField(~a, payload.ToBytes());\n    }\n" n)))]
        [(= type 9) (format "    for (const auto& x : ~a) w.BytesField(~a, grpcdc::Bytes(x.begin(), x.end()));\n" v n)]
        [(= type 12) (format "    for (const auto& x : ~a) w.BytesField(~a, x);\n" v n)]
        [(= type 11) (format "    for (const auto& x : ~a) w.BytesField(~a, x.MarshalDc());\n" v n)]
        [else (error 'emit-cpp-pb-file "unsupported repeated field type ~a" type)]))

(define (cpp-pb-decode-singular model f target src indent support)
  (define type (hash-ref f 'type))
  (cond [(memv type cpp-pb-varint-types)
         (format "~a~a = ~a;\n" indent target
                 (if (= type 14)
                     (format "static_cast<~a>(~a)" (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref f 'type-name))) (cpp-pb-varint-decode (hash-set f 'type 5) src))
                     (cpp-pb-varint-decode f src)))]
        [(assv type cpp-pb-fixed)
         => (lambda (info)
              (format "~a~a = ~a;\n" indent target
                      (case (hash-ref f 'type)
                        [(2) (format "~a::BitsToFloat(static_cast<std::uint32_t>(~a))" support src)]
                        [(1) (format "~a::BitsToDouble(~a)" support src)]
                        [(7) (format "static_cast<std::uint32_t>(~a)" src)]
                        [(15) (format "static_cast<std::int32_t>(~a)" src)]
                        [else src])))]
        [(= type 9) (format "~a~a = std::string(~a.begin(), ~a.end());\n" indent target src src)]
        [(= type 12) (format "~a~a = ~a;\n" indent target src)]
        [(= type 11)
         (define ref (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a.emplace();\n" indent target)
          (format "~a~a->UnmarshalDc(~a);\n" indent target src))]
        [else (error 'emit-cpp-pb-file "unsupported field type ~a" type)]))

(define (cpp-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "            ~a = ~a;\n" (hash-ref sib 'name) (cpp-pb-default model sib)))
              (oneof-siblings model f))))

(define (cpp-pb-decode-case model f support)
  (define v (hash-ref f 'name))
  (define type (hash-ref f 'type))
  (define head (format "        case ~a: {\n" (hash-ref f 'number)))
  (define clearing (cpp-pb-oneof-clearing model f))
  (define tail "            break;\n        }\n")
  (cond [(and (= type 11)
              (eq? (hash-ref (cpp-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (cpp-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a::~aDecode" support (cpp-pb-map-helper-name model entry)))
         (string-append head
                        (format "            auto kv = ~a(field.bytes);\n" helper)
                        (format "            ~a[kv.first] = kv.second;\n" v)
                        tail)]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        clearing
                        (cpp-pb-decode-singular model f v
                                                (cond [(memv type cpp-pb-varint-types) "field.varint"]
                                                      [(assv type cpp-pb-fixed) "field.fixed"]
                                                      [else "field.bytes"])
                                                "            " support)
                        tail)]
        [(memv type cpp-pb-varint-types)
         (string-append head
                        "            if (field.wire == 2) {\n"
                        (format "                ~a::Reader sub(field.bytes);\n" support)
                        "                while (!sub.Done()) {\n"
                        (format "                    ~a.push_back(~a);\n" v
                                (let ([conv (cpp-pb-varint-decode f "sub.Varint()")])
                                  (if (= type 14)
                                      (format "static_cast<~a>(~a)" (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref f 'type-name))) (cpp-pb-varint-decode (hash-set f 'type 5) "sub.Varint()"))
                                      conv)))
                        "                }\n            } else {\n"
                        (format "                ~a.push_back(~a);\n" v
                                (let ([conv (cpp-pb-varint-decode f "field.varint")])
                                  (if (= type 14)
                                      (format "static_cast<~a>(~a)" (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref f 'type-name))) (cpp-pb-varint-decode (hash-set f 'type 5) "field.varint"))
                                      conv)))
                        "            }\n" tail)]
        [(assv type cpp-pb-fixed)
         => (lambda (info)
              (string-append head
                             "            if (field.wire == 2) {\n"
                             (format "                ~a::Reader sub(field.bytes);\n" support)
                             (format "                while (!sub.Done()) ~a.push_back(~a);\n" v
                                     (case (hash-ref f 'type)
                                       [(2) (format "~a::BitsToFloat(sub.Fixed32())" support)]
                                       [(1) (format "~a::BitsToDouble(sub.Fixed64())" support)]
                                       [(7) "static_cast<std::uint32_t>(sub.Fixed32())"]
                                       [(15) "sub.Fixed32()"]
                                       [else "sub.Fixed64()"]))
                             "            } else {\n"
                             (format "                ~a.push_back(~a);\n" v
                                     (case (hash-ref f 'type)
                                       [(2) (format "~a::BitsToFloat(static_cast<std::uint32_t>(field.fixed))" support)]
                                       [(1) (format "~a::BitsToDouble(field.fixed)" support)]
                                       [(7) "static_cast<std::uint32_t>(field.fixed)"]
                                       [(15) "static_cast<std::int32_t>(field.fixed)"]
                                       [else "field.fixed"]))
                             "            }\n" tail))]
        [(= type 9) (string-append head (format "            ~a.push_back(std::string(field.bytes.begin(), field.bytes.end()));\n" v) tail)]
        [(= type 12) (string-append head (format "            ~a.push_back(field.bytes);\n" v) tail)]
        [(= type 11)
         (string-append head
                        (format "            ~a item;\n" (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref f 'type-name))))
                        "            item.UnmarshalDc(field.bytes);\n"
                        (format "            ~a.push_back(item);\n" v) tail)]
        [else (error 'emit-cpp-pb-file "unsupported repeated field type ~a" type)]))

(define (cpp-pb-map-helper-name model entry)
  (define rel (cpp-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)))
  (string-join (string-split rel "::") ""))

(define (cpp-pb-map-helpers model entry support)
  (define msg (hash-ref entry 'msg))
  (define base (cpp-pb-map-helper-name model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-cpp-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (define kt (cpp-pb-type model (hash-set key-f 'label 1)))
  (define vt (cpp-pb-type model (hash-set val-f 'label 1)))
  ;; Message-typed values are optional<T> in field position; map
  ;; values use plain T.
  (define vt-plain (if (and (= (hash-ref val-f 'type) 11)
                            (not (eq? (hash-ref (cpp-pb-resolve model (hash-ref val-f 'type-name)) 'kind) 'map)))
                       (cpp-pb-entry-ref model (cpp-pb-resolve model (hash-ref val-f 'type-name)))
                       vt))
  (cons
   (string-append
    (format "inline grpcdc::Bytes ~aEncode(const ~a& key, const ~a& value);\n" base kt vt-plain)
    (format "inline std::pair<~a, ~a> ~aDecode(const grpcdc::Bytes& bytes);\n" kt vt-plain base))
   (string-append
   (format "inline grpcdc::Bytes ~aEncode(const ~a& key, const ~a& value) {\n" base kt vt-plain)
   "    Writer w;\n"
   (cpp-pb-encode-singular model (hash-set key-f 'label 1) "key" "    " support)
   (if (= (hash-ref val-f 'type) 11)
       (format "    w.BytesField(~a, value.MarshalDc());\n" (hash-ref val-f 'number))
       (cpp-pb-encode-singular model (hash-set val-f 'label 1) "value" "    " support))
   "    return w.ToBytes();\n}\n\n"
   (format "inline std::pair<~a, ~a> ~aDecode(const grpcdc::Bytes& bytes) {\n" kt vt-plain base)
   (format "    ~a key = ~a;\n" kt (cpp-pb-default model (hash-set key-f 'label 1)))
   (format "    ~a value~a;\n" vt-plain (if (= (hash-ref val-f 'type) 11) "" (string-append " = " (cpp-pb-default model (hash-set val-f 'label 1)))))
   "    Reader r(bytes);\n    Field field;\n    while (r.Next(field)) {\n        switch (field.number) {\n"
   (format "            case ~a: ~a break;\n" (hash-ref key-f 'number)
           (string-trim (cpp-pb-decode-singular model (hash-set key-f 'label 1) "key"
                                                (cond [(memv (hash-ref key-f 'type) cpp-pb-varint-types) "field.varint"]
                                                      [(assv (hash-ref key-f 'type) cpp-pb-fixed) "field.fixed"]
                                                      [else "field.bytes"]) "" support) "\n" #:left? #f #:repeat? #t))
   (format "            case ~a: ~a break;\n" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               "value.UnmarshalDc(field.bytes);"
               (string-trim (cpp-pb-decode-singular model (hash-set val-f 'label 1)
                                                    "value"
                                                    (cond [(memv (hash-ref val-f 'type) cpp-pb-varint-types) "field.varint"]
                                                          [(assv (hash-ref val-f 'type) cpp-pb-fixed) "field.fixed"]
                                                          [else "field.bytes"]) "" support) "\n" #:left? #f #:repeat? #t)))
   "            default: break;\n        }\n    }\n    return {key, value};\n}\n\n")))

(define (cpp-pb-support-open base pkg deps)
  (string-append
   "// @generated by protoc-gen-grpc-dc-cpp. DO NOT EDIT.\n"
   "#pragma once\n\n"
   "#include <cstdint>\n#include <cstring>\n#include <map>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <utility>\n#include <vector>\n\n"
   "#include \"grpcdc/transport.hpp\"\n"
   (apply string-append
          (map (lambda (d)
                 (format "#include \"~a_messages.hpp\"\n"
                         (path->string (path-replace-extension (file-name-from-path d) ""))))
               deps))
   "\n"
   (format "namespace ~a {\n\n" (cpp-pb-ns pkg))))

(define (cpp-pb-support base pkg helpers)
  (string-append
   (format "namespace pb_~a {\n\n" base)
   "class Writer {\n"
   "    grpcdc::Bytes out_;\n"
   "public:\n"
   "    void Varint(std::uint64_t v) { while (v > 0x7f) { out_.push_back(static_cast<std::uint8_t>((v & 0x7f) | 0x80)); v >>= 7; } out_.push_back(static_cast<std::uint8_t>(v)); }\n"
   "    void Tag(int field, int wire) { Varint(static_cast<std::uint64_t>((field << 3) | wire)); }\n"
   "    void BytesField(int field, const grpcdc::Bytes& payload) { Tag(field, 2); Varint(payload.size()); out_.insert(out_.end(), payload.begin(), payload.end()); }\n"
   "    void StringField(int field, const std::string& value) { if (value.empty()) return; BytesField(field, grpcdc::Bytes(value.begin(), value.end())); }\n"
   "    void FixedInt32(std::int32_t v) { std::uint32_t u = static_cast<std::uint32_t>(v); for (int i = 0; i < 4; i++) out_.push_back(static_cast<std::uint8_t>((u >> (8 * i)) & 0xff)); }\n"
   "    void FixedInt64(std::int64_t v) { std::uint64_t u = static_cast<std::uint64_t>(v); for (int i = 0; i < 8; i++) out_.push_back(static_cast<std::uint8_t>((u >> (8 * i)) & 0xff)); }\n"
   "    void FixedFloat(float v) { std::uint32_t u; std::memcpy(&u, &v, 4); FixedInt32(static_cast<std::int32_t>(u)); }\n"
   "    void FixedDouble(double v) { std::uint64_t u; std::memcpy(&u, &v, 8); FixedInt64(static_cast<std::int64_t>(u)); }\n"
   "    void Raw(const grpcdc::Bytes& payload) { out_.insert(out_.end(), payload.begin(), payload.end()); }\n"
   "    grpcdc::Bytes ToBytes() const { return out_; }\n"
   "};\n\n"
   "inline float BitsToFloat(std::uint32_t u) { float v; std::memcpy(&v, &u, 4); return v; }\n"
   "inline double BitsToDouble(std::uint64_t u) { double v; std::memcpy(&v, &u, 8); return v; }\n\n"
   "struct Field {\n"
   "    int number = 0; int wire = 0; std::uint64_t varint = 0; grpcdc::Bytes bytes; std::uint64_t fixed = 0; grpcdc::Bytes raw;\n"
   "};\n\n"
   "class Reader {\n"
   "    grpcdc::Bytes buf_; std::size_t pos_ = 0;\n"
   "public:\n"
   "    explicit Reader(const grpcdc::Bytes& buf) : buf_(buf) {}\n"
   "    bool Done() const { return pos_ >= buf_.size(); }\n"
   "    std::uint64_t Varint() { std::uint64_t result = 0; int shift = 0; while (true) { if (pos_ >= buf_.size()) throw std::invalid_argument(\"truncated varint\"); std::uint8_t b = buf_[pos_++]; result |= static_cast<std::uint64_t>(b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) throw std::invalid_argument(\"varint too long\"); } }\n"
   "    grpcdc::Bytes Take(std::size_t n) { if (pos_ + n > buf_.size()) throw std::invalid_argument(\"truncated field\"); grpcdc::Bytes v(buf_.begin() + pos_, buf_.begin() + pos_ + n); pos_ += n; return v; }\n"
   "    std::uint32_t Fixed32() { auto b = Take(4); return static_cast<std::uint32_t>(b[0]) | (static_cast<std::uint32_t>(b[1]) << 8) | (static_cast<std::uint32_t>(b[2]) << 16) | (static_cast<std::uint32_t>(b[3]) << 24); }\n"
   "    std::uint64_t Fixed64() { auto b = Take(8); std::uint64_t v = 0; for (int i = 0; i < 8; i++) v |= static_cast<std::uint64_t>(b[i]) << (8 * i); return v; }\n"
   "    bool Next(Field& field) {\n"
   "        if (pos_ >= buf_.size()) return false;\n"
   "        std::size_t start = pos_;\n"
   "        std::uint64_t tag = Varint(); field.number = static_cast<int>(tag >> 3); field.wire = static_cast<int>(tag & 7);\n"
   "        switch (field.wire) {\n"
   "            case 0: field.varint = Varint(); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true;\n"
   "            case 2: { std::size_t n = static_cast<std::size_t>(Varint()); field.bytes = Take(n); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true; }\n"
   "            case 1: field.bytes = Take(8); field.fixed = 0; for (int i = 0; i < 8; i++) field.fixed |= static_cast<std::uint64_t>(field.bytes[i]) << (8 * i); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true;\n"
   "            case 5: field.bytes = Take(4); field.fixed = static_cast<std::uint32_t>(field.bytes[0]) | (static_cast<std::uint32_t>(field.bytes[1]) << 8) | (static_cast<std::uint32_t>(field.bytes[2]) << 16) | (static_cast<std::uint32_t>(field.bytes[3]) << 24); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true;\n"
   "            default: throw std::invalid_argument(\"bad wire type\");\n"
   "        }\n"
   "    }\n"
   "};\n\n"
   helpers
   (format "}  // namespace pb_~a\n\n" base)))

(define (cpp-pb-message-class model msg support indent)
  (define name (hash-ref msg 'name))
  (define fields (hash-ref msg 'fields))
  (define pad indent)
  (string-append
   (format "~aclass ~a : public grpcdc::Marshaler, public grpcdc::Unmarshaler {\n~a public:\n" pad name pad)
   ;; Nested enums and message classes come first: fields below
   ;; hold them by value (std::optional) and use their defaults,
   ;; so they must be declared and complete before the fields.
   (apply string-append (map (lambda (e) (cpp-pb-nested-enum e (string-append indent "  "))) (hash-ref msg 'enums)))
   (apply string-append (map (lambda (n) (cpp-pb-message-class model n support (string-append indent "  "))) (hash-ref msg 'nested)))
   (apply string-append
          (map (lambda (f)
                 (format "~a  ~a ~a = ~a;\n" pad (cpp-pb-type model f) (hash-ref f 'name) (cpp-pb-default model f)))
               fields))
   (format "~a  grpcdc::Bytes unknown_fields;\n" pad)
   (format "~a  ~a() = default;\n" pad name)
   ;; Bodies are defined out of line after all classes (see
   ;; cpp-pb-message-impls): the map helpers they call name
   ;; nested types, so the helpers can only be declared once
   ;; every class has been declared.
   (format "~a  grpcdc::Bytes MarshalDc() const override;\n" pad)
   (format "~a  void UnmarshalDc(const grpcdc::Bytes& data) override;\n" pad)
   (format "~a};\n" pad)))

;; Out-of-line MarshalDc/UnmarshalDc definitions for a message
;; class and its nested classes, emitted after all class
;; declarations and the map helper declarations.
(define (cpp-pb-message-impls model msg support qual)
  (define name (hash-ref msg 'name))
  (define fields (hash-ref msg 'fields))
  (define q (if (string=? qual "") name (string-append qual "::" name)))
  (string-append
   (format "inline grpcdc::Bytes ~a::MarshalDc() const {\n" q)
   (format "    ~a::Writer w;\n" support)
   (apply string-append (map (lambda (f) (cpp-pb-encode-guard model f (cpp-pb-encode-field model f support))) fields))
   "    w.Raw(unknown_fields);\n"
   "    return w.ToBytes();\n}\n\n"
   (format "inline void ~a::UnmarshalDc(const grpcdc::Bytes& data) {\n" q)
   "    unknown_fields.clear();\n"
   (apply string-append
          (map (lambda (f) (format "    ~a = ~a;\n" (hash-ref f 'name) (cpp-pb-default model f))) fields))
   (format "    ~a::Reader r(data);\n" support)
   (format "    ~a::Field field;\n" support)
   "    while (r.Next(field)) {\n      switch (field.number) {\n"
   (apply string-append (map (lambda (f) (cpp-pb-decode-case model f support)) fields))
   "        default: unknown_fields.insert(unknown_fields.end(), field.raw.begin(), field.raw.end()); break;\n      }\n    }\n}\n\n"
   (apply string-append
          (map (lambda (n) (cpp-pb-message-impls model n support q))
               (filter (lambda (n) (not (hash-ref n 'map-entry))) (hash-ref msg 'nested))))))

(define (cpp-pb-nested-enum e indent)
  (string-append
   (format "~aenum class ~a : std::int32_t {\n" indent (hash-ref e 'name))
   (string-join (map (lambda (v) (format "~a  ~a = ~a" indent (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) ",\n")
   (format "\n~a};\n" indent)))

(define (emit-cpp-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-cpp-pb-file/inner file-model)))

;; Top-level messages ordered so same-file by-value dependencies
;; (singular message fields held as std::optional, map values)
;; are defined before their users — C++ requires complete types
;; for those members regardless of proto declaration order.
(define (cpp-pb-ordered-messages file-model messages)
  (define tops (filter (lambda (m) (not (hash-ref m 'map-entry))) messages))
  (define (top-of e)
    (and (equal? (hash-ref e 'file) (hash-ref file-model 'name))
         (car (string-split (cpp-pb-rel (hash-ref file-model 'package) (hash-ref e 'full)) "::"))))
  (define (deps m)
    (define out '())
    (define (note f)
      (when (= (hash-ref f 'type) 11)
        (define e (cpp-pb-resolve file-model (hash-ref f 'type-name)))
        (cond [(eq? (hash-ref e 'kind) 'map)
               (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2))
                                    (hash-ref (hash-ref e 'msg) 'fields)))
               (when (= (hash-ref val-f 'type) 11)
                 (define ve (cpp-pb-resolve file-model (hash-ref val-f 'type-name)))
                 (when (eq? (hash-ref ve 'kind) 'message)
                   (define t (top-of ve))
                   (when t (set! out (cons t out)))))]
              [(and (eq? (hash-ref e 'kind) 'message) (not (= (hash-ref f 'label) 3)))
               (define t (top-of e))
               (when t (set! out (cons t out)))])))
    (define (walk msg)
      (for ([f (in-list (hash-ref msg 'fields))]) (note f))
      (for ([n (in-list (hash-ref msg 'nested))]) (walk n)))
    (walk m)
    (remove-duplicates (reverse out)))
  (define dep-map (map (lambda (m) (cons (hash-ref m 'name) (deps m))) tops))
  (define remaining (list->mutable-set (map (lambda (m) (hash-ref m 'name)) tops)))
  (define (ready? m)
    (andmap (lambda (d) (or (equal? d (hash-ref m 'name)) (not (set-member? remaining d))))
            (cdr (assoc (hash-ref m 'name) dep-map))))
  (let loop ([ms tops] [out '()])
    (cond [(null? ms) (reverse out)]
          [else
           (define next (findf ready? ms))
           (unless next (error 'emit-cpp-pb-file "message dependency cycle"))
           (set-remove! remaining (hash-ref next 'name))
           (loop (remq next ms) (cons next out))])))

(define (emit-cpp-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pkg (hash-ref file-model 'package))
         (define support (format "pb_~a" base))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (cpp-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (cpp-pb-map-helpers file-model e support) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define ordered (cpp-pb-ordered-messages file-model messages))
         (define content
           (string-append
            (cpp-pb-support-open base pkg (hash-ref file-model 'dependencies))
            (apply string-append
                   (map (lambda (m) (format "class ~a;\n" (hash-ref m 'name)))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            "\n"
            ;; Top-level enums precede the support block: its map
            ;; helper declarations name enum value types.
            (apply string-append
                   (map (lambda (e)
                          (string-append
                           (format "enum class ~a : std::int32_t {\n" (hash-ref e 'name))
                           (string-join (map (lambda (v) (format "  ~a = ~a" (hash-ref v 'name) (hash-ref v 'number)))
                                             (hash-ref e 'values)) ",\n")
                           "\n};\n\n"))
                        enums))
            (cpp-pb-support base pkg "")
            (apply string-append
                   (map (lambda (m) (cpp-pb-message-class file-model m support ""))
                        ordered))
            ;; Map helper declarations come after the classes:
            ;; they name nested message types, which must be
            ;; declared first. Implementations follow, then the
            ;; out-of-line MarshalDc/UnmarshalDc definitions.
            (if (null? helpers)
                ""
                (string-append
                 (format "namespace pb_~a {\n\n" base)
                 (apply string-append (map car (reverse helpers)))
                 (format "}  // namespace pb_~a\n\n" base)))
            (apply string-append
                   (map (lambda (m) (cpp-pb-message-impls file-model m support ""))
                        ordered))
            (if (null? helpers)
                ""
                (string-append
                 (format "namespace pb_~a {\n\n" base)
                 (apply string-append (map cdr (reverse helpers)))
                 (format "}  // namespace pb_~a\n\n" base)))
            (format "}  // namespace ~a\n" (cpp-pb-ns pkg))))
         (cons (string-append base "_messages.hpp") content))))

;; Message includes for a stub: one examples/<base>_messages.hpp
;; per file that defines a method input/output type (which may
;; live in an imported proto, not the service's own file).
(define (cpp-stub-includes file-model)
  (define self-base
    (path->string (path-replace-extension
                   (file-name-from-path (hash-ref file-model 'name)) "")))
  (cond [(not (hash-has-key? file-model 'types))
         (format "#include \"examples/~a_messages.hpp\"\n" self-base)]
        [else
         (define files
           (remove-duplicates
            (for*/list ([svc (in-list (hash-ref file-model 'services))]
                        [m (in-list (hash-ref svc 'methods))]
                        [k (in-list '(input-full output-full))])
              (hash-ref (cpp-pb-resolve file-model (hash-ref m k)) 'file))))
         (apply string-append
                (map (lambda (fn)
                       (format "#include \"examples/~a_messages.hpp\"\n"
                               (path->string (path-replace-extension
                                              (file-name-from-path fn) ""))))
                     files))]))

(define (emit-cpp-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define struct-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define ns (cpp-pb-ns pkg))
  (define stub
    (cons (string-append base "_grpc_dc.hpp")
          (string-append
           "// @generated by protoc-gen-grpc-dc-cpp. DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         "#pragma once\n\n"
         "#include <future>\n#include <optional>\n\n#if __cplusplus >= 202002L\n#include \"grpcdc/async.hpp\"\n#endif\n"
         "#include <memory>\n"
         "#include <vector>\n\n"
         (cpp-stub-includes file-model)
         "#include \"grpcdc/channel.hpp\"\n"
         "#include \"grpcdc/server.hpp\"\n\n"
         (format "namespace ~a {\n\n" ns)
         ;; trace=hooks: delegate the tracer registrar to grpcdc::Tracing.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "/// Tracing (trace=hooks): register an observer via SetTracer.\n"
              "inline void SetTracer(grpcdc::Tracing::Tracer* t) { grpcdc::Tracing::SetTracer(t); }\n"
              "inline void SetTraceFilter(const std::string& patterns) { grpcdc::Tracing::SetTraceFilter(patterns); }\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "inline const bool _grpcdcTraceFilterApplied = [] { grpcdc::Tracing::SetTraceFilter(~s); return true; }();\n" methods)
                    ""))
              "\n")
             "")
         (format "/// Generated gRPC-over-DataChannels stubs for ~a.\n" (hash-ref file-model 'name))
         (format "struct ~a {\n" struct-name)
         (apply string-append
                (map cpp-service (hash-ref file-model 'services)))
         "};\n\n"
         (format "}  // namespace ~a\n" ns))))
  (define pb-file (emit-cpp-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
