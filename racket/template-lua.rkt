#lang racket

;;; template-lua.rkt — emitter body spliced into protoc-gen-grpc-dc-lua.
;;;
;;; Generated code sits beside hand-written message types providing
;;; marshalDc / unmarshalDc. Statuses are raised as Lua error objects
;;; (grpcdc.status), so generated stubs mirror the exception-shaped
;;; runtimes. The service implementation is a duck-typed table.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-lua-file)

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





(define (lua-client-method m)
  (run-segments lua-client-method-program m (current-service)))

(define (lua-coro-client-stream-class m)
  (run-segments lua-coro-client-stream-class-program m (current-service)))



(define (lua-coro-client-method m)
  (run-segments lua-coro-client-method-program m (current-service)))

(define (lua-client-stream-class m)
  (run-segments lua-client-stream-class-program m (current-service)))

(define (lua-server-stream-class m)
  (run-segments lua-server-stream-class-program m (current-service)))

(define (lua-register-method m)
  (run-segments lua-register-method-program m (current-service)))

(define (lua-service svc)
  (run-segments lua-service-program svc (hash-ref svc 'name)))

;; (display-name . origin-file) for every method input/output
;; type, first-use order: the stub requires each origin file's
;; messages module and aliases the type from it.
(define (lua-stub-type-origins file-model)
  (define seen '())
  (for ([svc (in-list (hash-ref file-model 'services))])
    (for ([m (in-list (hash-ref svc 'methods))])
      (for ([pair (in-list (list (cons (hash-ref m 'input) (hash-ref m 'input-full))
                                 (cons (hash-ref m 'output) (hash-ref m 'output-full))))])
        (unless (assoc (car pair) seen)
          (set! seen
                (append seen
                        (list (cons (car pair)
                                    (hash-ref (lua-pb-resolve file-model (cdr pair))
                                              'file)))))))))
  seen)

(define (lua-stub-requires file-model)
  (if (hash-ref file-model 'types #f)
      (let ([origins (lua-stub-type-origins file-model)])
        (define files
          (remove-duplicates (map cdr origins)))
        (string-append
         (apply string-append
                (map (lambda (fn)
                       (define b (path->string
                                  (path-replace-extension (file-name-from-path fn) "")))
                       (format "local ~aMessages = require(\"examples.~a_messages\")\n"
                               (lua-pb-flat "" b) b))
                     files))
         "\n"
         (apply string-append
                (map (lambda (o)
                       (define b (path->string
                                  (path-replace-extension
                                   (file-name-from-path (cdr o)) "")))
                       (format "local ~a = ~aMessages.~a\n"
                               (car o) (lua-pb-flat "" b) (car o)))
                     origins))
         "\n"))
      (string-append
       (format "local messages = require(\"examples.~a_messages\")\n\n"
               (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
       (apply string-append
              (map (lambda (msg)
                     (format "local ~a = messages.~a\n" msg msg))
                   (lua-message-names file-model)))
       "\n")))

;; Message type names in first-use order (for the alias block).
(define (lua-message-names file-model)
  (define seen '())
  (for ([svc (in-list (hash-ref file-model 'services))])
    (for ([m (in-list (hash-ref svc 'methods))])
      (for ([t (in-list (list (hash-ref m 'input) (hash-ref m 'output)))])
        (unless (member t seen)
          (set! seen (append seen (list t)))))))
  seen)

;; ---------------------------------------------------------------------------
;; Lua message types (<base>_messages.lua, matching the stub's
;; require): tables with marshalDc/unmarshalDc methods plus local
;; Pb wire support in the same file. Dependency-free (Lua 5.3+
;; stdlib only). Mirrors the JS emitter on the shared desc.rkt
;; model.
;; ---------------------------------------------------------------------------

(define lua-pb-varint-types varint-scalar-types)
(define lua-pb-fixed (fixed-scalar-table 'lua))





(define (lua-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-lua-pb-file "unresolved type ~a" type-name))))

(define (lua-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (lua-pb-entry-flat model entry)
  (define local
    (lua-pb-flat (hash-ref entry 'pkg)
                 (if (eq? (hash-ref entry 'kind) 'enum)
                     (let ([e (hash-ref entry 'enum)])
                       (if (hash-ref entry 'msg)
                           (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                           (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                     (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (or (eq? (hash-ref entry 'kind) 'map)
          (equal? (hash-ref entry 'file) (hash-ref model 'name)))
      local
      (format "~a_messagesMessages.~a"
              (path->string (path-replace-extension
                             (file-name-from-path (hash-ref entry 'file)) ""))
              (if (eq? (hash-ref entry 'kind) 'enum)
                  (hash-ref (hash-ref entry 'enum) 'name)
                  (hash-ref (hash-ref entry 'msg) 'name)))))

(define (lua-pb-explicit-literal model f)
  (run-segments lua-pb-explicit-literal-program f #f model))

(define (lua-pb-default model f)
  (run-segments lua-pb-default-program f #f model))

(define (lua-pb-zero-field model f)
  (run-segments lua-pb-zero-field-program f #f model))

(define (lua-pb-varint-expr f v)
  (run-segments lua-pb-varint-expr-program f #f #f (list v)))

(define (lua-pb-varint-decode f v)
  (run-segments lua-pb-varint-decode-program f #f #f (list v)))





(define (lua-pb-nonzero f v)
  (run-segments lua-pb-nonzero-program f #f #f (list v)))

(define (lua-pb-encode-singular model f v indent)
  (run-segments lua-pb-encode-singular-program f #f model (list v indent)))

(define (lua-pb-set-expr sib)
  (run-segments lua-pb-set-expr-program sib #f))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.


(define (lua-pb-encode-field model f)
  (run-segments lua-pb-encode-field-program f #f model))

(define (lua-pb-decode-singular model f target src indent)
  (run-segments lua-pb-decode-singular-program f #f model (list target src indent)))

(define (lua-pb-oneof-clearing model f)
  (run-segments lua-pb-clearing-program f #f model))

(define (lua-pb-decode-case model f)
  (run-segments lua-pb-decode-case-program f #f model))

(define (lua-pb-map-helpers model entry)
  (run-segments lua-pb-map-helpers-program entry #f model))

(define lua-pb-support
  (string-append
   "-- @generated by protoc-gen-grpc-dc-lua. DO NOT EDIT.\n"
   "local Writer = {}\nWriter.__index = Writer\n\n"
   "local function bxor(a, b) return a ~ b end\n\n"
   "local function varintBytes(value)\n  local v = value\n  local parts = {}\n  if v < 0 then\n    for _ = 1, 9 do\n      parts[#parts + 1] = string.char((v & 0x7f) | 0x80)\n      v = v >> 7\n    end\n    parts[#parts + 1] = string.char(v & 0x7f)\n    return table.concat(parts)\n  end\n  while (v & ~0x7f) ~= 0 do\n    parts[#parts + 1] = string.char((v & 0x7f) | 0x80)\n    v = v >> 7\n  end\n  parts[#parts + 1] = string.char(v & 0x7f)\n  return table.concat(parts)\nend\n\n"
   "function Writer.new()\n  return setmetatable({ parts = {} }, Writer)\nend\n\n"
   "function Writer:varint(value)\n  self.parts[#self.parts + 1] = varintBytes(value)\nend\n\n"
   "function Writer:tag(field, wire)\n  self:varint((field << 3) | wire)\nend\n\n"
   "function Writer:bytesField(field, payload)\n  self:tag(field, 2)\n  self:varint(#payload)\n  self.parts[#self.parts + 1] = payload\nend\n\n"
   "function Writer:stringField(field, value)\n  if value == \"\" then return end\n  self:bytesField(field, value)\nend\n\n"
   "function Writer:fixed(fmt, value)\n  self.parts[#self.parts + 1] = string.pack(fmt, value)\nend\n\n"
   "function Writer:raw(payload)\n  self.parts[#self.parts + 1] = payload\nend\n\n"
   "function Writer:toBytes()\n  return table.concat(self.parts)\nend\n\n"
   "local Reader = {}\nReader.__index = Reader\n\n"
   "function Reader.new(buf)\n  return setmetatable({ buf = buf, pos = 1 }, Reader)\nend\n\n"
   "function Reader:done()\n  return self.pos > #self.buf\nend\n\n"
   "function Reader:varint()\n  local result = 0\n  local shift = 0\n  while true do\n    if self.pos > #self.buf then error(\"truncated varint\") end\n    local b = self.buf:byte(self.pos)\n    self.pos = self.pos + 1\n    result = result | ((b & 0x7f) << shift)\n    if (b & 0x80) == 0 then return result end\n    shift = shift + 7\n    if shift >= 70 then error(\"varint too long\") end\n  end\nend\n\n"
   "function Reader:take(n)\n  if self.pos + n - 1 > #self.buf then error(\"truncated field\") end\n  local v = self.buf:sub(self.pos, self.pos + n - 1)\n  self.pos = self.pos + n\n  return v\nend\n\n"
   "function Reader:next()\n  if self.pos > #self.buf then return nil end\n  local start = self.pos\n  local tag = self:varint()\n  local number = tag >> 3\n  local wire = tag & 7\n  if wire == 0 then\n    local v = self:varint()\n    return { number = number, wire = wire, varintValue = v, bytesValue = \"\", fixedValue = \"\", rawValue = self.buf:sub(start, self.pos - 1) }\n  elseif wire == 2 then\n    local n = self:varint()\n    local b = self:take(n)\n    return { number = number, wire = wire, varintValue = 0, bytesValue = b, fixedValue = \"\", rawValue = self.buf:sub(start, self.pos - 1) }\n  elseif wire == 1 then\n    local b = self:take(8)\n    return { number = number, wire = wire, varintValue = 0, bytesValue = \"\", fixedValue = b, rawValue = self.buf:sub(start, self.pos - 1) }\n  elseif wire == 5 then\n    local b = self:take(4)\n    return { number = number, wire = wire, varintValue = 0, bytesValue = \"\", fixedValue = b, rawValue = self.buf:sub(start, self.pos - 1) }\n  end\n  error(\"bad wire type\")\nend\n\n"))

(define (lua-pb-message-class model msg)
  (run-segments lua-pb-message-program msg #f model))

(define (lua-pb-enum model e)
  (run-segments lua-pb-enum-program e #f model))

(define (emit-lua-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-lua-pb-file/inner file-model)))

(define (emit-lua-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pkg (hash-ref file-model 'package))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define helper-names '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (lua-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (define base (lua-pb-entry-flat file-model e))
                 (set! helper-names (cons (format "~aEncode" base) (cons (format "~aDecode" base) helper-names)))
                 (set! helpers (cons (lua-pb-map-helpers file-model e) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define (all-msg-names msg)
           (if (hash-ref msg 'map-entry)
               '()
               (cons (lua-pb-flat pkg (hash-ref msg 'full-name))
                     (append-map all-msg-names (hash-ref msg 'nested)))))
         ;; Modules this file's types reference: service input/output
         ;; types re-export from the returned table.
         (define dep-modules
           (remove-duplicates
            (map (lambda (d)
                   (path->string (path-replace-extension (file-name-from-path d) "")))
                 (hash-ref file-model 'dependencies))))
         (define dep-requires
           (apply string-append
                  (map (lambda (d)
                         (format "local ~aMessages = require(\"examples.~a_messages\")\n"
                                 (lua-pb-flat "" (format "~a_messages" d)) d))
                       dep-modules)))
         (define content
           (string-append
            lua-pb-support
            (if (seg-struct-codec)
                (string-append
                 "local Structdc = require(\"grpcdc.structdc\")\n\n"
                 (format "local _STRUCTDC_DESCRIPTOR = ~a\n\n"
                         (let ([nums (map number->string
                                          (bytes->list (hash-ref file-model 'descriptor-set #"")))])
                           ;; Chunked: one huge string.char(...) call
                           ;; exceeds Lua's register limit.
                           (string-join
                            (let loop ([xs nums] [acc '()])
                              (if (null? xs)
                                  (reverse acc)
                                  (let ([n (min 100 (length xs))])
                                    (loop (drop xs n)
                                          (cons (format "string.char(~a)"
                                                        (string-join (take xs n) ","))
                                                acc)))))
                            " .. "))))
                "")
            dep-requires
            (if (string=? dep-requires "") "" "\n")
            (apply string-append
                   (map (lambda (n) (format "local ~a\n" n)) (reverse helper-names)))
            (apply string-append
                   (map (lambda (n) (format "local ~a\n" n))
                        (append-map all-msg-names messages)))
            (if (seg-struct-codec)
                (apply string-append
                       (map (lambda (n) (format "local ~aStruct\n" n))
                            (append-map all-msg-names messages)))
                "")
            (apply string-append (map (lambda (e) (lua-pb-enum file-model e)) enums))
            (apply string-append
                   (map (lambda (m) (lua-pb-message-class file-model m))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            (apply string-append (reverse helpers))
            (if (seg-struct-codec)
                (let ([out (open-output-string)])
                  (define (emit-companion msg)
                    (unless (hash-ref msg 'map-entry)
                      (define flat (lua-pb-flat pkg (hash-ref msg 'full-name)))
                      (fprintf out "~aStruct = {}\nfunction ~aStruct.marshal(m)\n  return Structdc.transcodeStruct(_STRUCTDC_DESCRIPTOR, \"~a\", m:marshalDc(), true)\nend\nfunction ~aStruct.unmarshal(data)\n  local wire = Structdc.transcodeStruct(_STRUCTDC_DESCRIPTOR, \"~a\", data, false)\n  local m = ~a.new()\n  m:unmarshalDc(wire)\n  local present = {}\n  local r = Reader.new(wire)\n  while true do\n    local field = r:next()\n    if field == nil then break end\n    present[field.number] = true\n  end\n" flat flat (hash-ref msg 'full-name) flat (hash-ref msg 'full-name) flat)
                      (for ([f (in-list (hash-ref msg 'fields))])
                        (display (lua-pb-zero-field file-model f) out))
                      (fprintf out "  return m\nend\n\n"))
                    (for ([n (in-list (hash-ref msg 'nested))]) (emit-companion n)))
                  (for ([m (in-list messages)]) (emit-companion m))
                  (get-output-string out))
                "")
            "return {\n"
            (apply string-append
                   (map (lambda (m)
                          (format "  ~a = ~a,\n" (hash-ref m 'name)
                                  (lua-pb-flat pkg (hash-ref m 'full-name))))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            (apply string-append
                   (map (lambda (e)
                          (format "  ~a = ~a,\n" (hash-ref e 'name)
                                  (lua-pb-flat pkg (if (string=? pkg "")
                                                       (hash-ref e 'name)
                                                       (format "~a.~a" pkg (hash-ref e 'name))))))
                        enums))
            "}\n"))
         (cons (string-append base "_messages.lua") content))))

(define (emit-lua-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define stub
    (cons (string-append base "_grpc_dc.lua")
          (string-append
           "-- @generated by protoc-gen-grpc-dc-lua. DO NOT EDIT.\n"
         (format "-- source: ~a\n\n" (hash-ref file-model 'name))
         "local channelModule = require(\"grpcdc.channel\")\n"
         "local serverModule = require(\"grpcdc.server\")\n"
         "local statusModule = require(\"grpcdc.status\")\n"
         "local wire = require(\"grpcdc.wire\")\n"
         (lua-stub-requires file-model)
         "local Channel = channelModule.Channel\n"
         "local Server = serverModule.Server\n"
         "local Status = statusModule.Status\n"
         "local EndOfStream = statusModule.EndOfStream\n\n"
         ;; trace=hooks: aliases into the runtime registrar.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "-- Tracing (trace=hooks@@TRACING_BETA@@): register an observer via set_tracer.\n"
              "local set_tracer = statusModule.setTracer\n"
              "local set_trace_filter = statusModule.setTraceFilter\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "statusModule.setTraceFilter(~s)\n" methods)
                    ""))
              "\n")
             "")
         (apply string-append (map lua-service (hash-ref file-model 'services)))
         (apply string-append
                (map (lambda (svc)
                       (define sname (hash-ref svc 'name))
                       (string-append
                        (format "--- Register an implementation of ~a on a Server. The impl is\n" (hash-ref svc 'full-name))
                        "--- a table with unary/serverStream/clientStream/bidi functions\n"
                        "--- (duck-typed, mirroring the generated adapters below).\n"
                        (format "local function register~aServer(server, impl)\n" sname)
                        "  server:registerService({\n"
                        (format "    name = ~s,\n" (hash-ref svc 'full-name))
                        "    methods = {\n"
                        (parameterize ([current-service sname])
                          (apply string-append
                                 (map lua-register-method
                                      (append (hash-ref svc 'methods)
                                              (alias-server-methods svc)))))
                        "    },\n"
                        "  })\n"
                        "end\n\n"))
                     (hash-ref file-model 'services)))
         "return {\n"
         (apply string-append
                (map (lambda (svc)
                       (define sname (hash-ref svc 'name))
                       (string-append
                        (format "  ~aClient = ~aClient,\n" sname sname)
                        (format "  ~aClientCoro = ~aClientCoro,\n" sname sname)
                        (apply string-append
                               (map (lambda (m)
                                      (case (hash-ref m 'kind)
                                        [(server-streaming bidi)
                                         (format "  ~a~aCoroStream = ~a~aCoroStream,\n"
                                                 sname (hash-ref m 'name) sname (hash-ref m 'name))]
                                        [else ""]))
                                    (hash-ref svc 'methods)))
                        (apply string-append
                               (map (lambda (m)
                                      (case (hash-ref m 'kind)
                                        [(server-streaming bidi)
                                         (format "  ~a~aStream = ~a~aStream,\n"
                                                 sname (hash-ref m 'name) sname (hash-ref m 'name))]
                                        [else ""]))
                                    (hash-ref svc 'methods)))
                        (apply string-append
                               (map (lambda (m)
                                      (case (hash-ref m 'kind)
                                        [(unary) ""]
                                        [else
                                         (format "  ~a~aServer = ~a~aServer,\n"
                                                 sname (hash-ref m 'name) sname (hash-ref m 'name))]))
                                    (hash-ref svc 'methods)))
                        (format "  register~aServer = register~aServer,\n" sname sname)))
                     (hash-ref file-model 'services)))
         "}\n")))
  (define pb-file (parameterize ([seg-struct-codec (equal? (hash-ref params 'struct_codec #f) "true")])
                    (emit-lua-pb-file file-model)))
  (if pb-file (list stub pb-file) stub))
