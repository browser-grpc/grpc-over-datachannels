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
              "    pub fn ~a(self: *~aClient, req: *const ~a, metadata: ?*const Metadata, timeout_ms: ?u64) status_mod.CallResult(~a) {\n"
              "        var resp = ~a{};\n"
              "        const st = self.channel.unary(~s, req, &resp, metadata, timeout_ms);\n"
              "        if (!st.isOk()) return .{ .status = st };\n"
              "        return .{ .ok = resp };\n"
              "    }\n\n")
             name svc req resp resp path)]
    [(server-streaming)
     (format (string-append
              "    pub fn ~a(self: *~aClient, req: *const ~a, metadata: ?*const Metadata, timeout_ms: ?u64) status_mod.CallResult(~a~aClient) {\n"
              "        switch (self.channel.serverStream(~s, req, metadata, timeout_ms)) {\n"
              "            .ok => |stream| return .{ .ok = .{ .stream = stream } },\n"
              "            .status => |st| return .{ .status = st },\n"
              "        }\n"
              "    }\n\n")
             name svc req svc orig-name path)]
    [(client-streaming)
     (format (string-append
              "    pub fn ~a(self: *~aClient, reqs: []const ~a, metadata: ?*const Metadata, timeout_ms: ?u64) status_mod.CallResult(~a) {\n"
              "        var resp = ~a{};\n"
              "        const st = self.channel.clientStreamCall(~s, reqs, &resp, metadata, timeout_ms);\n"
              "        if (!st.isOk()) return .{ .status = st };\n"
              "        return .{ .ok = resp };\n"
              "    }\n\n")
             name svc req resp resp path)]
    [(bidi)
     (format (string-append
              "    pub fn ~a(self: *~aClient, reqs: []const ~a, metadata: ?*const Metadata, timeout_ms: ?u64) status_mod.CallResult(~a~aClient) {\n"
              "        switch (self.channel.bidi(~s, reqs, metadata, timeout_ms)) {\n"
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

;; ---------------------------------------------------------------------------
;; Zig message types (<base>_messages.zig, matching the stub's
;; import): structs with marshalDc/unmarshalDc plus Pb wire
;; support in the same file. Dependency-free (std only). Mirrors
;; the Dart emitter on the shared desc.rkt model. Maps become
;; slices of generated entry structs; nested messages are nested
;; struct declarations.
;; ---------------------------------------------------------------------------

(define zig-pb-varint-types '(5 3 13 4 17 18 8 14))
(define zig-pb-fixed '((2 4 "f32") (1 8 "f64") (7 4 "u32") (15 4 "i32") (6 8 "u64") (16 8 "i64")))

(define (zig-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-zig-pb-file "unresolved type ~a" type-name))))

(define (zig-pb-rel pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  rel)

(define (zig-pb-entry-ref model entry)
  (define rel
    (zig-pb-rel (hash-ref entry 'pkg)
                (if (eq? (hash-ref entry 'kind) 'enum)
                    (let ([e (hash-ref entry 'enum)])
                      (if (hash-ref entry 'msg)
                          (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                          (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                    (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (equal? (hash-ref entry 'file) (hash-ref model 'name))
      rel
      (format "~a_messages.~a"
              (path->string (path-replace-extension (file-name-from-path (hash-ref entry 'file)) ""))
              rel)))

(define (zig-pb-scalar f)
  (case (hash-ref f 'type)
    [(1) '("f64" "0")] [(2) '("f32" "0")] [(3) '("i64" "0")] [(4) '("u64" "0")]
    [(5) '("i32" "0")] [(6) '("u64" "0")] [(7) '("u32" "0")] [(8) '("bool" "false")]
    [(9) '("[]const u8" "\"\"")] [(12) '("[]const u8" "\"\"")] [(13) '("u32" "0")]
    [(15) '("i32" "0")] [(16) '("i64" "0")] [(17) '("i32" "0")] [(18) '("i64" "0")]
    [else #f]))

(define (zig-pb-entry-struct-name model entry)
  (string-replace (zig-pb-entry-ref model entry) "." "_"))

(define (zig-pb-type model f)
  (define type (hash-ref f 'type))
  (define singular
    (cond [(= type 11)
           (define entry (zig-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (format "[]const ~a" (zig-pb-entry-struct-name model entry))
               (format "?*~a" (zig-pb-entry-ref model entry)))]
          [(= type 14) (zig-pb-entry-ref model (zig-pb-resolve model (hash-ref f 'type-name)))]
          [else (first (zig-pb-scalar f))]))
  (cond [(and (= type 11)
              (eq? (hash-ref (zig-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         singular]
        [(= (hash-ref f 'label) 3)
         (format "[]const ~a" (if (= type 11)
                                  (zig-pb-entry-ref model (zig-pb-resolve model (hash-ref f 'type-name)))
                                  (zig-pb-type model (hash-set f 'label 1))))]
        [else singular]))

(define (zig-pb-default model f)
  (cond [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (zig-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         "&.{}"]
        [(= (hash-ref f 'label) 3) "&.{}"]
        [(= (hash-ref f 'type) 11) "null"]
        [(= (hash-ref f 'type) 14)
         (define entry (zig-pb-resolve model (hash-ref f 'type-name)))
         (format ".~a" (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'name))]
        [else (second (zig-pb-scalar f))]))

(define (zig-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "@intFromBool(~a)" v)]
    [(17) (format "@as(u64, @bitCast(@as(i64, ((~a << 1) ^ (~a >> 31)))))" v v)]
    [(18) (format "@as(u64, @bitCast(((~a << 1) ^ (~a >> 63))))" v v)]
    [(14) (format "@as(u64, @bitCast(@as(i64, @intFromEnum(~a))))" v)]
    [(5) (format "@as(u64, @bitCast(@as(i64, ~a)))" v)]
    [(3) (format "@as(u64, @bitCast(~a))" v)]
    [else v]))

(define (zig-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "@as(i32, @truncate(@as(i64, @bitCast(~a))))" v)]
    [(13 7) (format "@as(u32, @truncate(~a))" v)]
    [(3) (format "@as(i64, @bitCast(~a))" v)]
    [(4 6) v]
    [(8) (format "~a != 0" v)]
    [(17) (format "@as(i32, @bitCast(@as(u32, @truncate((~a >> 1) ^ (0 -% (~a & 1))))))" v v)]
    [(18) (format "@as(i64, @bitCast((~a >> 1) ^ (0 -% (~a & 1))))" v v)]))

(define (zig-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [(14) (format "@intFromEnum(~a) != 0" v)]
    [else (format "~a != 0" v)]))

(define (zig-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(memv type zig-pb-varint-types)
         (format "~aif (~a) { w.tag(~a, 0); w.varint(~a); }\n" indent (zig-pb-nonzero f v) n (zig-pb-varint-expr f v))]
        [(assv type zig-pb-fixed)
         => (lambda (info)
              (format "~aif (~a) { w.tag(~a, ~a); w.fixed~a(~a); }\n" indent (zig-pb-nonzero f v) n
                      (if (= (second info) 8) 1 5) (third info) v))]
        [(= type 9) (format "~aw.stringField(~a, ~a);\n" indent n v)]
        [(= type 12) (format "~aif (~a.len > 0) w.bytesField(~a, ~a);\n" indent v n v)]
        [(= type 11) (format "~aif (~a) |p| w.bytesField(~a, p.marshalDc(alloc));\n" indent v n)]
        [else (error 'emit-zig-pb-file "unsupported field type ~a (groups)" type)]))

(define (zig-pb-encode-field model f)
  (define v (format "self.~a" (hash-ref f 'name)))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (zig-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (zig-pb-resolve model (hash-ref f 'type-name)))
         (format "        for (~a) |e| w.bytesField(~a, encode~a(alloc, e.key, e.value));\n" v n (zig-pb-entry-struct-name model entry))]
        [(not (= (hash-ref f 'label) 3)) (zig-pb-encode-singular model f v "        ")]
        [(memv type zig-pb-varint-types)
         (string-append
          (format "        if (~a.len > 0) {\n            var payload = PbWriter.init(alloc);\n            defer payload.deinit();\n" v)
          (format "            for (~a) |x| payload.varint(~a);\n" v (zig-pb-varint-expr f "x"))
          (format "            w.bytesField(~a, payload.toBytes());\n        }\n" n))]
        [(assv type zig-pb-fixed)
         => (lambda (info)
              (string-append
               (format "        if (~a.len > 0) {\n            var payload = PbWriter.init(alloc);\n            defer payload.deinit();\n" v)
               (format "            for (~a) |x| payload.fixed~a(x);\n" v (third info))
               (format "            w.bytesField(~a, payload.toBytes());\n        }\n" n)))]
        [(= type 9) (format "        for (~a) |x| w.bytesField(~a, x);\n" v n)]
        [(= type 12) (format "        for (~a) |x| w.bytesField(~a, x);\n" v n)]
        [(= type 11) (format "        for (~a) |x| w.bytesField(~a, x.marshalDc(alloc));\n" v n)]
        [else (error 'emit-zig-pb-file "unsupported repeated field type ~a" type)]))

(define (zig-pb-decode-singular model f target src indent alloc?)
  (define type (hash-ref f 'type))
  (cond [(memv type zig-pb-varint-types)
         (format "~a~a = ~a;\n" indent target
                 (if (= type 14)
                     (format "@enumFromInt(@as(i32, @truncate(@as(i64, @bitCast(~a)))))" src)
                     (zig-pb-varint-decode f src)))]
        [(assv type zig-pb-fixed)
         => (lambda (info)
              (format "~a~a = ~a;\n" indent target
                      (case (hash-ref f 'type)
                        [(2) (format "@as(f32, @bitCast(@as(u32, @truncate(~a))))" src)]
                        [(1) (format "@as(f64, @bitCast(~a))" src)]
                        [(7) (format "@as(u32, @truncate(~a))" src)]
                        [(15) (format "@as(i32, @bitCast(@as(u32, @truncate(~a))))" src)]
                        [(6) src]
                        [(16) (format "@as(i64, @bitCast(~a))" src)]
                        [else src])))]
        [(= type 9) (format "~a~a = alloc.dupe(u8, ~a) catch \"\";\n" indent target src)]
        [(= type 12) (format "~a~a = alloc.dupe(u8, ~a) catch &.{};\n" indent target src)]
        [(= type 11)
         (define ref (zig-pb-entry-ref model (zig-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = alloc.create(~a) catch unreachable;\n" indent target ref)
          (format "~a~a.?.* = .{};\n" indent target)
          (format "~a~a.?.unmarshalDc(alloc, ~a);\n" indent target src))]
        [else (error 'emit-zig-pb-file "unsupported field type ~a" type)]))

(define (zig-pb-decode-case model f)
  (define v (format "self.~a" (hash-ref f 'name)))
  (define type (hash-ref f 'type))
  (define head (format "                ~a => {\n" (hash-ref f 'number)))
  (define tail "                },\n")
  (cond [(and (= type 11)
              (eq? (hash-ref (zig-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (zig-pb-resolve model (hash-ref f 'type-name)))
         (define sname (zig-pb-entry-struct-name model entry))
         (string-append head
                        (format "                    const kv = decode~a(alloc, field.bytes_value);\n" sname)
                        (format "                    ~a_list.append(alloc, kv) catch {};\n" (hash-ref f 'name))
                        tail)]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        (zig-pb-decode-singular model f v
                                                (cond [(memv type zig-pb-varint-types) "field.varint_value"]
                                                      [(assv type zig-pb-fixed) "field.fixed_value"]
                                                      [else "field.bytes_value"])
                                                "                    " #t)
                        tail)]
        [(memv type zig-pb-varint-types)
         (string-append head
                        "                    if (field.wire == 2) {\n"
                        "                        var sub = PbReader.init(field.bytes_value);\n"
                        "                        while (!sub.done()) {\n"
                        (format "                            ~a_list.append(alloc, ~a) catch {};\n" (hash-ref f 'name)
                                (let ([conv (zig-pb-varint-decode f "sub.varint()")])
                                  (if (= type 14) (format "@enumFromInt(@as(i32, @truncate(@as(i64, @bitCast(sub.varint())))))" ) conv)))
                        "                        }\n                    } else {\n"
                        (format "                        ~a_list.append(alloc, ~a) catch {};\n" (hash-ref f 'name)
                                (let ([conv (zig-pb-varint-decode f "field.varint_value")])
                                  (if (= type 14) "@enumFromInt(@as(i32, @truncate(@as(i64, @bitCast(field.varint_value)))))" conv)))
                        "                    }\n" tail)]
        [(assv type zig-pb-fixed)
         => (lambda (info)
              (string-append head
                             "                    if (field.wire == 2) {\n"
                             "                        var sub = PbReader.init(field.bytes_value);\n"
                             "                        while (!sub.done()) {\n"
                             (format "                            ~a_list.append(alloc, ~a) catch {};\n" (hash-ref f 'name)
                                     (case (hash-ref f 'type)
                                       [(2) "@as(f32, @bitCast(std.mem.readInt(u32, sub.take(4)[0..4], .little)))"]
                                       [(1) "@as(f64, @bitCast(std.mem.readInt(u64, sub.take(8)[0..8], .little)))"]
                                       [(7) "std.mem.readInt(u32, sub.take(4)[0..4], .little)"]
                                       [(15) "@as(i32, @bitCast(std.mem.readInt(u32, sub.take(4)[0..4], .little)))"]
                                       [(6) "std.mem.readInt(u64, sub.take(8)[0..8], .little)"]
                                       [else "@as(i64, @bitCast(std.mem.readInt(u64, sub.take(8)[0..8], .little)))"]))
                             "                        }\n                    } else {\n"
                             (format "                        ~a_list.append(alloc, ~a) catch {};\n" (hash-ref f 'name)
                                     (case (hash-ref f 'type)
                                       [(2) "@as(f32, @bitCast(@as(u32, @truncate(field.fixed_value))))"]
                                       [(1) "@as(f64, @bitCast(field.fixed_value))"]
                                       [(7) "@as(u32, @truncate(field.fixed_value))"]
                                       [(15) "@as(i32, @bitCast(@as(u32, @truncate(field.fixed_value))))"]
                                       [(6) "field.fixed_value"]
                                       [else "@as(i64, @bitCast(field.fixed_value))"]))
                             "                    }\n" tail))]
        [(= type 9) (string-append head (format "                    ~a_list.append(alloc, alloc.dupe(u8, field.bytes_value) catch \"\") catch {};\n" (hash-ref f 'name)) tail)]
        [(= type 12) (string-append head (format "                    ~a_list.append(alloc, alloc.dupe(u8, field.bytes_value) catch &.{}) catch {};\n" (hash-ref f 'name)) tail)]
        [(= type 11)
         (string-append head
                        (format "                    var item: ~a = .{};\n" (zig-pb-entry-ref model (zig-pb-resolve model (hash-ref f 'type-name))))
                        "                    item.unmarshalDc(alloc, field.bytes_value);\n"
                        (format "                    ~a_list.append(alloc, item) catch {};\n" (hash-ref f 'name)) tail)]
        [else (error 'emit-zig-pb-file "unsupported repeated field type ~a" type)]))

(define (zig-pb-map-helpers model entry)
  (define msg (hash-ref entry 'msg))
  (define sname (zig-pb-entry-struct-name model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-zig-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (define kt (zig-pb-type model (hash-set key-f 'label 1)))
  (define vt (zig-pb-type model (hash-set val-f 'label 1)))
  (define vt-plain (if (and (= (hash-ref val-f 'type) 11)
                            (not (eq? (hash-ref (zig-pb-resolve model (hash-ref val-f 'type-name)) 'kind) 'map)))
                       (zig-pb-entry-ref model (zig-pb-resolve model (hash-ref val-f 'type-name)))
                       vt))
  ;; Entry struct declaration is emitted with message classes.
  (string-append
   (format "pub fn encode~a(alloc: std.mem.Allocator, key: ~a, value: ~a) []u8 {\n" sname kt vt-plain)
   "    var w = PbWriter.init(alloc);\n    defer w.deinit();\n"
   (zig-pb-encode-singular model (hash-set key-f 'label 1) "key" "    ")
   (if (= (hash-ref val-f 'type) 11)
       (format "    w.bytesField(~a, value.marshalDc(alloc));\n" (hash-ref val-f 'number))
       (zig-pb-encode-singular model (hash-set val-f 'label 1) "value" "    "))
   "    return w.toBytes();\n}\n\n"
   (format "pub fn decode~a(alloc: std.mem.Allocator, data: []const u8) ~a {\n" sname sname)
   (format "    var result: ~a = .{ .key = ~a, .value = ~a };\n" sname
           (zig-pb-default model (hash-set key-f 'label 1))
           (if (= (hash-ref val-f 'type) 11) ".{}" (zig-pb-default model (hash-set val-f 'label 1))))
   "    var r = PbReader.init(data);\n    while (r.next()) |field| {\n        switch (field.number) {\n"
   (format "            ~a => { ~a },\n" (hash-ref key-f 'number)
           (string-trim (zig-pb-decode-singular model (hash-set key-f 'label 1) "result.key"
                                                (cond [(memv (hash-ref key-f 'type) zig-pb-varint-types) "field.varint_value"]
                                                      [(assv (hash-ref key-f 'type) zig-pb-fixed) "field.fixed_value"]
                                                      [else "field.bytes_value"]) "" #t) "\n" #:left? #f #:repeat? #t))
   (format "            ~a => { ~a },\n" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               "result.value.unmarshalDc(alloc, field.bytes_value);"
               (string-trim (zig-pb-decode-singular model (hash-set val-f 'label 1) "result.value"
                                                    (cond [(memv (hash-ref val-f 'type) zig-pb-varint-types) "field.varint_value"]
                                                          [(assv (hash-ref val-f 'type) zig-pb-fixed) "field.fixed_value"]
                                                          [else "field.bytes_value"]) "" #t) "\n" #:left? #f #:repeat? #t)))
   "            else => {},\n        }\n    }\n    return result;\n}\n\n"))

(define (zig-pb-support)
  (string-append
   "// @generated by protoc-gen-grpc-dc-zig (Racket metaprogram). DO NOT EDIT.\n"
   "const std = @import(\"std\");\n\n"
   "pub const PbWriter = struct {\n"
   "    alloc: std.mem.Allocator,\n"
   "    list: std.ArrayList(u8),\n"
   "    pub fn init(alloc: std.mem.Allocator) PbWriter { return .{ .alloc = alloc, .list = std.ArrayList(u8).empty }; }\n"
   "    pub fn deinit(self: *PbWriter) void { self.list.deinit(self.alloc); }\n"
   "    pub fn varint(self: *PbWriter, value: u64) void { var v = value; while (v > 0x7f) { self.list.append(self.alloc, @as(u8, @truncate((v & 0x7f) | 0x80))) catch {}; v >>= 7; } self.list.append(self.alloc, @as(u8, @truncate(v))) catch {}; }\n"
   "    pub fn tag(self: *PbWriter, field: u32, wire: u3) void { self.varint((@as(u64, field) << 3) | @as(u64, wire)); }\n"
   "    pub fn bytesField(self: *PbWriter, field: u32, payload: []const u8) void { self.tag(field, 2); self.varint(payload.len); self.list.appendSlice(self.alloc, payload) catch {}; }\n"
   "    pub fn stringField(self: *PbWriter, field: u32, value: []const u8) void { if (value.len == 0) return; self.bytesField(field, value); }\n"
   "    pub fn fixedf32(self: *PbWriter, value: f32) void { self.fixed32Bits(@bitCast(value)); }\n"
   "    pub fn fixedf64(self: *PbWriter, value: f64) void { self.fixed64Bits(@bitCast(value)); }\n"
   "    pub fn fixedu32(self: *PbWriter, value: u32) void { self.fixed32Bits(value); }\n"
   "    pub fn fixedi32(self: *PbWriter, value: i32) void { self.fixed32Bits(@bitCast(value)); }\n"
   "    pub fn fixedu64(self: *PbWriter, value: u64) void { self.fixed64Bits(value); }\n"
   "    pub fn fixedi64(self: *PbWriter, value: i64) void { self.fixed64Bits(@bitCast(value)); }\n"
   "    fn fixed32Bits(self: *PbWriter, value: u32) void { var b: [4]u8 = undefined; std.mem.writeInt(u32, &b, value, .little); self.list.appendSlice(self.alloc, &b) catch {}; }\n"
   "    fn fixed64Bits(self: *PbWriter, value: u64) void { var b: [8]u8 = undefined; std.mem.writeInt(u64, &b, value, .little); self.list.appendSlice(self.alloc, &b) catch {}; }\n"
   "    pub fn toBytes(self: *PbWriter) []u8 { return self.list.toOwnedSlice(self.alloc) catch &.{}; }\n"
   "};\n\n"
   "pub const PbField = struct {\n"
   "    number: u32,\n    wire: u3,\n    varint_value: u64 = 0,\n    bytes_value: []const u8 = &.{},\n    fixed_value: u64 = 0,\n"
   "};\n\n"
   "pub const PbReader = struct {\n"
   "    buf: []const u8,\n    pos: usize = 0,\n"
   "    pub fn init(buf: []const u8) PbReader { return .{ .buf = buf }; }\n"
   "    pub fn done(self: *PbReader) bool { return self.pos >= self.buf.len; }\n"
   "    pub fn varint(self: *PbReader) u64 { var result: u64 = 0; var shift: u6 = 0; while (true) { if (self.pos >= self.buf.len) return result; const b = self.buf[self.pos]; self.pos += 1; result |= @as(u64, b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) return result; } }\n"
   "    pub fn take(self: *PbReader, n: usize) []const u8 { const end = @min(self.pos + n, self.buf.len); const v = self.buf[self.pos..end]; self.pos = end; return v; }\n"
   "    pub fn fixed32Of(self: *PbReader, field: PbField) u32 { _ = self; return @as(u32, @truncate(field.fixed_value)); }\n"
   "    pub fn fixed64Of(self: *PbReader, field: PbField) u64 { _ = self; return field.fixed_value; }\n"
   "    pub fn next(self: *PbReader) ?PbField {\n"
   "        if (self.pos >= self.buf.len) return null;\n"
   "        const tagv = self.varint();\n"
   "        var field = PbField{ .number = @as(u32, @truncate(tagv >> 3)), .wire = @as(u3, @truncate(tagv & 7)) };\n"
   "        switch (field.wire) {\n"
   "            0 => field.varint_value = self.varint(),\n"
   "            2 => { const n = self.varint(); field.bytes_value = self.take(@as(usize, @truncate(n))); },\n"
   "            1 => { field.bytes_value = self.take(8); field.fixed_value = std.mem.readInt(u64, field.bytes_value[0..8], .little); },\n"
   "            5 => { field.bytes_value = self.take(4); field.fixed_value = std.mem.readInt(u32, field.bytes_value[0..4], .little); },\n"
   "            else => return null,\n"
   "        }\n"
   "        return field;\n"
   "    }\n"
   "};\n\n"))

(define (zig-pb-message-struct model msg indent)
  (define name (hash-ref msg 'name))
  (define fields (hash-ref msg 'fields))
  (string-append
   (format "~apub const ~a = struct {\n" indent name)
   (apply string-append
          (map (lambda (f)
                 (format "~a    ~a: ~a = ~a,\n" indent (hash-ref f 'name) (zig-pb-type model f) (zig-pb-default model f)))
               fields))
   (format "~a    pub fn marshalDc(self: *const ~a, alloc: std.mem.Allocator) []u8 {\n" indent name)
   (format "~a        _ = .{ self, alloc };\n" indent)
   (format "~a        var w = PbWriter.init(alloc);\n~a        defer w.deinit();\n" indent indent)
   (apply string-append (map (lambda (f) (zig-pb-encode-field model f)) fields))
   (format "~a        return w.toBytes();\n~a    }\n" indent indent)
   (format "~a    pub fn unmarshalDc(self: *~a, alloc: std.mem.Allocator, data: []const u8) void {\n" indent name)
   (format "~a        _ = .{ self, alloc, data };\n" indent)
   (apply string-append
          (map (lambda (f) (format "~a        self.~a = ~a;\n" indent (hash-ref f 'name) (zig-pb-default model f))) fields))
   ;; Declare ArrayList accumulators for repeated/map fields.
   (apply string-append
          (map (lambda (f)
                 (if (or (= (hash-ref f 'label) 3)
                         (and (= (hash-ref f 'type) 11)
                              (eq? (hash-ref (zig-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map)))
                     (format "~a        var ~a_list = std.ArrayList(~a).empty;\n" indent (hash-ref f 'name)
                             (if (and (= (hash-ref f 'type) 11)
                                      (eq? (hash-ref (zig-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
                                 (zig-pb-entry-struct-name model (zig-pb-resolve model (hash-ref f 'type-name)))
                                 (if (= (hash-ref f 'type) 11)
                                     (zig-pb-entry-ref model (zig-pb-resolve model (hash-ref f 'type-name)))
                                     (zig-pb-type model (hash-set f 'label 1)))))
                     ""))
               fields))
   (format "~a        var r = PbReader.init(data);\n" indent)
   (format "~a        while (r.next()) |field| {\n~a            switch (field.number) {\n" indent indent)
   (apply string-append (map (lambda (f) (zig-pb-decode-case model f)) fields))
   (format "~a                else => {},\n~a            }\n~a        }\n" indent indent indent)
   (apply string-append
          (map (lambda (f)
                 (if (or (= (hash-ref f 'label) 3)
                         (and (= (hash-ref f 'type) 11)
                              (eq? (hash-ref (zig-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map)))
                     (format "~a        self.~a = ~a_list.toOwnedSlice(alloc) catch &.{};\n" indent (hash-ref f 'name) (hash-ref f 'name))
                     ""))
               fields))
   (format "~a    }\n" indent)
   (apply string-append (map (lambda (n) (zig-pb-message-struct model n (string-append indent "    "))) (hash-ref msg 'nested)))
   (apply string-append (map (lambda (e) (zig-pb-nested-enum e (string-append indent "    "))) (hash-ref msg 'enums)))
   (format "~a};\n" indent)))

(define (zig-pb-nested-enum e indent)
  (string-append
   (format "~apub const ~a = enum(i32) {\n" indent (hash-ref e 'name))
   (string-join (map (lambda (v) (format "~a    ~a = ~a" indent (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) ",\n")
   (format ",\n~a};\n" indent)))

(define (emit-zig-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-zig-pb-file/inner file-model)))

(define (emit-zig-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         ;; Entry structs for map entries in this file.
         (define entry-structs '())
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (zig-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (equal? (hash-ref e 'file) (hash-ref file-model 'name)))
                 (define sname (zig-pb-entry-struct-name file-model e))
                 (unless (member sname (map car entry-structs))
                   (define em (hash-ref e 'msg))
                   (define kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
                   (define vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))
                   (set! entry-structs
                         (cons (cons sname
                                     (format "pub const ~a = struct { key: ~a, value: ~a };\n\n" sname
                                             (zig-pb-type file-model (hash-set kf 'label 1))
                                             (if (= (hash-ref vf 'type) 11)
                                                 (zig-pb-entry-ref file-model (zig-pb-resolve file-model (hash-ref vf 'type-name)))
                                                 (zig-pb-type file-model (hash-set vf 'label 1)))))
                               entry-structs))
                   (set! helpers (cons (zig-pb-map-helpers file-model e) helpers))))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define dep-imports
           (apply string-append
                  (map (lambda (d)
                         (format "const ~a_messages = @import(\"~a_messages.zig\");\n"
                                 (path->string (path-replace-extension (file-name-from-path d) ""))
                                 (path->string (path-replace-extension (file-name-from-path d) ""))))
                       (hash-ref file-model 'dependencies))))
         (define content
           (string-append
            (zig-pb-support)
            dep-imports
            (apply string-append (map cdr (reverse entry-structs)))
            (apply string-append
                   (map (lambda (e)
                          (string-append
                           (format "pub const ~a = enum(i32) {\n" (hash-ref e 'name))
                           (string-join (map (lambda (v) (format "    ~a = ~a" (hash-ref v 'name) (hash-ref v 'number)))
                                             (hash-ref e 'values)) ",\n")
                           ",\n};\n\n"))
                        enums))
            (apply string-append
                   (map (lambda (m) (zig-pb-message-struct file-model m ""))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            (apply string-append (reverse helpers))))
         (cons (string-append base "_messages.zig") content))))

(define (emit-zig-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define stub
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
  (define pb-file (emit-zig-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
