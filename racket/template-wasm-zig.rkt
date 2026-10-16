#lang racket

;;; template-wasm-zig.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-wasm-zig.
;;;
;;; The generated facade is a typed Zig client compiled to
;;; wasm32-freestanding that calls the JavaScript grpc-dc
;;; implementation through the bridge in wasm/zig/bridge.zig (which
;;; wraps js/src/wasm_bridge.js). Unlike the native Zig client
;;; nothing blocks — WASM is single-threaded — so methods take
;;; completion callbacks. Only leaf runtime pieces are imported
;;; (status + message types); the threaded endpoint/channel runtime
;;; cannot run under wasm32-freestanding.

(require "spec.rkt" "desc.rkt")
(provide emit-wasm-zig-file)

(define current-service (make-parameter ""))

(define (lower-first s)
  (if (zero? (string-length s))
      s
      (string-append (string (char-downcase (string-ref s 0))) (substring s 1))))

(define (wasm-client-method* m)
  (define name (lower-first (hash-ref m 'name)))
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    pub fn ~a(self: *~aClient, req: *const ~a, ctx: *anyopaque,\n"
              "        callback: *const fn (ctx: *anyopaque, result: CallResult(~a)) void) void {\n"
              "        const alloc = self.bridge.alloc;\n"
              "        const pending = alloc.create(~aUnaryPending) catch {\n"
              "            callback(ctx, .{ .status = oomStatus() });\n"
              "            return;\n"
              "        };\n"
              "        pending.* = .{ .alloc = alloc, .ctx = ctx, .callback = callback };\n"
              "        const payload = req.marshalDc(alloc);\n"
              "        self.bridge.unary(~s, payload, pending, ~aUnaryPending.complete);\n"
              "        alloc.free(payload);\n"
              "    }\n\n")
             name svc req resp orig-name path orig-name)]
    [(server-streaming)
     (format (string-append
              "    pub fn ~a(self: *~aClient, req: *const ~a, ctx: *anyopaque,\n"
              "        on_message: *const fn (ctx: *anyopaque, resp: ~a) void,\n"
              "        on_done: *const fn (ctx: *anyopaque, status: Status) void) void {\n"
              "        const alloc = self.bridge.alloc;\n"
              "        const pending = alloc.create(~aStreamPending) catch {\n"
              "            on_done(ctx, oomStatus());\n"
              "            return;\n"
              "        };\n"
              "        pending.* = .{ .alloc = alloc, .ctx = ctx, .on_message = on_message, .on_done = on_done };\n"
              "        const payload = req.marshalDc(alloc);\n"
              "        self.bridge.serverStream(~s, payload, pending, ~aStreamPending.message, ~aStreamPending.done);\n"
              "        alloc.free(payload);\n"
              "    }\n\n")
             name svc req resp orig-name path orig-name orig-name)]
    [(client-streaming)
     (format (string-append
              "    pub fn ~a(self: *~aClient, reqs: []const ~a, ctx: *anyopaque,\n"
              "        callback: *const fn (ctx: *anyopaque, result: CallResult(~a)) void) void {\n"
              "        const alloc = self.bridge.alloc;\n"
              "        const pending = alloc.create(~aUnaryPending) catch {\n"
              "            callback(ctx, .{ .status = oomStatus() });\n"
              "            return;\n"
              "        };\n"
              "        pending.* = .{ .alloc = alloc, .ctx = ctx, .callback = callback };\n"
              "        const payloads = marshalAll(~a, reqs, alloc);\n"
              "        self.bridge.clientStream(~s, payloads, pending, ~aUnaryPending.complete);\n"
              "        freeAll(payloads, alloc);\n"
              "    }\n\n")
             name svc req resp orig-name req path orig-name)]
    [(bidi)
     (format (string-append
              "    pub fn ~a(self: *~aClient, reqs: []const ~a, ctx: *anyopaque,\n"
              "        on_message: *const fn (ctx: *anyopaque, resp: ~a) void,\n"
              "        on_done: *const fn (ctx: *anyopaque, status: Status) void) void {\n"
              "        const alloc = self.bridge.alloc;\n"
              "        const pending = alloc.create(~aStreamPending) catch {\n"
              "            on_done(ctx, oomStatus());\n"
              "            return;\n"
              "        };\n"
              "        pending.* = .{ .alloc = alloc, .ctx = ctx, .on_message = on_message, .on_done = on_done };\n"
              "        const payloads = marshalAll(~a, reqs, alloc);\n"
              "        self.bridge.bidi(~s, payloads, pending, ~aStreamPending.message, ~aStreamPending.done);\n"
              "        freeAll(payloads, alloc);\n"
              "    }\n\n")
             name svc req resp orig-name req path orig-name orig-name)]))

