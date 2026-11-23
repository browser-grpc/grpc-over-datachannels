#lang racket

;;; template-python.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-python.
;;;
;;; Generated code lives beside hand-written message types in a
;;; `<base>_pb` module (classes with marshal_dc()/unmarshal_dc()),
;;; and imports the runtime as grpcdc. Method names keep the proto
;;; spelling (Unary, ServerStream, ...), mirroring the Go stub.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-python-file)

(define current-service (make-parameter ""))

(define (snake sym) ; EchoService -> echo_service
  (define s (symbol->string sym))
  (apply string-append
         (for/list ([c (in-string s)] [i (in-naturals)])
           (cond [(char-upper-case? c)
                  (string-append (if (> i 0) "_" "") (string (char-downcase c)))]
                 [else (string c)]))))

(define (py-deprecated m)
  (run-segments py-deprecated-program m ""))
(define (py-client-method/raw pb m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    def ~a(self, req, metadata=None, timeout=None):\n"
              "~a        return self._channel.unary(~s, req, ~a.~a(), metadata, timeout)\n\n")
             name (py-deprecated m) path pb resp)]
    [(server-streaming)
     (format (string-append
              "    def ~a(self, req, metadata=None, timeout=None):\n"
              "~a        stream = self._channel.server_stream(~s, req, metadata, timeout)\n"
              "        return _RecvStream(stream, ~a.~a)\n\n")
             name (py-deprecated m) path pb resp)]
    [(client-streaming)
     (format (string-append
              "    def ~a(self, reqs, metadata=None, timeout=None):\n"
              "~a        return self._channel.client_stream(~s, reqs, ~a.~a(), metadata, timeout)\n\n")
             name (py-deprecated m) path pb resp)]
    [(bidi)
     (format (string-append
              "    def ~a(self, reqs, metadata=None, timeout=None):\n"
              "~a        stream = self._channel.bidi(~s, reqs, metadata, timeout)\n"
              "        return _RecvStream(stream, ~a.~a)\n\n")
             name (py-deprecated m) path pb resp)]))

