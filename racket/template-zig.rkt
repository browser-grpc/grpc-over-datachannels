#lang racket

;;; template-zig.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-zig.
;;;
;;; Generated code sits beside hand-written message types providing
;;; marshalDc / unmarshalDc. Method names keep the proto spelling in
;;; paths; Zig identifiers use lowerFirst for methods, mirroring the
;;; other stubs. Zig has no exceptions or interfaces: statuses are
;;; returned as values (CallResult / RecvResult unions) and the
;;; service interface is a vtable struct.

(require "spec.rkt" "desc.rkt")
(provide emit-zig-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (lower-first s)
  (if (string=? s "")
      s
      (string-append (string (char-downcase (string-ref s 0))) (substring s 1))))

(define (snake-case s) ; ServerStream -> server_stream
  (apply string-append
         (for/list ([c (in-string s)] [i (in-naturals)])
           (cond [(char-upper-case? c)
                  (string-append (if (= i 0) "" "_")
                                 (string (char-downcase c)))]
                 [else (string c)]))))

(define (zig-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a/// Deprecated in the proto schema.\n" indent)
      ""))

(define (zig-client-method/raw m)
  (define name (lower-first (hash-ref m 'name)))
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    pub fn ~a(self: *~aClient, req: *const ~a, metadata: ?*const Metadata) status_mod.CallResult(~a) {\n"
              "        var resp = ~a{};\n"
              "        const st = self.channel.unary(~s, req, &resp, metadata);\n"
              "        if (!st.isOk()) return .{ .status = st };\n"
              "        return .{ .ok = resp };\n"
              "    }\n\n")
             name svc req resp resp path)]
    [(server-streaming)
     (format (string-append
              "    pub fn ~a(self: *~aClient, req: *const ~a, metadata: ?*const Metadata) status_mod.CallResult(~a~aClient) {\n"
              "        switch (self.channel.serverStream(~s, req, metadata)) {\n"
              "            .ok => |stream| return .{ .ok = .{ .stream = stream } },\n"
              "            .status => |st| return .{ .status = st },\n"
              "        }\n"
              "    }\n\n")
             name svc req svc orig-name path)]
    [(client-streaming)
     (format (string-append
              "    pub fn ~a(self: *~aClient, reqs: []const ~a, metadata: ?*const Metadata) status_mod.CallResult(~a) {\n"
              "        var resp = ~a{};\n"
              "        const st = self.channel.clientStreamCall(~s, reqs, &resp, metadata);\n"
              "        if (!st.isOk()) return .{ .status = st };\n"
              "        return .{ .ok = resp };\n"
              "    }\n\n")
             name svc req resp resp path)]
    [(bidi)
     (format (string-append
              "    pub fn ~a(self: *~aClient, reqs: []const ~a, metadata: ?*const Metadata) status_mod.CallResult(~a~aClient) {\n"
              "        switch (self.channel.bidi(~s, reqs, metadata)) {\n"
              "            .ok => |stream| return .{ .ok = .{ .stream = stream } },\n"
              "            .status => |st| return .{ .status = st },\n"
              "        }\n"
              "    }\n\n")
             name svc req svc orig-name path)]))

(define (zig-client-method m)
  (string-append (zig-deprecated m "    ") (zig-client-method/raw m)))

(define (zig-client-stream-class m)
  (define orig-name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming)
     (format (string-append
              "/// Response stream of a ~a call.\n"
              "pub const ~a~aClient = struct {\n"
              "    stream: ClientStream,\n\n"
              "    pub fn recv(self: *~a~aClient) status_mod.RecvResult(~a) {\n"
              "        var resp = ~a{};\n"
              "        switch (self.stream.recvInto(&resp)) {\n"
              "            .message => return .{ .message = resp },\n"
              "            .end => return .end,\n"
              "            .status => |st| return .{ .status = st },\n"
              "        }\n"
              "    }\n\n"
              "    pub fn deinit(self: *~a~aClient) void {\n"
              "        self.stream.deinit();\n"
              "    }\n"
              "};\n\n")
             orig-name svc orig-name svc orig-name resp resp svc orig-name)]
    [(bidi)
     (format (string-append
              "/// Response stream of a ~a call.\n"
              "pub const ~a~aClient = struct {\n"
              "    stream: ClientStream,\n\n"
              "    pub fn recv(self: *~a~aClient) status_mod.RecvResult(~a) {\n"
              "        var resp = ~a{};\n"
              "        switch (self.stream.recvInto(&resp)) {\n"
              "            .message => return .{ .message = resp },\n"
              "            .end => return .end,\n"
              "            .status => |st| return .{ .status = st },\n"
              "        }\n"
              "    }\n\n"
              "    pub fn deinit(self: *~a~aClient) void {\n"
              "        self.stream.deinit();\n"
              "    }\n"
              "};\n\n")
             orig-name svc orig-name svc orig-name resp resp svc orig-name)]
    [else ""]))

