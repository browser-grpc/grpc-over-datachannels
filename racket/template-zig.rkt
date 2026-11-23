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
            (if (seg-struct-codec) (format "const _structdc = @import(\"~a_struct.zig\");\n" base) "")
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
              "\n/// Tracing (trace=hooks@@TRACING_BETA@@): register an observer via setTracer.\n"
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
  (define pb-file (parameterize ([seg-struct-codec (equal? (hash-ref params 'struct_codec #f) "true")])
                    (emit-zig-pb-file file-model)))
  (define struct-file (emit-zig-struct-file file-model params))
  (if struct-file
      (append (list stub pb-file) (list struct-file))
      (if pb-file (list stub pb-file) stub)))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true): <Msg>Struct namespace per
;; message in <base>_struct.zig with the packed layout from
;; SPEC.md (byte-identical to the other struct codecs; verified
;; by conformance/struct).
(define (zg-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (zg-struct-fixed32-type? t) (member t '(2 7 15)))
(define (zg-struct-fixed64-type? t) (member t '(1 6 16)))

(define (zg-struct-slot-size f)
  (if (zg-struct-fixed32-type? (hash-ref f 'type)) 4 8))

(define (zg-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (zg-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (zig-pb-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (zg-struct-map-key-field model f)
  (define em (hash-ref (zg-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (zg-struct-map-val-field model f)
  (define em (hash-ref (zg-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (zg-struct-type-name model msg)
  (string-replace (zig-pb-rel (hash-ref model 'package) (hash-ref msg 'full-name)) "." "_"))

(define (zg-struct-class-name model f)
  (define e (zig-pb-resolve model (hash-ref f 'type-name)))
  (zig-pb-entry-struct-name model e))

(define (zg-struct-companion model f)
  (string-append (zg-struct-class-name model f) "Struct"))

(define (zg-struct-present model f fn)
  (define t (hash-ref f 'type))
  (cond [(zg-struct-map-entry model f) (format "m.~a.len > 0" fn)]
        [(= (hash-ref f 'label) 3) (format "m.~a.len > 0" fn)]
        [(= t 11) (format "m.~a != null" fn)]
        [(= t 9) (format "m.~a.len > 0" fn)]
        [(= t 12) (format "m.~a.len > 0" fn)]
        [(= t 8) (format "m.~a" fn)]
        [(= t 14) (format "@intFromEnum(m.~a) != 0" fn)]
        [else (format "m.~a != 0" fn)]))

(define (zg-struct-scalar-encode f v)
  (define t (hash-ref f 'type))
  (cond [(zg-struct-fixed32-type? t)
         (cond [(= t 2) (format "put32(buf, off, @as(u32, @bitCast(~a)));" v)]
               [(= t 7) (format "put32(buf, off, ~a);" v)]
               [else (format "put32(buf, off, @as(u32, @bitCast(~a)));" v)])]
        [(zg-struct-fixed64-type? t)
         (cond [(= t 1) (format "put64(buf, off, @as(u64, @bitCast(~a)));" v)]
               [(= t 6) (format "put64(buf, off, ~a);" v)]
               [else (format "put64(buf, off, @as(u64, @bitCast(~a)));" v)])]
        [(= t 8) (format "buf[off] = if (~a) 1 else 0;" v)]
        [(= t 14) (format "put64(buf, off, @as(u64, @bitCast(@as(i64, @intFromEnum(~a)))));" v)]
        [(member t '(5 17)) (format "put64(buf, off, @as(u64, @bitCast(@as(i64, ~a))));" v)]
        [(member t '(3 18)) (format "put64(buf, off, @as(u64, @bitCast(~a)));" v)]
        [(= t 13) (format "put64(buf, off, @as(u64, ~a));" v)]
        [else (format "put64(buf, off, ~a);" v)]))

(define (zg-struct-scalar-value/off model f offv)
  (define t (hash-ref f 'type))
  (cond [(zg-struct-fixed32-type? t)
         (cond [(= t 2) (format "@as(f32, @bitCast(get32(data, ~a)))" offv)]
               [(= t 7) (format "get32(data, ~a)" offv)]
               [else (format "@as(i32, @bitCast(get32(data, ~a)))" offv)])]
        [(zg-struct-fixed64-type? t)
         (cond [(= t 1) (format "@as(f64, @bitCast(get64(data, ~a)))" offv)]
               [(= t 6) (format "get64(data, ~a)" offv)]
               [else (format "@as(i64, @bitCast(get64(data, ~a)))" offv)])]
        [(= t 8) (format "(data[~a] != 0)" offv)]
        [(= t 14) (format "@as(~a, @enumFromInt(@as(i32, @bitCast(get32(data, ~a)))))"
                          (zig-pb-type model (hash-set f 'label 1)) offv)]
        [(member t '(5 17)) (format "@as(i32, @bitCast(get32(data, ~a)))" offv)]
        [(= t 13) (format "get32(data, ~a)" offv)]
        [(= t 3) (format "@as(i64, @bitCast(get64(data, ~a)))" offv)]
        [else (format "get64(data, ~a)" offv)]))

(define (zg-struct-value-size model f v)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "~a.len" v)]
        [(= t 12) (format "~a.len" v)]
        [(= t 11) (format "~a.sizeOf(&~a)" (zg-struct-companion model f) v)]
        [(zg-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (zg-struct-message model msg)
  (define type-name (zg-struct-type-name model msg))
  (define full-name (hash-ref msg 'full-name))
  (define out (open-output-string))
  (fprintf out "pub const ~aStruct = struct {\n" type-name)
  (fprintf out "    pub const fingerprint: u32 = 0x~x;\n\n" (zg-struct-fingerprint full-name))
  (fprintf out "    pub fn marshal(m: *const ~a, alloc: std.mem.Allocator) ![]u8 {\n        const pb = m.marshalDc(alloc);\n        defer alloc.free(pb);\n        return structdc_detail.transcode(true, \"~a\", pb, alloc);\n    }\n\n" type-name full-name)
  (fprintf out "    pub fn unmarshal(alloc: std.mem.Allocator, data: []const u8) !~a {\n        const pb = try structdc_detail.transcode(false, \"~a\", data, alloc);\n        defer alloc.free(pb);\n        var m = ~a{};\n        m.unmarshalDc(alloc, pb);\n        return m;\n    }\n};\n\n" type-name full-name type-name)
  (get-output-string out))

(define (zg-struct-value-write model f v)
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (cond [(= t 9)
         (fprintf out "                @memcpy(buf[vp..][0..~a.len], ~a); vp += ~a.len;\n" v v v)]
        [(= t 12)
         (fprintf out "                @memcpy(buf[vp..][0..~a.len], ~a); vp += ~a.len;\n" v v v)]
        [(= t 11)
         (fprintf out "                { const nb = try ~a.marshal(&~a, alloc); defer alloc.free(nb); @memcpy(buf[vp..][0..nb.len], nb); vp += nb.len; }\n"
                  (zg-struct-companion model f) v)]
        [else
         (fprintf out "                { const off = vp; ~a } vp += ~a;\n"
                  (zg-struct-scalar-encode f v) (if (zg-struct-fixed32-type? t) 4 8))])
  (get-output-string out))

(define (zg-struct-marshal-field model f off)
  (define fn (hash-ref f 'name))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" fn))
  (cond [(zg-struct-map-entry model f)
         (define kf (zg-struct-map-key-field model f))
         (define vf (zg-struct-map-val-field model f))
         (define entry (zg-struct-class-name model f))
         (define kt (hash-ref kf 'type))
         (define less-expr
           (cond [(= kt 9) "std.mem.lessThan(u8, a.key, b.key)"]
                 [else "a.key < b.key"]))
         (fprintf out "        if (m.~a.len > 0) {\n            put32(buf, ~a, @as(u32, @truncate(vp))); put32(buf, ~a, @as(u32, @truncate(m.~a.len)));\n" fn off (+ off 4) fn)
         (fprintf out "            const ord = try alloc.dupe(~a, m.~a);\n            std.mem.sort(~a, ord, {}, struct { fn less(_: void, a: ~a, b: ~a) bool { return ~a; } }.less);\n"
                  entry fn entry entry entry less-expr)
         (fprintf out "            for (ord) |e| {\n                put32(buf, vp, @as(u32, @truncate(~a))); put32(buf, vp + 4, @as(u32, @truncate(~a))); vp += 8;\n"
                  (zg-struct-value-size model kf "e.key") (zg-struct-value-size model vf "e.value"))
         (display (zg-struct-value-write model kf "e.key") out)
         (display (zg-struct-value-write model vf "e.value") out)
         (fprintf out "            }\n            alloc.free(ord);\n        }\n")]
        [(= (hash-ref f 'label) 3)
         (cond [(member t '(9 12))
                (fprintf out "        if (m.~a.len > 0) {\n            put32(buf, ~a, @as(u32, @truncate(vp))); put32(buf, ~a, @as(u32, @truncate(m.~a.len)));\n            var doff = vp + 8 * m.~a.len;\n            for (m.~a) |e| { put32(buf, vp, @as(u32, @truncate(doff))); put32(buf, vp + 4, @as(u32, @truncate(e.len))); doff += e.len; vp += 8; }\n            for (m.~a) |e| { @memcpy(buf[vp..][0..e.len], e); vp += e.len; }\n        }\n"
                         fn off (+ off 4) fn fn fn fn)]
               [(= t 11)
                (fprintf out "        if (m.~a.len > 0) {\n            put32(buf, ~a, @as(u32, @truncate(vp))); put32(buf, ~a, @as(u32, @truncate(m.~a.len)));\n            var doff = vp + 8 * m.~a.len;\n            for (m.~a) |e| { const es = ~a.sizeOf(&e); put32(buf, vp, @as(u32, @truncate(doff))); put32(buf, vp + 4, @as(u32, @truncate(es))); doff += es; vp += 8; }\n            for (m.~a) |e| { const nb = try ~a.marshal(&e, alloc); defer alloc.free(nb); @memcpy(buf[vp..][0..nb.len], nb); vp += nb.len; }\n        }\n"
                         fn off (+ off 4) fn fn fn (zg-struct-companion model f)
                         fn (zg-struct-companion model f))]
               [else
                (fprintf out "        if (m.~a.len > 0) {\n            put32(buf, ~a, @as(u32, @truncate(vp))); put32(buf, ~a, @as(u32, @truncate(m.~a.len)));\n            for (m.~a) |e| { const off = vp; ~a vp += ~a; }\n        }\n"
                         fn off (+ off 4) fn
                         fn
                         (zg-struct-scalar-encode f "e")
                         (if (zg-struct-fixed32-type? t) 4 8))])]
        [(= t 11)
         (fprintf out "        if (m.~a) |p| {\n            put32(buf, ~a, @as(u32, @truncate(vp))); put32(buf, ~a, @as(u32, @truncate(~a.sizeOf(p))));\n            const nb = try ~a.marshal(p, alloc); defer alloc.free(nb); @memcpy(buf[vp..][0..nb.len], nb); vp += nb.len;\n        }\n"
                  fn off (+ off 4) (zg-struct-companion model f) (zg-struct-companion model f))]
        [(member t '(9 12))
         (fprintf out "        if (m.~a.len > 0) {\n            put32(buf, ~a, @as(u32, @truncate(vp))); put32(buf, ~a, @as(u32, @truncate(m.~a.len)));\n            @memcpy(buf[vp..][0..m.~a.len], m.~a); vp += m.~a.len;\n        }\n"
                  fn off (+ off 4) fn fn fn fn)]
        [else
         (fprintf out "        { const off: usize = ~a; ~a }\n" off (zg-struct-scalar-encode f mv))])
  (get-output-string out))

(define (zg-struct-value-expr/off model f lenvar offv)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "try alloc.dupe(u8, data[~a..][0..~a])" offv lenvar)]
        [(= t 12) (format "try alloc.dupe(u8, data[~a..][0..~a])" offv lenvar)]
        [(= t 11) (format "try ~a.unmarshal(alloc, data[~a..][0..~a])" (zg-struct-companion model f) offv lenvar)]
        [else (zg-struct-scalar-value/off model f offv)]))

(define (zg-struct-decode-field model f foff)
  (define fn (hash-ref f 'name))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" fn))
  (cond [(zg-struct-map-entry model f)
         (define kf (zg-struct-map-key-field model f))
         (define vf (zg-struct-map-val-field model f))
         (define entry (zg-struct-class-name model f))
         (fprintf out "            const off = get32(data, ~a); const n = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            var p: usize = off;\n            const entries = try alloc.alloc(~a, n);\n            for (entries) |*e| {\n" entry)
         (fprintf out "                try check(data, p, 8);\n                const kl = get32(data, p); const vl = get32(data, p + 4); p += 8;\n                try check(data, p, kl + vl);\n")
         (fprintf out "                e.key = blk: { const io = p; break :blk ~a; };\n" (zg-struct-value-expr/off model kf "kl" "io"))
         (fprintf out "                e.value = blk: { const io = p + kl; break :blk ~a; };\n" (zg-struct-value-expr/off model vf "vl" "io"))
         (fprintf out "                p += kl + vl;\n            }\n            m.~a = entries;\n            if (p > vend) vend = p;\n" fn)]
        [(= (hash-ref f 'label) 3)
         (define et (if (= t 11) (zg-struct-class-name model f)
                        (zig-pb-type model (hash-set f 'label 1))))
         (fprintf out "            const off = get32(data, ~a); const n = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            const arr = try alloc.alloc(~a, n);\n            m.~a = arr;\n" et fn)
         (cond [(member t '(9 12))
                (fprintf out "            for (arr, 0..) |*slot, i| {\n                const eo = get32(data, off + 8 * i); const el = get32(data, off + 8 * i + 4);\n                try check(data, eo, el);\n                slot.* = try alloc.dupe(u8, data[eo..][0..el]);\n                if (eo + el > vend) vend = eo + el;\n            }\n")]
               [(= t 11)
                (fprintf out "            for (arr, 0..) |*slot, i| {\n                const eo = get32(data, off + 8 * i); const el = get32(data, off + 8 * i + 4);\n                if (el > 0) {\n                    try check(data, eo, el);\n                    slot.* = try ~a.unmarshal(alloc, data[eo..][0..el]);\n                    if (eo + el > vend) vend = eo + el;\n                }\n            }\n"
                         (zg-struct-companion model f))]
               [else
                (define esz (if (zg-struct-fixed32-type? t) 4 8))
                (fprintf out "            try check(data, off, n * ~a);\n            for (arr, 0..) |*slot, i| {\n                const eo = off + i * ~a;\n                slot.* = ~a;\n            }\n            if (off + n * ~a > vend) vend = off + n * ~a;\n"
                         esz esz (zg-struct-scalar-value/off model f "eo") esz esz)])]
        [(= t 11)
         (fprintf out "            const off = get32(data, ~a); const el = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            try check(data, off, el);\n            { const np = try alloc.create(~a); np.* = try ~a.unmarshal(alloc, data[off..][0..el]); m.~a = np; }\n            if (off + el > vend) vend = off + el;\n"
                  (zg-struct-class-name model f) (zg-struct-companion model f) fn)]
        [(member t '(9 12))
         (fprintf out "            const off = get32(data, ~a); const el = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            try check(data, off, el);\n            m.~a = try alloc.dupe(u8, data[off..][0..el]);\n            if (off + el > vend) vend = off + el;\n" fn)]
        [else
         (fprintf out "            const off: usize = ~a;\n            m.~a = ~a;\n" foff fn
                  (zg-struct-scalar-value/off model f "off"))])
  (get-output-string out))

(define (emit-zig-struct-file file-model params)
  (and (equal? (hash-ref params 'struct_codec #f) "true")
       (hash-has-key? file-model 'messages)
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define (walk msg)
           (if (hash-ref msg 'map-entry)
               '()
               (append (append-map walk (hash-ref msg 'nested)) (list msg))))
         (define all (append-map walk (hash-ref file-model 'messages)))
         (define content
           (string-append
            "// @generated by protoc-gen-grpc-dc-zig. DO NOT EDIT.\n"
            (format "// source: ~a\n\n" (hash-ref file-model 'name))
            "const std = @import(\"std\");\n"
            (format "const messages = @import(\"~a_messages.zig\");\n" base)
            (apply string-append
                   (map (lambda (m)
                          (format "const ~a = messages.~a;\n" (zg-struct-type-name file-model m) (zg-struct-type-name file-model m)))
                        all))
            (let ([seen (mutable-set)] [out '()])
                     (for ([m (in-list all)])
                       (for ([f (in-list (hash-ref m 'fields))])
                         (when (zg-struct-map-entry file-model f)
                           (define en (zg-struct-class-name file-model f))
                           (unless (set-member? seen en)
                             (set-add! seen en)
                             (set! out (cons (format "const ~a = messages.~a;\n" en en) out))))))
                     (apply string-append (reverse out)))
            (apply string-append
                   (map (lambda (e)
                          (format "const ~a = messages.~a;\n" (hash-ref e 'name) (hash-ref e 'name)))
                        (hash-ref file-model 'enums)))
            (apply string-append
                   (map (lambda (m)
                          (apply string-append
                                 (map (lambda (e)
                                        (format "const ~a_~a = messages.~a_~a;\n"
                                                (zg-struct-type-name file-model m) (hash-ref e 'name)
                                                (zg-struct-type-name file-model m) (hash-ref e 'name)))
                                      (hash-ref m 'enums))))
                        all))
            "\n"
            "extern fn grpcdc_struct_encode(desc: [*]const u8, desc_len: usize, type_name: [*]const u8, type_len: usize, input: [*]const u8, input_len: usize, out: *?[*]u8, out_len: *usize, err_out: *?[*]u8) i32;\n"
            "extern fn grpcdc_struct_decode(desc: [*]const u8, desc_len: usize, type_name: [*]const u8, type_len: usize, input: [*]const u8, input_len: usize, out: *?[*]u8, out_len: *usize, err_out: *?[*]u8) i32;\n"
            "extern fn grpcdc_struct_free(ptr: [*]u8, len: usize) void;\n"
            "extern fn grpcdc_struct_error_free(ptr: [*]u8) void;\n\n"
            "const structdc_detail = struct {\n"
            (format "    const descriptor = [_]u8{~a};\n"
                    (string-join (for/list ([b (in-bytes (hash-ref file-model 'descriptor-set #""))]) (format "0x~x" b)) ","))
            "    fn transcode(encode: bool, type_name: []const u8, input: []const u8, alloc: std.mem.Allocator) ![]u8 {\n"
            "        var out: ?[*]u8 = null;\n        var out_len: usize = 0;\n        var err: ?[*]u8 = null;\n"
            "        const rc = if (encode) grpcdc_struct_encode(&descriptor, descriptor.len, type_name.ptr, type_name.len, input.ptr, input.len, &out, &out_len, &err) else grpcdc_struct_decode(&descriptor, descriptor.len, type_name.ptr, type_name.len, input.ptr, input.len, &out, &out_len, &err);\n"
            "        if (rc != 0) { if (err) |e| grpcdc_struct_error_free(e); return error.StructCodec; }\n"
            "        const raw = out.?[0..out_len];\n        const copy = try alloc.dupe(u8, raw);\n        grpcdc_struct_free(out.?, out_len);\n        return copy;\n    }\n};\n\n"
            (apply string-append
                   (map (lambda (m) (zg-struct-message file-model m)) all))))
         (cons (string-append base "_struct.zig") content))))
