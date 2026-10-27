#lang racket

;;; template-ruby.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-ruby.
;;;
;;; Generated code lives beside hand-written message types in a
;;; `<base>_pb` file (module <Base>Pb, classes with
;;; marshal_dc/unmarshal_dc), and requires the runtime as
;;; grpcdc. Method names keep the proto spelling (Unary,
;;; ServerStream, ...), mirroring the Python stub.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-ruby-file)

(define current-service (make-parameter ""))

(define (snake sym) ; EchoService -> echo_service
  (define s (symbol->string sym))
  (apply string-append
         (for/list ([c (in-string s)] [i (in-naturals)])
           (cond [(char-upper-case? c)
                  (string-append (if (> i 0) "_" "") (string (char-downcase c)))]
                 [else (string c)]))))

(define (camel str) ; "echo" -> "Echo", "my_svc" -> "MySvc"
  (apply string-append
         (for/list ([part (in-list (string-split str "_"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (rb-deprecated m)
  (run-segments rb-deprecated-program m ""))
(define (rb-client-method model m)
  (run-segments rb-client-method-program m "" model))
(define (rb-fiber-client-method model m)
  (run-segments rb-fiber-client-method-program m "" model))
(define (rb-server-handler model m)
  (run-segments rb-server-handler-program m "" model))
(define (rb-method-entry m)
  (run-segments rb-method-entry-program m ""))
(define rb-stream-helpers
  (string-append
   "  # Client receiving stream: recv raises EOFError at end.\n"
   "  class RecvStream\n"
   "    include Enumerable\n\n"
   "    def initialize(stream, resp_cls)\n"
   "      @stream = stream\n"
   "      @resp_cls = resp_cls\n"
   "    end\n\n"
   "    def recv\n"
   "      @stream.recv(@resp_cls.new)\n"
   "    end\n\n"
   "    # Response initial metadata (after the first recv).\n"
   "    def headers\n"
   "      @stream.headers&.metadata\n"
   "    end\n\n"
   "    # Response trailing metadata (after the call ends).\n"
   "    def trailers\n"
   "      @stream.trailers\n"
   "    end\n\n"
   "    # Abandon the call early: RST so the server stops producing.\n"
   "    def cancel\n"
   "      @stream.cancel\n"
   "    end\n\n"
   "    def close\n"
   "      @stream.cancel\n"
   "    end\n\n"
   "    def each\n"
   "      return enum_for(:each) unless block_given?\n\n"
   "      begin\n"
   "        loop do\n"
   "          begin\n"
   "            yield recv\n"
   "          rescue EOFError\n"
   "            return\n"
   "          end\n"
   "        end\n"
   "      ensure\n"
   "        # Breaking out of the block abandons the call: RST so\n"
   "        # the server stops producing (no-op once terminated).\n"
   "        close\n"
   "      end\n"
   "    end\n"
   "  end\n\n"
   "  # Server-streaming sink passed to service implementations.\n"
   "  class SendStream\n"
   "    attr_reader :context\n\n"
   "    def initialize(ctx, sink)\n"
   "      @context = ctx\n"
   "      @sink = sink\n"
   "    end\n\n"
   "    def send(resp)\n"
   "      @sink.send(resp.marshal_dc)\n"
   "    end\n"
   "  end\n\n"
   "  # Client-streaming stream passed to service implementations.\n"
   "  class ClientStreamImpl\n"
   "    attr_reader :context, :resp\n\n"
   "    def initialize(ctx, reqs, req_cls)\n"
   "      @context = ctx\n"
   "      @reqs = reqs\n"
   "      @req_cls = req_cls\n"
   "      @resp = nil\n"
   "    end\n\n"
   "    def recv\n"
   "      @reqs.recv_into(@req_cls.new)\n"
   "    end\n\n"
   "    def send_and_close(resp)\n"
   "      @resp = resp\n"
   "    end\n"
   "  end\n\n"
   "  # Bidi stream passed to service implementations.\n"
   "  class BidiStream\n"
   "    attr_reader :context\n\n"
   "    def initialize(ctx, reqs, sink, req_cls)\n"
   "      @context = ctx\n"
   "      @reqs = reqs\n"
   "      @sink = sink\n"
   "      @req_cls = req_cls\n"
   "    end\n\n"
   "    def send(resp)\n"
   "      @sink.send(resp.marshal_dc)\n"
   "    end\n\n"
   "    def recv\n"
   "      @reqs.recv_into(@req_cls.new)\n"
   "    end\n"
   "  end\n\n"
   "  # Fiber-based client receiving stream: a producer Fiber\n"
   "  # yields each response; next_msg resumes it and raises\n"
   "  # StopIteration when the call completes. cancel aborts\n"
   "  # the underlying stream (RST).\n"
   "  class FiberRecvStream\n"
   "    include Enumerable\n\n"
   "    DONE = Object.new\n\n"
   "    def initialize(stream, resp_cls)\n"
   "      @stream = stream\n"
   "      @resp_cls = resp_cls\n"
   "      @fiber = Fiber.new do\n"
   "        begin\n"
   "          loop { Fiber.yield(@stream.recv(@resp_cls.new)) }\n"
   "        rescue EOFError\n"
   "          DONE\n"
   "        end\n"
   "      end\n"
   "    end\n\n"
   "    def next_msg\n"
   "      value = @fiber.resume\n"
   "      raise StopIteration if value.equal?(DONE)\n\n"
   "      value\n"
   "    end\n\n"
   "    # Response initial metadata (after the first recv).\n"
   "    def headers\n"
   "      @stream.headers&.metadata\n"
   "    end\n\n"
   "    # Response trailing metadata (after the call ends).\n"
   "    def trailers\n"
   "      @stream.trailers\n"
   "    end\n\n"
   "    def cancel\n"
   "      @stream.cancel\n"
   "    end\n\n"
   "    def close\n"
   "      @stream.cancel\n"
   "    end\n\n"
   "    def each\n"
   "      return enum_for(:each) unless block_given?\n\n"
   "      begin\n"
   "        loop do\n"
   "          begin\n"
   "            yield next_msg\n"
   "          rescue StopIteration\n"
   "            return\n"
   "          end\n"
   "        end\n"
   "      ensure\n"
   "        # Breaking out of the block abandons the call: RST so\n"
   "        # the server stops producing (no-op once terminated).\n"
   "        close\n"
   "      end\n"
   "    end\n"
   "  end\n\n"))

(define (rb-service model svc)
  (run-segments rb-service-program svc (hash-ref svc 'name) model))
(define rb-pb-varint-types varint-scalar-types)
;; type -> (size pack-format) ; pack: e/E float/double, V/Q< unsigned
;; fixed, l</q< signed fixed.
(define rb-pb-fixed (fixed-scalar-table 'ruby))

(define (rb-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (rb-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-ruby-pb-file "unresolved type ~a" type-name))))

;; Stub-side reference to a message type: always qualified with
;; the pb module of the file that defines it (method types often
;; live in an imported file, not the service's own file).
(define (rb-stub-ref file-model full)
  (define e (rb-pb-resolve file-model full))
  (format "~a::~a" (rb-pb-module-name e)
          (rb-pb-flat (hash-ref e 'pkg)
                      (hash-ref (hash-ref e 'msg) 'full-name))))

;; require_relative lines for the pb module of every file that
;; defines a method input/output type.
(define (rb-stub-requires file-model)
  (if (hash-ref file-model 'types #f)
      (apply string-append
             (map (lambda (fn)
                    (format "require_relative \"~a_pb\"\n"
                            (path->string
                             (path-replace-extension (file-name-from-path fn) ""))))
                  (remove-duplicates
                   (append-map
                    (lambda (svc)
                      (append-map
                       (lambda (m)
                         (list (hash-ref (rb-pb-resolve file-model (hash-ref m 'input-full)) 'file)
                               (hash-ref (rb-pb-resolve file-model (hash-ref m 'output-full)) 'file)))
                       (hash-ref svc 'methods)))
                    (hash-ref file-model 'services)))))
      (format "require_relative \"~a_pb\"\n"
              (path->string (path-replace-extension
                             (file-name-from-path (hash-ref file-model 'name)) "")))))

(define (rb-pb-module-name entry)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref entry 'file)) "")))
  (string-append (camel base) "Pb"))

(define (rb-pb-entry-ref model entry)
  (define local
    (rb-pb-flat (hash-ref entry 'pkg)
                (if (eq? (hash-ref entry 'kind) 'enum)
                    (let ([e (hash-ref entry 'enum)])
                      (if (hash-ref entry 'msg)
                          (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                          (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                    (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (or (eq? (hash-ref entry 'kind) 'map)
          (equal? (hash-ref entry 'file) (hash-ref model 'name)))
      local
      (format "~a::~a" (rb-pb-module-name entry)
              (if (eq? (hash-ref entry 'kind) 'enum)
                  (hash-ref (hash-ref entry 'enum) 'name)
                  (rb-pb-flat (hash-ref entry 'pkg)
                              (hash-ref (hash-ref entry 'msg) 'full-name))))))

(define (rb-pb-field-name f) (hash-ref f 'name))

(define (rb-pb-explicit-literal model f)
  (define lit (run-segments rb-pb-explicit-literal-program f "" model))
  (and (not (string=? lit "")) lit))
(define (rb-pb-default model f)
  (run-segments rb-pb-default-program f "" model))
(define (rb-pb-varint-expr f v)
  (run-segments rb-pb-varint-expr-program f "" #f (list v)))
(define (rb-pb-varint-decode f v)
  (run-segments rb-pb-varint-decode-program f "" #f (list v)))
(define (rb-pb-nonzero f v)
  (run-segments rb-pb-nonzero-program f "" #f (list v)))
(define (rb-pb-encode-singular model pb f v indent)
  (run-segments rb-pb-encode-singular-program f "" model (list v indent)))
(define (rb-pb-encode-field model pb f)
  (run-segments rb-pb-encode-field-program f "" model (list pb)))
(define (rb-pb-decode-singular model f target src indent)
  (run-segments rb-pb-decode-singular-program f "" model (list target src indent)))
(define (rb-pb-oneof-clearing model f)
  (run-segments rb-pb-oneof-clearing-program f "" model))
(define (rb-pb-decode-case model f)
  (run-segments rb-pb-decode-case-program f "" model))
(define (rb-pb-map-helpers model pb entry)
  (run-segments rb-pb-map-helpers-program entry "" model (list pb)))
(define (rb-pb-support pb)
  (string-append
   "# @generated by protoc-gen-grpc-dc-ruby. DO NOT EDIT.\n"
   (format "~aPbVarint = lambda do |value|\n  out = +\"\".b\n  v = value & 0xffffffffffffffff\n  while v > 0x7f\n    out << ((v & 0x7f) | 0x80)\n    v >>= 7\n  end\n  out << v\n  out\nend\n\n" pb)
   "  class Writer\n"
   "    def initialize\n      @out = String.new(encoding: Encoding::BINARY)\n    end\n\n"
   "    def varint(value)\n      @out << " pb "PbVarint.call(value)\n    end\n\n"
   "    def tag(field, wire)\n      varint((field << 3) | wire)\n    end\n\n"
   "    def bytes_field(field, payload)\n      tag(field, 2)\n      varint(payload.bytesize)\n      @out << payload.b\n    end\n\n"
   "    def string_field(field, value)\n      return if value.nil? || value.empty?\n\n      bytes_field(field, value.encode(Encoding::UTF_8).b)\n    end\n\n"
   "    def fixed(fmt, value)\n      @out << [value].pack(fmt)\n    end\n\n"
   "    def raw(payload)\n      @out << payload.b\n    end\n\n"
   "    def to_bytes\n      @out\n    end\n  end\n\n"
   "  class Reader\n"
   "    def initialize(buf)\n      @buf = buf.b\n      @pos = 0\n    end\n\n"
   "    def done?\n      @pos >= @buf.bytesize\n    end\n\n"
   "    def varint\n      result = 0\n      shift = 0\n      loop do\n        raise ArgumentError, \"truncated varint\" if @pos >= @buf.bytesize\n\n        b = @buf.getbyte(@pos)\n        @pos += 1\n        result |= (b & 0x7f) << shift\n        return result if (b & 0x80).zero?\n\n        shift += 7\n        raise ArgumentError, \"varint too long\" if shift >= 70\n      end\n    end\n\n"
   "    def take(n)\n      raise ArgumentError, \"truncated field\" if @pos + n > @buf.bytesize\n\n      value = @buf.byteslice(@pos, n)\n      @pos += n\n      value\n    end\n\n"
   "    # [number, wire, varint_value, bytes_value, fixed_value] or nil.\n"
   "    def field\n      return nil if done?\n\n      start = @pos\n      tag = varint\n      num = tag >> 3\n      wire = tag & 7\n      raw = -> { @buf.byteslice(start, @pos - start) }\n      case wire\n      when 0 then [num, wire, varint, \"\".b, \"\".b, raw.call]\n      when 2\n        n = varint\n        v = take(n)\n        [num, wire, 0, v, \"\".b, raw.call]\n      when 1\n        v = take(8)\n        [num, wire, 0, \"\".b, v, raw.call]\n      when 5\n        v = take(4)\n        [num, wire, 0, \"\".b, v, raw.call]\n      else raise ArgumentError, \"bad wire type\"\n      end\n    end\n  end\n\n"))

(define (rb-pb-message-class model pb msg)
  (run-segments rb-pb-message-program msg "" model (list pb)))
(define (rb-pb-enum model e)
  (run-segments rb-pb-enum-program e "" model
                (list (if (string=? (hash-ref model 'package) "")
                          (hash-ref e 'name)
                          (format "~a.~a" (hash-ref model 'package) (hash-ref e 'name))))))
(define (emit-ruby-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-ruby-pb-file/inner file-model)))

(define (emit-ruby-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pb (camel base))
         (define pkg (hash-ref file-model 'package))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (rb-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (rb-pb-map-helpers file-model pb e) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define dep-modules
           (remove-duplicates
            (map (lambda (d)
                   (path->string (path-replace-extension (file-name-from-path d) "")))
                 (hash-ref file-model 'dependencies))))
         (define content
           (string-append
            (apply string-append
                   (map (lambda (d) (format "require_relative \"~a_pb\"\n" d)) dep-modules))
            (if (null? dep-modules) "" "\n")
            (format "module ~aPb\n" pb)
            (rb-pb-support pb)
            (apply string-append (map (lambda (e) (rb-pb-enum file-model e)) enums))
            (apply string-append
                   (map (lambda (m) (rb-pb-message-class file-model pb m))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            (apply string-append (reverse helpers))
            "end\n"))
         (cons (string-append base "_pb.rb") content))))

(define (emit-ruby-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define mod (string-append (camel base) "GrpcDc"))
  (define stub
    (cons (string-append base "_grpc_dc.rb")
        (string-append
         "# @generated by protoc-gen-grpc-dc-ruby. DO NOT EDIT.\n"
         (format "# source: ~a\n\n" (hash-ref file-model 'name))
         (rb-stub-requires file-model)
         "require \"grpcdc\"\n\n"
         (format "module ~a\n" mod)
         ;; trace=hooks: delegate the tracer registrar to the runtime.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "  # Tracing (trace=hooks): register an observer via set_tracer.\n"
              "  def self.set_tracer(t)\n    Grpcdc.set_tracer(t)\n  end\n\n"
              "  def self.set_trace_filter(patterns)\n    Grpcdc.set_trace_filter(patterns)\n  end\n\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "  Grpcdc.set_trace_filter(~s)\n\n" methods)
                    "")))
             "")
         rb-stream-helpers
         (apply string-append
                (map (lambda (svc) (rb-service file-model svc))
                     (hash-ref file-model 'services)))
         "end\n")))
  (define pb-file (emit-ruby-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