(define (zig-server-stream-struct m)
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "/// Sends responses of a ~a call.\n"
              "pub const ~a~aServer = struct {\n"
              "    sink: server_mod.Sink,\n"
              "    alloc: std.mem.Allocator,\n\n"
              "    pub fn send(self: *~a~aServer, resp: *const ~a) Status {\n"
              "        const payload = resp.marshalDc(self.alloc);\n"
              "        defer self.alloc.free(payload);\n"
              "        self.sink.send(payload);\n"
              "        return Status.ok();\n"
              "    }\n"
              "};\n\n")
             orig-name svc orig-name svc orig-name resp)]
    [(client-streaming)
     (format (string-append
              "/// Receives requests of a ~a call.\n"
              "pub const ~a~aServer = struct {\n"
              "    reqs: *server_mod.RequestStream,\n"
              "    alloc: std.mem.Allocator,\n"
              "    resp: ?~a = null,\n\n"
              "    pub fn recv(self: *~a~aServer) status_mod.RecvResult(~a) {\n"
              "        var req = ~a{};\n"
              "        switch (self.reqs.recvInto(&req)) {\n"
              "            .message => return .{ .message = req },\n"
              "            .end => return .end,\n"
              "            .status => |st| return .{ .status = st },\n"
              "        }\n"
              "    }\n\n"
              "    pub fn sendAndClose(self: *~a~aServer, resp: ~a) void {\n"
              "        self.resp = resp;\n"
              "    }\n"
              "};\n\n")
             orig-name svc orig-name resp svc orig-name req req svc orig-name resp)]
    [(bidi)
     (format (string-append
              "/// Full-duplex stream of a ~a call.\n"
              "pub const ~a~aServer = struct {\n"
              "    reqs: *server_mod.RequestStream,\n"
              "    sink: server_mod.Sink,\n"
              "    alloc: std.mem.Allocator,\n\n"
              "    pub fn recv(self: *~a~aServer) status_mod.RecvResult(~a) {\n"
              "        var req = ~a{};\n"
              "        switch (self.reqs.recvInto(&req)) {\n"
              "            .message => return .{ .message = req },\n"
              "            .end => return .end,\n"
              "            .status => |st| return .{ .status = st },\n"
              "        }\n"
              "    }\n\n"
              "    pub fn send(self: *~a~aServer, resp: *const ~a) Status {\n"
              "        const payload = resp.marshalDc(self.alloc);\n"
              "        defer self.alloc.free(payload);\n"
              "        self.sink.send(payload);\n"
              "        return Status.ok();\n"
              "    }\n"
              "};\n\n")
             orig-name svc orig-name svc orig-name req req svc orig-name resp)]))

(define (zig-server-vtable-field m)
  (define name (snake-case (hash-ref m 'name)))
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "    ~a_fn: *const fn (ctx: *anyopaque, call_ctx: *CallContext, req: *const ~a, resp: *~a, alloc: std.mem.Allocator) Status,\n"
             name req resp)]
    [(server-streaming)
     (format "    ~a_fn: *const fn (ctx: *anyopaque, call_ctx: *CallContext, req: *const ~a, stream: *~a~aServer) Status,\n"
             name req svc orig-name)]
    [(client-streaming)
     (format "    ~a_fn: *const fn (ctx: *anyopaque, call_ctx: *CallContext, stream: *~a~aServer) Status,\n"
             name svc orig-name)]
    [(bidi)
     (format "    ~a_fn: *const fn (ctx: *anyopaque, call_ctx: *CallContext, stream: *~a~aServer) Status,\n"
             name svc orig-name)]))