(define (wasm-pending-structs m)
  (define orig-name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(unary client-streaming)
     (format (string-append
              "const ~aUnaryPending = struct {\n"
              "    alloc: std.mem.Allocator,\n"
              "    ctx: *anyopaque,\n"
              "    callback: *const fn (ctx: *anyopaque, result: CallResult(~a)) void,\n\n"
              "    fn complete(raw: *anyopaque, st: Status, payload: ?[]const u8) void {\n"
              "        const self: *@This() = @ptrCast(@alignCast(raw));\n"
              "        defer self.alloc.destroy(self);\n"
              "        if (!st.isOk()) {\n"
              "            self.callback(self.ctx, .{ .status = st });\n"
              "            return;\n"
              "        }\n"
              "        var resp = ~a{};\n"
              "        resp.unmarshalDc(self.alloc, payload orelse \"\");\n"
              "        self.callback(self.ctx, .{ .ok = resp });\n"
              "    }\n"
              "};\n\n")
             orig-name resp resp)]
    [(server-streaming bidi)
     (format (string-append
              "const ~aStreamPending = struct {\n"
              "    alloc: std.mem.Allocator,\n"
              "    ctx: *anyopaque,\n"
              "    on_message: *const fn (ctx: *anyopaque, resp: ~a) void,\n"
              "    on_done: *const fn (ctx: *anyopaque, status: Status) void,\n\n"
              "    fn message(raw: *anyopaque, payload: []const u8) void {\n"
              "        const self: *@This() = @ptrCast(@alignCast(raw));\n"
              "        var resp = ~a{};\n"
              "        resp.unmarshalDc(self.alloc, payload);\n"
              "        self.on_message(self.ctx, resp);\n"
              "    }\n\n"
              "    fn done(raw: *anyopaque, st: Status, _: ?[]const u8) void {\n"
              "        const self: *@This() = @ptrCast(@alignCast(raw));\n"
              "        defer self.alloc.destroy(self);\n"
              "        self.on_done(self.ctx, st);\n"
              "    }\n"
              "};\n\n")
             orig-name resp resp)]))

(define (wasm-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (apply string-append (map wasm-pending-structs methods))
     (format "/// Client for the service (browser/WASM facade; see module doc).\npub const ~aClient = struct {\n    bridge: *bridge_mod.Bridge,\n\n    pub fn init(bridge: *bridge_mod.Bridge) ~aClient {\n        return .{ .bridge = bridge };\n    }\n\n" sname sname)
     (apply string-append (map wasm-client-method* methods))
     "};\n")))

(define (emit-wasm-zig-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define messages-import (hash-ref params 'messages_import "echo_messages"))
  (define status-import (hash-ref params 'status_import "grpcdc_status"))
  (cons (string-append base "_wasm_dc.zig")
        (string-append
         "// @generated by protoc-gen-grpc-dc-wasm-zig (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "const std = @import(\"std\");\n"
         "const bridge_mod = @import(\"bridge.zig\");\n"
         (format "const status_mod = @import(~s);\n" status-import)
         (format "const messages = @import(~s);\n\n" messages-import)
         "pub const Status = status_mod.Status;\n"
         "pub const CallResult = status_mod.CallResult;\n"
         "pub const EchoRequest = messages.EchoRequest;\n"
         "pub const EchoResponse = messages.EchoResponse;\n\n"
         "fn oomStatus() Status {\n"
         "    // gRPC INTERNAL (13): a request could not be marshaled.\n"
         "    return Status.init(13, \"out of memory\");\n"
         "}\n\n"
         "fn marshalAll(comptime T: type, reqs: []const T, alloc: std.mem.Allocator) [][]u8 {\n"
         "    const out = alloc.alloc([]u8, reqs.len) catch return &.{};\n"
         "    for (reqs, 0..) |*req, i| out[i] = req.marshalDc(alloc);\n"
         "    return out;\n"
         "}\n\n"
         "fn freeAll(payloads: [][]u8, alloc: std.mem.Allocator) void {\n"
         "    for (payloads) |p| alloc.free(p);\n"
         "    if (payloads.len > 0) alloc.free(payloads);\n"
         "}\n\n"
         (apply string-append
                (map wasm-service (hash-ref file-model 'services))))))
