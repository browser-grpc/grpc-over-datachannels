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

(require "spec.rkt" "desc.rkt" "segments.rkt")
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





(define (zig-client-method m)
  (run-segments zig-client-method-program m (current-service) #f (list "    ")))

(define (zig-client-stream-class m)
  (run-segments zig-client-stream-class-program m (current-service)))

(define (zig-server-stream-struct m)
  (run-segments zig-server-stream-struct-program m (current-service)))

(define (zig-server-vtable-field m)
  (run-segments zig-server-vtable-field-program m (current-service)))

(define (zig-adapter m)
  (run-segments zig-adapter-program m (current-service)))

(define (zig-register-method m)
  (run-segments zig-register-method-program m (current-service)))

(define (zig-service svc)
  (run-segments zig-service-program svc (hash-ref svc 'name)))

;; (simple-name . origin-base) pairs for method input/output
;; types in first-use order: a stub's message types may live in
;; imported protos, so imports and re-exports are per origin file.
(define (zig-type-origins file-model)
  (define seen '())
  (for ([svc (in-list (hash-ref file-model 'services))])
    (for ([m (in-list (hash-ref svc 'methods))])
      (for ([pair (in-list (list (cons (hash-ref m 'input) (hash-ref m 'input-full))
                                 (cons (hash-ref m 'output) (hash-ref m 'output-full))))])
        (unless (assoc (car pair) seen)
          (define entry (zig-pb-resolve file-model (cdr pair)))
          (set! seen (append seen (list (cons (car pair)
                                              (path->string (path-replace-extension (file-name-from-path (hash-ref entry 'file)) ""))))))))))
  seen)

(define (zig-stub-imports file-model)
  (cond [(not (hash-has-key? file-model 'types))
         (format "const messages = @import(\"~a_messages.zig\");\n\n"
                 (path->string (path-replace-extension (file-name-from-path (hash-ref file-model 'name)) "")))]
        [else
         (define bases (remove-duplicates (map cdr (zig-type-origins file-model))))
         (string-append
          (apply string-append
                 (map (lambda (b) (format "const ~a_messages = @import(\"~a_messages.zig\");\n" b b))
                      bases))
          "\n")]))

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

(define zig-pb-varint-types varint-scalar-types)
(define zig-pb-fixed (fixed-scalar-table 'zig))

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

(define (zig-pb-scalar f) (scalar-type-entry 'zig (hash-ref f 'type)))

(define (zig-pb-entry-struct-name model entry)
  (string-replace (zig-pb-entry-ref model entry) "." "_"))


(define (zig-pb-type model f)
  (run-segments zig-pb-type-program f #f model))

(define (zig-pb-explicit-literal model f)
  (run-segments zig-pb-explicit-literal-program f #f model))

(define (zig-pb-default model f)
  (run-segments zig-pb-default-program f #f model))

(define (zig-pb-varint-expr f v)
  (run-segments zig-pb-varint-expr-program f #f #f (list v)))

(define (zig-pb-varint-decode f v)
  (run-segments zig-pb-varint-decode-program f #f #f (list v)))

(define (zig-pb-nonzero f v)
  (run-segments zig-pb-nonzero-program f #f #f (list v)))

(define (zig-pb-encode-singular model f v indent)
  (run-segments zig-pb-encode-singular-program f #f model (list v indent)))

(define (zig-pb-set-expr sib)
  (run-segments zig-pb-set-expr-program sib #f))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.


(define (zig-pb-encode-field model f)
  (run-segments zig-pb-encode-field-program f #f model))

(define (zig-pb-decode-singular model f target src indent alloc?)
  (run-segments zig-pb-decode-singular-program f #f model (list target src indent)))

(define (zig-pb-oneof-clearing model f)
  (run-segments zig-pb-clearing-program f #f model))

(define (zig-pb-decode-case model f)
  (run-segments zig-pb-decode-case-program f #f model))

(define (zig-pb-map-helpers model entry)
  (run-segments zig-pb-map-helpers-program entry #f model))

(define (zig-pb-support)
  (string-append
   "// @generated by protoc-gen-grpc-dc-zig. DO NOT EDIT.\n"
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
   "    pub fn raw(self: *PbWriter, payload: []const u8) void { self.list.appendSlice(self.alloc, payload) catch {}; }\n"
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
   "    number: u32,\n    wire: u3,\n    varint_value: u64 = 0,\n    bytes_value: []const u8 = &.{},\n    fixed_value: u64 = 0,\n    raw_value: []const u8 = &.{},\n"
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
   "        const start = self.pos;\n"
   "        const tagv = self.varint();\n"
   "        var field = PbField{ .number = @as(u32, @truncate(tagv >> 3)), .wire = @as(u3, @truncate(tagv & 7)) };\n"
   "        switch (field.wire) {\n"
   "            0 => field.varint_value = self.varint(),\n"
   "            2 => { const n = self.varint(); field.bytes_value = self.take(@as(usize, @truncate(n))); },\n"
   "            1 => { field.bytes_value = self.take(8); field.fixed_value = std.mem.readInt(u64, field.bytes_value[0..8], .little); },\n"
   "            5 => { field.bytes_value = self.take(4); field.fixed_value = std.mem.readInt(u32, field.bytes_value[0..4], .little); },\n"
   "            else => return null,\n"
   "        }\n"
   "        field.raw_value = self.buf[start..self.pos];\n"
   "        return field;\n"
   "    }\n"
   "};\n\n"))

(define (zig-pb-message-struct model msg indent)
  (run-segments zig-pb-message-program msg #f model (list indent)))

(define (zig-pb-nested-enum e indent)
  (run-segments zig-pb-nested-enum-program e #f #f (list indent)))

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
               (when (eq? (hash-ref e 'kind) 'map)
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
           "// @generated by protoc-gen-grpc-dc-zig. DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "const std = @import(\"std\");\n"
         "const grpcdc = @import(\"grpcdc\");\n"
         "const channel_mod = grpcdc.channel;\n"
         "const endpoint_mod = grpcdc.endpoint;\n"
         "const server_mod = grpcdc.server;\n"
         "const status_mod = grpcdc.status;\n"
         "const wire = grpcdc.wire;\n"
         (zig-stub-imports file-model)
         "pub const Channel = channel_mod.Channel;\n"
         "pub const ClientStream = channel_mod.ClientStream;\n"
         "pub const CallContext = endpoint_mod.CallContext;\n"
         "pub const Server = server_mod.Server;\n"
         "pub const Status = status_mod.Status;\n"
         "pub const Metadata = channel_mod.Metadata;\n"
         ;; trace=hooks: re-export the tracer registrar.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "\n/// Tracing (trace=hooks): register an observer via setTracer.\n"
              "pub const setTracer = status_mod.setTracer;\n"
              "pub const setTraceFilter = status_mod.setTraceFilter;\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "\n/// Apply the baked-in trace filter (trace_methods) once.\npub fn applyTraceFilter() void {\n    status_mod.setTraceFilter(~s);\n}\n" methods)
                    "")))
             "")
         (if (hash-has-key? file-model 'types)
             (apply string-append
                    (map (lambda (pair)
                           (format "pub const ~a = ~a_messages.~a;\n" (car pair) (cdr pair) (car pair)))
                         (zig-type-origins file-model)))
             (apply string-append
                    (map (lambda (msg)
                           (format "pub const ~a = messages.~a;\n" msg msg))
                         (zig-message-names file-model))))
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