(define (zig-adapter m)
  (define name (lower-first (hash-ref m 'name)))
  (define impl-name (snake-case (method-impl-name m)))
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "fn ~aAdapter(ctx: *anyopaque, call_ctx: *CallContext, reqs: *server_mod.RequestStream, sink: server_mod.Sink) Status {\n"
              "    const impl: *~aServer = @ptrCast(@alignCast(ctx));\n"
              "    var req = ~a{};\n"
              "    switch (reqs.recvInto(&req)) {\n"
              "        .message => {},\n"
              "        .end => return Status.init(wire.codeInternal, \"unary call closed with no request\"),\n"
              "        .status => |st| return st,\n"
              "    }\n"
              "    var arena = std.heap.ArenaAllocator.init(reqs.alloc);\n"
              "    defer arena.deinit();\n"
              "    var resp = ~a{};\n"
              "    const st = impl.~a_fn(impl.ctx, call_ctx, &req, &resp, arena.allocator());\n"
              "    if (!st.isOk()) return st;\n"
              "    const payload = resp.marshalDc(reqs.alloc);\n"
              "    defer reqs.alloc.free(payload);\n"
              "    sink.send(payload);\n"
              "    return Status.ok();\n"
              "}\n\n")
             name svc req (hash-ref m 'output) impl-name)]
    [(server-streaming)
     (format (string-append
              "fn ~aAdapter(ctx: *anyopaque, call_ctx: *CallContext, reqs: *server_mod.RequestStream, sink: server_mod.Sink) Status {\n"
              "    const impl: *~aServer = @ptrCast(@alignCast(ctx));\n"
              "    var req = ~a{};\n"
              "    switch (reqs.recvInto(&req)) {\n"
              "        .message => {},\n"
              "        .end => return Status.init(wire.codeInternal, \"server-streaming call closed with no request\"),\n"
              "        .status => |st| return st,\n"
              "    }\n"
              "    var stream = ~a~aServer{ .sink = sink, .alloc = reqs.alloc };\n"
              "    return impl.~a_fn(impl.ctx, call_ctx, &req, &stream);\n"
              "}\n\n")
             name svc req svc orig-name impl-name)]
    [(client-streaming)
     (format (string-append
              "fn ~aAdapter(ctx: *anyopaque, call_ctx: *CallContext, reqs: *server_mod.RequestStream, sink: server_mod.Sink) Status {\n"
              "    const impl: *~aServer = @ptrCast(@alignCast(ctx));\n"
              "    var arena = std.heap.ArenaAllocator.init(reqs.alloc);\n"
              "    defer arena.deinit();\n"
              "    var stream = ~a~aServer{ .reqs = reqs, .alloc = arena.allocator() };\n"
              "    const st = impl.~a_fn(impl.ctx, call_ctx, &stream);\n"
              "    if (!st.isOk()) return st;\n"
              "    const resp = stream.resp orelse\n"
              "        return Status.init(wire.codeInternal, \"client-streaming handler never called sendAndClose\");\n"
              "    const payload = resp.marshalDc(reqs.alloc);\n"
              "    defer reqs.alloc.free(payload);\n"
              "    sink.send(payload);\n"
              "    return Status.ok();\n"
              "}\n\n")
             name svc svc orig-name impl-name)]
    [(bidi)
     (format (string-append
              "fn ~aAdapter(ctx: *anyopaque, call_ctx: *CallContext, reqs: *server_mod.RequestStream, sink: server_mod.Sink) Status {\n"
              "    const impl: *~aServer = @ptrCast(@alignCast(ctx));\n"
              "    var stream = ~a~aServer{ .reqs = reqs, .sink = sink, .alloc = reqs.alloc };\n"
              "    return impl.~a_fn(impl.ctx, call_ctx, &stream);\n"
              "}\n\n")
             name svc svc orig-name impl-name)]))

(define (zig-register-method m)
  (define name (hash-ref m 'name))
  (define lower (lower-first name))
  (define kind-const
    (case (hash-ref m 'kind)
      [(unary) "unary"]
      [(server-streaming) "server_streaming"]
      [(client-streaming) "client_streaming"]
      [(bidi) "bidi"]))
  (format "                .{ .name = ~s, .path = ~s, .kind = .~a, .ctx = impl, .handler = ~aAdapter },\n"
          name (hash-ref m 'path) kind-const lower))

(define (zig-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "/// Client for ~a.\n" (hash-ref svc 'full-name))
     (format "pub const ~aClient = struct {\n" sname)
     "    channel: *Channel,\n\n"
     (format "    pub fn init(channel: *Channel) ~aClient {\n" sname)
     "        return .{ .channel = channel };\n"
     "    }\n\n"
     (apply string-append (map zig-client-method (append methods (alias-client-methods svc))))
     "};\n\n"
     (apply string-append (map zig-client-stream-class methods))
     (apply string-append (map zig-server-stream-struct methods))
     (format "/// Service implementation interface for ~a (vtable: Zig has no\n" (hash-ref svc 'full-name))
     "/// interfaces, so generated stubs dispatch through fn pointers).\n"
     (format "pub const ~aServer = struct {\n" sname)
     "    ctx: *anyopaque,\n"
     (apply string-append (map zig-server-vtable-field methods))
     "};\n\n"
     (apply string-append (map zig-adapter (append methods (alias-server-methods svc)))))))

;; Message type names in first-use order (for the re-export block).
(define (zig-message-names file-model)
  (define seen '())
  (for ([svc (in-list (hash-ref file-model 'services))])
    (for ([m (in-list (hash-ref svc 'methods))])
      (for ([t (in-list (list (hash-ref m 'input) (hash-ref m 'output)))])
        (unless (member t seen)
          (set! seen (append seen (list t)))))))
  seen)

(define (emit-zig-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (cons (string-append base "_grpc_dc.zig")
        (string-append
         "// @generated by protoc-gen-grpc-dc-zig (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "const std = @import(\"std\");\n"
         "const grpcdc = @import(\"grpcdc\");\n"
         "const channel_mod = grpcdc.channel;\n"
         "const endpoint_mod = grpcdc.endpoint;\n"
         "const server_mod = grpcdc.server;\n"
         "const status_mod = grpcdc.status;\n"
         "const wire = grpcdc.wire;\n"
         (format "const messages = @import(\"~a_messages.zig\");\n\n" base)
         "pub const Channel = channel_mod.Channel;\n"
         "pub const ClientStream = channel_mod.ClientStream;\n"
         "pub const CallContext = endpoint_mod.CallContext;\n"
         "pub const Server = server_mod.Server;\n"
         "pub const Status = status_mod.Status;\n"
         "pub const Metadata = channel_mod.Metadata;\n"
         (apply string-append
                (map (lambda (msg)
                       (format "pub const ~a = messages.~a;\n" msg msg))
                     (zig-message-names file-model)))
         "\n"
         (apply string-append (map zig-service (hash-ref file-model 'services)))
         (format "/// Generated gRPC-over-DataChannels stubs for ~a.\n" (hash-ref file-model 'name))
         (format "pub const ~a = struct {\n" class-name)
         (apply string-append
                (map (lambda (svc)
                       (define sname (hash-ref svc 'name))
                       (string-append
                        (format "    /// Register an implementation of ~a on a Server.\n" (hash-ref svc 'full-name))
                        (format "    pub fn register~aServer(server: *Server, impl: *~aServer) void {\n" sname sname)
                        "        server.registerService(.{\n"
                        (format "            .name = ~s,\n" (hash-ref svc 'full-name))
                        "            .methods = &.{\n"
                        (parameterize ([current-service sname])
                          (apply string-append
                                 (map zig-register-method
                                      (append (hash-ref svc 'methods)
                                              (alias-server-methods svc)))))
                        "            },\n"
                        "        });\n"
                        "    }\n"))
                     (hash-ref file-model 'services)))
         "};\n")))