(define (py-client-method pb m)
  (run-segments py-client-method-program m "" #f (list pb)))
(define (py-async-client-method/raw pb m)
  (run-segments py-async-client-method-program m "" #f (list pb)))
(define (py-server-handler pb m)
  (run-segments py-server-handler-program m (current-service) #f (list pb)))
(define (py-method-entry m)
  (run-segments py-method-entry-program m ""))
(define py-stream-helpers
  (string-append
   "class _RecvStream:\n"
   "    \"\"\"Client receiving stream: recv() raises EOFError at end.\"\"\"\n\n"
   "    def __init__(self, stream, resp_cls):\n"
   "        self._stream = stream\n"
   "        self._resp_cls = resp_cls\n\n"
   "    def recv(self):\n"
   "        if self._stream is None:\n"
   "            raise EOFError(\"stream closed\")\n"
   "        return self._stream.recv(self._resp_cls())\n\n"
   "    def close(self):\n"
   "        \"\"\"Abandon the call early: RST so the server stops.\"\"\"\n"
   "        stream, self._stream = self._stream, None\n"
   "        if stream is not None:\n"
   "            stream.cancel()\n\n"
   "    def __del__(self):\n"
   "        self.close()\n\n"
   "    def __enter__(self):\n"
   "        return self\n\n"
   "    def __exit__(self, *exc):\n"
   "        self.close()\n"
   "        return False\n\n"
   "    def __iter__(self):\n"
   "        return self\n\n"
   "    def __next__(self):\n"
   "        try:\n"
   "            return self.recv()\n"
   "        except EOFError:\n"
   "            raise StopIteration\n\n\n"
   "class _SendStream:\n"
   "    \"\"\"Server-streaming sink passed to service implementations.\"\"\"\n\n"
   "    def __init__(self, ctx, sink):\n"
   "        self.context = ctx\n"
   "        self._sink = sink\n\n"
   "    def send(self, resp):\n"
   "        self._sink.send(self.context.encode_message(resp))\n\n\n"
   "class _ClientStreamImpl:\n"
   "    \"\"\"Client-streaming stream passed to service implementations.\"\"\"\n\n"
   "    def __init__(self, ctx, reqs, req_cls):\n"
   "        self.context = ctx\n"
   "        self._reqs = reqs\n"
   "        self._req_cls = req_cls\n"
   "        self.resp = None\n\n"
   "    def recv(self):\n"
   "        return self._reqs.recv_into(self._req_cls())\n\n"
   "    def send_and_close(self, resp):\n"
   "        self.resp = resp\n\n\n"
   "class _BidiStream:\n"
   "    \"\"\"Bidi stream passed to service implementations.\"\"\"\n\n"
   "    def __init__(self, ctx, reqs, sink, req_cls):\n"
   "        self.context = ctx\n"
   "        self._reqs = reqs\n"
   "        self._sink = sink\n"
   "        self._req_cls = req_cls\n\n"
   "    def send(self, resp):\n"
   "        self._sink.send(self.context.encode_message(resp))\n\n"
   "    def recv(self):\n"
   "        return self._reqs.recv_into(self._req_cls())\n\n\n"
   "class _AsyncRecvStream:\n"
   "    \"\"\"Async client receiving stream: async-for or await recv().\"\"\"\n\n"
   "    def __init__(self, stream, resp_cls):\n"
   "        self._stream = stream\n"
   "        self._resp_cls = resp_cls\n\n"
   "    async def recv(self):\n"
   "        return await self._stream.recv(self._resp_cls())\n\n"
   "    def cancel(self):\n"
   "        self._stream.cancel()\n\n"
   "    async def aclose(self):\n"
   "        self.cancel()\n\n"
   "    def __aiter__(self):\n"
   "        return self\n\n"
   "    async def __anext__(self):\n"
   "        try:\n"
   "            return await self.recv()\n"
   "        except EOFError:\n"
   "            raise StopAsyncIteration\n\n\n"))

(define (py-service pb svc)
  (run-segments py-service-program svc (hash-ref svc 'name) #f (list pb)))
(define py-pb-preamble
  (string-append
   "import struct as _struct\n\n\n"
   "def _append_varint(out, value):\n"
   "    v = value & 0xFFFFFFFFFFFFFFFF\n"
   "    while v > 0x7F:\n"
   "        out.append((v & 0x7F) | 0x80)\n"
   "        v >>= 7\n"
   "    out.append(v)\n"
   "    return out\n\n\n"
   "def _append_tag(out, field, wire):\n"
   "    return _append_varint(out, (field << 3) | wire)\n\n\n"
   "def _append_varint_field(out, field, value):\n"
   "    if value == 0:\n"
   "        return out\n"
   "    out = _append_tag(out, field, 0)\n"
   "    return _append_varint(out, value)\n\n\n"
   "def _append_bytes_field(out, field, data):\n"
   "    out = _append_tag(out, field, 2)\n"
   "    out = _append_varint(out, len(data))\n"
   "    out.extend(data)\n"
   "    return out\n\n\n"
   "def _append_string_field(out, field, value):\n"
   "    if value == \"\":\n"
   "        return out\n"
   "    return _append_bytes_field(out, field, value.encode(\"utf-8\"))\n\n\n"
   "def _append_fixed_field(out, field, payload):\n"
   "    out = _append_tag(out, field, 1 if len(payload) == 8 else 5)\n"
   "    out.extend(payload)\n"
   "    return out\n\n\n"
   "class _Reader:\n"
   "    def __init__(self, buf):\n"
   "        self.buf = bytes(buf)\n"
   "        self.pos = 0\n\n"
   "    def varint(self):\n"
   "        result = 0\n"
   "        shift = 0\n"
   "        while True:\n"
   "            if self.pos >= len(self.buf):\n"
   "                raise ValueError(\"truncated varint\")\n"
   "            b = self.buf[self.pos]\n"
   "            self.pos += 1\n"
   "            result |= (b & 0x7F) << shift\n"
   "            if not (b & 0x80):\n"
   "                return result\n"
   "            shift += 7\n"
   "            if shift >= 64:\n"
   "                raise ValueError(\"varint too long\")\n\n"
   "    def take(self, n):\n"
   "        if self.pos + n > len(self.buf):\n"
   "            raise ValueError(\"truncated field\")\n"
   "        value = self.buf[self.pos:self.pos + n]\n"
   "        self.pos += n\n"
   "        return value\n\n"
   "    def field(self):\n"
   "        if self.pos >= len(self.buf):\n"
   "            return None\n"
   "        start = self.pos\n"
   "        tag = self.varint()\n"
   "        num, wire = tag >> 3, tag & 7\n"
   "        if wire == 0:\n"
   "            return num, wire, self.varint(), self.buf[start:self.pos]\n"
   "        if wire == 2:\n"
   "            return num, wire, self.take(self.varint()), self.buf[start:self.pos]\n"
   "        if wire == 1:\n"
   "            return num, wire, self.take(8), self.buf[start:self.pos]\n"
   "        if wire == 5:\n"
   "            return num, wire, self.take(4), self.buf[start:self.pos]\n"
   "        raise ValueError(\"bad wire type\")\n\n\n"
   "def _as_int32(value):\n"
   "    return ((value & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000\n\n\n"
   "def _as_int64(value):\n"
   "    return ((value & 0xFFFFFFFFFFFFFFFF) ^ 0x8000000000000000) - 0x8000000000000000\n\n\n"
   "def _unzz32(value):\n"
   "    v = value & 0xFFFFFFFF\n"
   "    return (v >> 1) ^ -(v & 1)\n\n\n"
   "def _unzz64(value):\n"
   "    v = value & 0xFFFFFFFFFFFFFFFF\n"
   "    return (v >> 1) ^ -(v & 1)\n\n\n"))

(define pb-varint-types varint-scalar-types) ; int64 uint64 int32 bool uint32 enum sint32 sint64
(define pb-fixed-formats (map (lambda (e) (cons (first e) (third e))) (fixed-scalar-table 'python)))
(define pb-fixed-sizes (map (lambda (e) (cons (first e) (second e))) (fixed-scalar-table 'python)))

(define (py-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg ""))
                       (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (py-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-python-pb-file "unresolved type ~a" type-name))))

(define (py-pb-ref model entry)
  (define flat (py-pb-flat (hash-ref entry 'pkg)
                           (if (eq? (hash-ref entry 'kind) 'enum)
                               ;; 'full includes the parent message:
                               ;; nested enums must not collide on
                               ;; their simple name.
                               (hash-ref entry 'full)
                               (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (equal? (hash-ref entry 'file) (hash-ref model 'name))
      flat
      (format "~a_pb.~a" (path->string (path-replace-extension
                                        (file-name-from-path (hash-ref entry 'file)) ""))
              flat)))

(define (py-pb-varint-expr f v)
  (run-segments py-pb-varint-expr-program f "" #f (list v)))
(define (py-pb-varint-decode f v)
  (run-segments py-pb-varint-decode-program f "" #f (list v)))
(define (py-pb-explicit-literal model f)
  (define lit (run-segments py-pb-explicit-literal-program f "" model))
  (and (not (string=? lit "")) lit))
(define (py-pb-default f model)
  (run-segments py-pb-default-program f "" model))
(define (py-pb-encode-singular model f v indent)
  (run-segments py-pb-encode-singular-program f "" model (list v indent)))
(define (py-pb-encode-field model f)
  (run-segments py-pb-encode-field-program f "" model))
(define (py-pb-decode-singular model f target src indent)
  (run-segments py-pb-decode-singular-program f "" model (list target src indent)))
(define (py-pb-oneof-clearing model f)
  (run-segments py-pb-oneof-clearing-program f "" model))
(define (py-pb-decode-case model f first?)
  (run-segments py-pb-decode-case-program f "" model (list (if first? "if" "elif"))))
(define (py-pb-map-helpers model entry)
  (run-segments py-pb-map-helpers-program entry "" model))
(define (py-pb-default-expr model f)
  (run-segments py-pb-default-expr-program f "" model))
(define (py-pb-init-line model f)
  (run-segments py-pb-init-line-program f "" model))
(define (py-pb-class model msg)
  (run-segments py-pb-message-program msg "" model))
(define (py-pb-enum entry)
  (run-segments py-pb-enum-program entry ""))
(define (emit-python-pb-file file-model)
  ;; Models without message metadata (synthetic test models that
  ;; predate the desc 'types registry) get no pb companion; real
  ;; desc.rkt models always carry 'messages/'types.
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (let/ec return-false
         (emit-python-pb-file/inner file-model return-false))))

(define (emit-python-pb-file/inner file-model return-false)
  (define messages (hash-ref file-model 'messages))
  ;; Types the stubs import from this file's pb module: re-export
  ;; any living in imported files so generated code runs as-is.
  (define service-types
    (remove-duplicates
     (append-map (lambda (svc)
                   (append-map (lambda (m) (list (hash-ref m 'input-full) (hash-ref m 'output-full)))
                               (hash-ref svc 'methods)))
                 (hash-ref file-model 'services))))
  (define imports (make-hash)) ; dep file -> set of flat names
  (define reexports (make-hash))
  (define (add-import! entry also-export?)
    (unless (equal? (hash-ref entry 'file) (hash-ref file-model 'name))
      (define flat (py-pb-ref file-model entry))
      (define dep (hash-ref entry 'file))
      (hash-update! imports dep (lambda (s) (set-add s flat)) (set))
      (when also-export?
        (hash-update! reexports dep (lambda (s) (set-add s flat)) (set)))))
  (define (scan-fields msg)
    (for ([f (in-list (hash-ref msg 'fields))])
      (when (memv (hash-ref f 'type) '(11 14))
        (define e (py-pb-resolve file-model (hash-ref f 'type-name)))
        (add-import! e #f)
        (when (and (= (hash-ref f 'type) 11) (eq? (hash-ref e 'kind) 'map))
          (for ([ef (in-list (hash-ref (hash-ref e 'msg) 'fields))])
            (when (memv (hash-ref ef 'type) '(11 14))
              (add-import! (py-pb-resolve file-model (hash-ref ef 'type-name)) #f))))))
    (for ([n (in-list (hash-ref msg 'nested))]) (scan-fields n)))
  (for ([m (in-list messages)]) (scan-fields m))
  (for ([t (in-list service-types)])
    (define e (hash-ref (hash-ref file-model 'types) t #f))
    (when (and e (not (eq? (hash-ref e 'kind) 'enum))) (add-import! e #t)))
  ;; Always emit the pb companion for real files: the stub imports
  ;; it unconditionally, even for message-less (empty/enums-only)
  ;; schemas.
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define out (open-output-string))
  (fprintf out "# @generated by protoc-gen-grpc-dc-python. DO NOT EDIT.\n")
  (fprintf out "# source: ~a\n\n" (hash-ref file-model 'name))
  (fprintf out "\"\"\"Generated protobuf messages (dependency-free wire format).\"\"\"\n\n")
  (when (seg-struct-codec)
    (fprintf out "from grpcdc.structdc import transcode_struct as _grpcdc_transcode\n\n")
    (fprintf out "_STRUCTDC_DESCRIPTOR = bytes([~a])\n\n"
             (string-join
              (map number->string
                   (bytes->list (hash-ref file-model 'descriptor-set #"")))
              ",")))
  (for ([dep (in-list (sort (hash-keys imports) string<?))])
    (define dep-base (path->string (path-replace-extension (file-name-from-path dep) "")))
    (fprintf out "try:\n    from . import ~a_pb\nexcept ImportError:  # direct module load\n    import ~a_pb\n\n" dep-base dep-base))
  (when (positive? (hash-count reexports))
    (for ([dep (in-list (sort (hash-keys reexports) string<?))])
      (for ([flat (in-list (sort (set->list (hash-ref reexports dep)) string<?))])
        (define short (last (string-split flat ".")))
        (fprintf out "~a = ~a\n" short flat)))
    (fprintf out "\n"))
  (display py-pb-preamble out)
  ;; enums (file-level + nested), map helpers, then classes
  (define (all-enum-entries)
    (define acc '())
    (define (walk msg)
      (for ([e (in-list (hash-ref msg 'enums))])
        (set! acc (cons (hash-ref (hash-ref file-model 'types)
                                  (format "~a.~a" (hash-ref msg 'full-name) (hash-ref e 'name)))
                        acc)))
      (for ([n (in-list (hash-ref msg 'nested))]) (walk n)))
    (for ([m (in-list messages)]) (walk m))
    (for ([e (in-list (hash-ref file-model 'enums))])
      (set! acc (cons (hash-ref (hash-ref file-model 'types)
                                (if (string=? (hash-ref file-model 'package) "")
                                    (hash-ref e 'name)
                                    (format "~a.~a" (hash-ref file-model 'package) (hash-ref e 'name))))
                      acc)))
    (reverse acc))
  (define seen-enums (mutable-set))
  (for ([e (in-list (all-enum-entries))])
    (when e
      (define flat (py-pb-flat (hash-ref e 'pkg)
                               (if (hash-ref e 'msg)
                                   (format "~a.~a" (hash-ref (hash-ref e 'msg) 'full-name) (hash-ref (hash-ref e 'enum) 'name))
                                   (if (string=? (hash-ref e 'pkg) "") (hash-ref (hash-ref e 'enum) 'name)
                                       (format "~a.~a" (hash-ref e 'pkg) (hash-ref (hash-ref e 'enum) 'name))))))
      (unless (set-member? seen-enums flat)
        (set-add! seen-enums flat)
        (display (py-pb-enum e) out))))
  (define seen-maps (mutable-set))
  (define (emit-map-helpers msg)
    (for ([f (in-list (hash-ref msg 'fields))])
      (when (= (hash-ref f 'type) 11)
        (define e (py-pb-resolve file-model (hash-ref f 'type-name)))
        (when (and (eq? (hash-ref e 'kind) 'map)
                   (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
          (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
          (display (py-pb-map-helpers file-model e) out))))
    (for ([n (in-list (hash-ref msg 'nested))]) (emit-map-helpers n)))
  (for ([m (in-list messages)]) (emit-map-helpers m))
  (define exported (mutable-set))
  (define (emit-msg msg)
    (unless (hash-ref msg 'map-entry)
      (display (py-pb-class file-model msg) out)
      (set-add! exported (py-pb-flat (hash-ref file-model 'package) (hash-ref msg 'full-name)))
      (for ([n (in-list (hash-ref msg 'nested))]) (emit-msg n))))
  (for ([m (in-list messages)]) (emit-msg m))
  (when (seg-struct-codec)
    (define (emit-companion msg)
      (unless (hash-ref msg 'map-entry)
        (define flat (py-pb-flat (hash-ref file-model 'package) (hash-ref msg 'full-name)))
        (fprintf out "class ~aStruct:\n    @staticmethod\n    def marshal(m):\n        return _grpcdc_transcode(_STRUCTDC_DESCRIPTOR, \"~a\", m.marshal_dc(), True)\n\n    @staticmethod\n    def unmarshal(data):\n        m = ~a()\n        m.unmarshal_dc(_grpcdc_transcode(_STRUCTDC_DESCRIPTOR, \"~a\", data, False))\n        return m\n\n\n" flat (hash-ref msg 'full-name) flat (hash-ref msg 'full-name)))
      (for ([n (in-list (hash-ref msg 'nested))]) (emit-companion n)))
    (for ([m (in-list messages)]) (emit-companion m)))
  ;; Simple-name aliases for nested messages (stubs import the
  ;; simple name), when unambiguous.
  (define (emit-aliases msg)
    (for ([n (in-list (hash-ref msg 'nested))])
      (when (and (not (hash-ref n 'map-entry))
                 (not (set-member? exported (hash-ref n 'name))))
        (fprintf out "~a = ~a\n" (hash-ref n 'name)
                 (py-pb-flat (hash-ref file-model 'package) (hash-ref n 'full-name)))
        (set-add! exported (hash-ref n 'name)))
      (emit-aliases n)))
  (for ([m (in-list messages)]) (emit-aliases m))
  (cons (string-append base "_pb.py") (get-output-string out)))

(define (emit-python-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define pb (string-append base "_pb"))
  (define stub
    (cons (string-append base "_grpc_dc.py")
        (string-append
         "# @generated by protoc-gen-grpc-dc-python. DO NOT EDIT.\n"
         (format "# source: ~a\n\n" (hash-ref file-model 'name))
         (format "try:\n    from . import ~a\nexcept ImportError:  # direct module load\n    import ~a\n\n" pb pb)
         "import grpcdc\n"
         ;; trace=hooks: re-export the runtime tracer registrar so
         ;; tracing can be wired from generated code alone.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "\n# trace=hooks: register an observer via grpcdc.set_tracer(...)\nset_tracer = grpcdc.set_tracer\nset_trace_filter = grpcdc.set_trace_filter\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "grpcdc.set_trace_filter(~s)\n" methods)
                    "")))
             "")
         "\n"
         py-stream-helpers
         (apply string-append
                (map (lambda (svc) (py-service pb svc))
                     (hash-ref file-model 'services))))))
  (define pb-file (parameterize ([seg-struct-codec (equal? (hash-ref params 'struct_codec #f) "true")])
                    (emit-python-pb-file file-model)))
  (if pb-file (list stub pb-file) stub))
