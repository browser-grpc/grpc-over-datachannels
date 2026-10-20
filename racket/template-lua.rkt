#lang racket

;;; template-lua.rkt — emitter body spliced into protoc-gen-grpc-dc-lua.
;;;
;;; Generated code sits beside hand-written message types providing
;;; marshalDc / unmarshalDc. Statuses are raised as Lua error objects
;;; (grpcdc.status), so generated stubs mirror the exception-shaped
;;; runtimes. The service implementation is a duck-typed table.

(require "spec.rkt" "desc.rkt")
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

(define (lua-deprecated m)
  (if (hash-ref m 'deprecated #f)
      "--- Deprecated in the proto schema.\n"
      ""))

(define (lua-client-method/raw m)
  (define name (lower-first (hash-ref m 'name)))
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "function ~aClient:~a(req, metadata, timeout)\n"
              "  local resp = ~a.new()\n"
              "  self.channel:unary(~s, req, resp, metadata, timeout)\n"
              "  return resp\n"
              "end\n\n")
             svc name resp path)]
    [(server-streaming)
     (format (string-append
              "function ~aClient:~a(req, metadata, timeout)\n"
              "  return ~a~aStream.new(\n"
              "    self.channel:serverStream(~s, req, metadata, timeout))\n"
              "end\n\n")
             svc name svc orig-name path)]
    [(client-streaming)
     (format (string-append
              "function ~aClient:~a(reqs, metadata, timeout)\n"
              "  local resp = ~a.new()\n"
              "  self.channel:clientStreamCall(~s, reqs, resp, metadata, timeout)\n"
              "  return resp\n"
              "end\n\n")
             svc name resp path)]
    [(bidi)
     (format (string-append
              "function ~aClient:~a(reqs, metadata, timeout)\n"
              "  return ~a~aStream.new(self.channel:bidi(~s, reqs, metadata, timeout))\n"
              "end\n\n")
             svc name svc orig-name path)]))

(define (lua-client-method m)
  (string-append (lua-deprecated m) (lua-client-method/raw m)))

(define (lua-coro-client-stream-class m)
  (define orig-name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming bidi)
     (format (string-append
              "--- Coroutine receiving stream for ~a responses: a producer\n"
              "--- coroutine yields each response; next() returns nil at the\n"
              "--- end of the call and raises a Status on trailers errors.\n"
              "local ~a~aCoroStream = {}\n"
              "~a~aCoroStream.__index = ~a~aCoroStream\n\n"
              "function ~a~aCoroStream.new(stream)\n"
              "  local self = setmetatable({ stream = stream }, ~a~aCoroStream)\n"
              "  self.co = coroutine.create(function()\n"
              "    while true do\n"
              "      local resp = ~a.new()\n"
              "      stream:recv(resp)\n"
              "      coroutine.yield(resp)\n"
              "    end\n"
              "  end)\n"
              "  return self\n"
              "end\n\n"
              "function ~a~aCoroStream:next()\n"
              "  if coroutine.status(self.co) == \"dead\" then return nil end\n"
              "  local ok, value = coroutine.resume(self.co)\n"
              "  if not ok then\n"
              "    if value == EndOfStream then return nil end\n"
              "    error(value, 0)\n"
              "  end\n"
              "  return value\n"
              "end\n\n"
              "function ~a~aCoroStream:cancel()\n"
              "  self.stream:cancel()\n"
              "end\n\n"
              "--- Generic-for iterator: for resp in stream:iter() do ... end\n"
              "function ~a~aCoroStream:iter()\n"
              "  return function() return self:next() end\n"
              "end\n\n")
             orig-name svc orig-name svc orig-name svc orig-name
             svc orig-name svc orig-name resp
             svc orig-name svc orig-name svc orig-name)]
    [else ""]))

(define (lua-coro-client-method m)
  (define name (lower-first (hash-ref m 'name)))
  (define orig-name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "function ~aClientCoro:~a(req, metadata, timeout)\n"
              "  local resp = ~a.new()\n"
              "  self.channel:unary(~s, req, resp, metadata, timeout)\n"
              "  return resp\n"
              "end\n\n")
             svc name resp path)]
    [(server-streaming)
     (format (string-append
              "function ~aClientCoro:~a(req, metadata, timeout)\n"
              "  return ~a~aCoroStream.new(\n"
              "    self.channel:serverStream(~s, req, metadata, timeout))\n"
              "end\n\n")
             svc name svc orig-name path)]
    [(client-streaming)
     (format (string-append
              "function ~aClientCoro:~a(reqs, metadata, timeout)\n"
              "  local resp = ~a.new()\n"
              "  self.channel:clientStreamCall(~s, reqs, resp, metadata, timeout)\n"
              "  return resp\n"
              "end\n\n")
             svc name resp path)]
    [(bidi)
     (format (string-append
              "function ~aClientCoro:~a(reqs, metadata, timeout)\n"
              "  return ~a~aCoroStream.new(self.channel:bidi(~s, reqs, metadata, timeout))\n"
              "end\n\n")
             svc name svc orig-name path)]))

(define (lua-client-stream-class m)
  (define orig-name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming bidi)
     (format (string-append
              "--- Receiving stream for ~a responses.\n"
              "local ~a~aStream = {}\n"
              "~a~aStream.__index = ~a~aStream\n\n"
              "function ~a~aStream.new(stream)\n"
              "  return setmetatable({ stream = stream }, ~a~aStream)\n"
              "end\n\n"
              "--- Next response; raises EndOfStream at the end of the call.\n"
              "function ~a~aStream:recv()\n"
              "  local resp = ~a.new()\n"
              "  self.stream:recv(resp)\n"
              "  return resp\n"
              "end\n\n")
             orig-name svc orig-name svc orig-name svc orig-name
             svc orig-name svc orig-name svc orig-name resp)]
    [else ""]))

(define (lua-server-stream-class m)
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "--- Server-streaming sink passed to service implementations.\n"
              "local ~a~aServer = {}\n"
              "~a~aServer.__index = ~a~aServer\n\n"
              "function ~a~aServer.new(sink)\n"
              "  return setmetatable({ sink = sink }, ~a~aServer)\n"
              "end\n\n"
              "function ~a~aServer:send(resp)\n"
              "  self.sink(resp:marshalDc())\n"
              "end\n\n")
             svc orig-name svc orig-name svc orig-name svc orig-name
             svc orig-name svc orig-name)]
    [(client-streaming)
     (format (string-append
              "--- Client-streaming stream passed to service implementations.\n"
              "local ~a~aServer = {}\n"
              "~a~aServer.__index = ~a~aServer\n\n"
              "function ~a~aServer.new(reqs)\n"
              "  return setmetatable({ reqs = reqs, resp = nil }, ~a~aServer)\n"
              "end\n\n"
              "function ~a~aServer:recv()\n"
              "  local req = ~a.new()\n"
              "  self.reqs:recvInto(req)\n"
              "  return req\n"
              "end\n\n"
              "function ~a~aServer:sendAndClose(resp)\n"
              "  self.resp = resp\n"
              "end\n\n")
             svc orig-name svc orig-name svc orig-name svc orig-name
             svc orig-name svc orig-name req svc orig-name)]
    [(bidi)
     (format (string-append
              "--- Bidi stream passed to service implementations.\n"
              "local ~a~aServer = {}\n"
              "~a~aServer.__index = ~a~aServer\n\n"
              "function ~a~aServer.new(reqs, sink)\n"
              "  return setmetatable({ reqs = reqs, sink = sink }, ~a~aServer)\n"
              "end\n\n"
              "function ~a~aServer:send(resp)\n"
              "  self.sink(resp:marshalDc())\n"
              "end\n\n"
              "function ~a~aServer:recv()\n"
              "  local req = ~a.new()\n"
              "  self.reqs:recvInto(req)\n"
              "  return req\n"
              "end\n\n")
             svc orig-name svc orig-name svc orig-name svc orig-name
             svc orig-name svc orig-name svc orig-name req)]))

(define (lua-register-method m)
  (define name (hash-ref m 'name))
  (define impl-name (lower-first (method-impl-name m)))
  (define req (hash-ref m 'input))
  (define svc (current-service))
  (define kind-const
    (case (hash-ref m 'kind)
      [(unary) "KIND_UNARY"]
      [(server-streaming) "KIND_SERVER_STREAMING"]
      [(client-streaming) "KIND_CLIENT_STREAMING"]
      [(bidi) "KIND_BIDI"]))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "      {\n"
              "        name = ~s,\n"
              "        path = ~s,\n"
              "        kind = Server.~a,\n"
              "        handler = function(ctx, reqs, sink)\n"
              "          local req = ~a.new()\n"
              "          reqs:recvInto(req)\n"
              "          sink(impl:~a(ctx, req):marshalDc())\n"
              "        end,\n"
              "      },\n")
             name (hash-ref m 'path) kind-const req impl-name)]
    [(server-streaming)
     (format (string-append
              "      {\n"
              "        name = ~s,\n"
              "        path = ~s,\n"
              "        kind = Server.~a,\n"
              "        handler = function(ctx, reqs, sink)\n"
              "          local req = ~a.new()\n"
              "          reqs:recvInto(req)\n"
              "          impl:~a(ctx, req, ~a~aServer.new(sink))\n"
              "        end,\n"
              "      },\n")
             name (hash-ref m 'path) kind-const req impl-name svc name)]
    [(client-streaming)
     (format (string-append
              "      {\n"
              "        name = ~s,\n"
              "        path = ~s,\n"
              "        kind = Server.~a,\n"
              "        handler = function(ctx, reqs, sink)\n"
              "          local stream = ~a~aServer.new(reqs)\n"
              "          impl:~a(ctx, stream)\n"
              "          local resp = stream.resp\n"
              "          if resp == nil then\n"
              "            error(Status.new(wire.CODE_INTERNAL,\n"
              "              \"client-streaming handler never called sendAndClose\"), 0)\n"
              "          end\n"
              "          sink(resp:marshalDc())\n"
              "        end,\n"
              "      },\n")
             name (hash-ref m 'path) kind-const svc name impl-name)]
    [(bidi)
     (format (string-append
              "      {\n"
              "        name = ~s,\n"
              "        path = ~s,\n"
              "        kind = Server.~a,\n"
              "        handler = function(ctx, reqs, sink)\n"
              "          impl:~a(ctx, ~a~aServer.new(reqs, sink))\n"
              "        end,\n"
              "      },\n")
             name (hash-ref m 'path) kind-const impl-name svc name)]))

(define (lua-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (apply string-append (map lua-client-stream-class methods))
     (apply string-append (map lua-server-stream-class methods))
     (format "--- Client for ~a.\n" (hash-ref svc 'full-name))
     (format "local ~aClient = {}\n" sname)
     (format "~aClient.__index = ~aClient\n\n" sname sname)
     (format "function ~aClient.new(channel)\n" sname)
     "  return setmetatable({ channel = channel }, "
     (format "~aClient)\n" sname)
     "end\n\n"
     (apply string-append (map lua-client-method (append methods (alias-client-methods svc))))
     (apply string-append (map lua-coro-client-stream-class methods))
     (format "--- Coroutine client for ~a.\n" (hash-ref svc 'full-name))
     (format "local ~aClientCoro = {}\n" sname)
     (format "~aClientCoro.__index = ~aClientCoro\n\n" sname sname)
     (format "function ~aClientCoro.new(channel)\n" sname)
     "  return setmetatable({ channel = channelModule.CoroutineChannel.new(channel) }, "
     (format "~aClientCoro)\n" sname)
     "end\n\n"
     (apply string-append (map (lambda (m) (string-append (lua-deprecated m) (lua-coro-client-method m))) (append methods (alias-client-methods svc)))))))

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

(define lua-pb-varint-types '(5 3 13 4 17 18 8 14))
(define lua-pb-fixed '((2 4 "f") (1 8 "d") (7 4 "I4") (15 4 "i4") (6 8 "I8") (16 8 "i8")))

(define (lua-pb-camel s)
  (define parts (string-split s "_"))
  (if (null? parts)
      s
      (apply string-append (car parts)
             (map (lambda (p) (if (string=? p "") "" (string-append (string (char-upcase (string-ref p 0))) (substring p 1))))
                  (cdr parts)))))

(define (lua-pb-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn ""))) jn (lua-pb-camel (hash-ref f 'name))))

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
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(8) d]
         [(14) (format "~a" (enum-default-number model f))]
         [(2) (format "~a" d)]
         [else d])))

(define (lua-pb-default model f)
  (cond [(lua-pb-explicit-literal model f) => (lambda (lit) lit)]
        [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (lua-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         "{}"]
        [(= (hash-ref f 'label) 3) "{}"]
        [(= (hash-ref f 'type) 11) "nil"]
        [(= (hash-ref f 'type) 9) "\"\""]
        [(= (hash-ref f 'type) 12) "\"\""]
        [(= (hash-ref f 'type) 8) "false"]
        [(= (hash-ref f 'type) 14)
         (define entry (lua-pb-resolve model (hash-ref f 'type-name)))
         (format "~a" (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'number))]
        [else "0"]))

(define (lua-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a and 1 or 0)" v)]
    [(17) (format "((bxor(~a << 1, ~a >> 31)) & 0xffffffff)" v v)]
    [(18) (format "(bxor(~a << 1, -(~a >> 63)))" v v)]
    [else v]))

(define (lua-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5 14) (format "((~a & 0xffffffff) >= 0x80000000 and (~a & 0xffffffff) - 0x100000000 or (~a & 0xffffffff))" v v v)]
    [(13 7) (format "(~a & 0xffffffff)" v)]
    [(8) (string-append "(" v " ~= 0)")]
    [(17) (format "(((bxor(~a >> 1, -(~a & 1))) & 0xffffffff) >= 0x80000000 and ((bxor(~a >> 1, -(~a & 1))) & 0xffffffff) - 0x100000000 or ((bxor(~a >> 1, -(~a & 1))) & 0xffffffff))" v v v v v v)]
    [(18) (format "(bxor(~a >> 1, -(~a & 1)))" v v)]
    [else v]))

(define (lua-pb-fixed-fmt f)
  (string-append "<" (third (assv (hash-ref f 'type) lua-pb-fixed))))

(define (lua-pb-wire f)
  (if (= (second (assv (hash-ref f 'type) lua-pb-fixed)) 8) 1 5))

(define (lua-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [else (string-append v " ~= 0")]))

(define (lua-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type lua-pb-varint-types)
         (if proto2?
             (format "~aw:tag(~a, 0) w:varint(~a)\n" indent n (lua-pb-varint-expr f v))
             (format "~aif ~a then w:tag(~a, 0) w:varint(~a) end\n" indent (lua-pb-nonzero f v) n (lua-pb-varint-expr f v)))]
        [(assv type lua-pb-fixed)
         => (lambda (info)
              (if proto2?
                  (string-append indent "w:tag(" (number->string n) ", " (number->string (lua-pb-wire f)) ") w:fixed(" (format "~s" (lua-pb-fixed-fmt f)) ", " v ")\n")
                  (string-append indent "if " v " ~= 0 then w:tag(" (number->string n) ", " (number->string (lua-pb-wire f)) ") w:fixed(" (format "~s" (lua-pb-fixed-fmt f)) ", " v ") end\n")))]
        [(= type 9)
         (if proto2?
             (format "~aw:bytesField(~a, ~a)\n" indent n v)
             (format "~aw:stringField(~a, ~a)\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~aw:bytesField(~a, ~a)\n" indent n v)
             (format "~aif #~a > 0 then w:bytesField(~a, ~a) end\n" indent v n v))]
        [(= type 11) (string-append indent "if " v " ~= nil then w:bytesField(" (number->string n) ", " v ":marshalDc()) end\n")]
        [else (error 'emit-lua-pb-file "unsupported field type ~a (groups)" type)]))

(define (lua-pb-set-expr sib)
  (define v (format "self.~a" (lua-pb-field-name sib)))
  (case (hash-ref sib 'type)
    [(11 10) (string-append v " ~= nil")]
    [(9 12) (string-append "#" v " > 0")]
    [else (lua-pb-nonzero sib v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (lua-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (string-append
       "    if not (" (string-join (map lua-pb-set-expr later) " or ") ") then\n"
       (if (string-suffix? code "\n") code (string-append code "\n"))
       "    end\n")))

(define (lua-pb-encode-field model f)
  (define v (format "self.~a" (lua-pb-field-name f)))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (lua-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (lua-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~aEncode" (lua-pb-entry-flat model entry)))
         (format "    for k, val in pairs(~a) do w:bytesField(~a, ~a(k, val)) end\n" v n helper)]
        [(not (= (hash-ref f 'label) 3)) (lua-pb-encode-singular model f v "    ")]
        [(memv type lua-pb-varint-types)
         (string-append
          (format "    if #~a > 0 then\n      local payload = {}\n" v)
          (format "      for _, x in ipairs(~a) do payload[#payload + 1] = varintBytes(~a) end\n" v (lua-pb-varint-expr f "x"))
          (format "      w:bytesField(~a, table.concat(payload))\n    end\n" n))]
        [(assv type lua-pb-fixed)
         => (lambda (info)
              (string-append
               (format "    if #~a > 0 then\n      local payload = {}\n" v)
               (format "      for _, x in ipairs(~a) do payload[#payload + 1] = string.pack(~s, x) end\n" v (string-append "<" (third info)))
               (format "      w:bytesField(~a, table.concat(payload))\n    end\n" n)))]
        [(= type 9) (format "    for _, x in ipairs(~a) do w:bytesField(~a, x) end\n" v n)]
        [(= type 12) (format "    for _, x in ipairs(~a) do w:bytesField(~a, x) end\n" v n)]
        [(= type 11) (format "    for _, x in ipairs(~a) do w:bytesField(~a, x:marshalDc()) end\n" v n)]
        [else (error 'emit-lua-pb-file "unsupported repeated field type ~a" type)]))

(define (lua-pb-decode-singular model f target src indent)
  (define type (hash-ref f 'type))
  (cond [(memv type lua-pb-varint-types)
         (format "~a~a = ~a\n" indent target (lua-pb-varint-decode f src))]
        [(assv type lua-pb-fixed)
         => (lambda (info)
              (format "~a~a = string.unpack(~s, ~a)\n" indent target (string-append "<" (third info)) src))]
        [(= type 9) (format "~a~a = ~a\n" indent target src)]
        [(= type 12) (format "~a~a = ~a\n" indent target src)]
        [(= type 11)
         (define ref (lua-pb-entry-flat model (lua-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = ~a.new()\n" indent target ref)
          (format "~a~a:unmarshalDc(~a)\n" indent target src))]
        [else (error 'emit-lua-pb-file "unsupported field type ~a" type)]))

(define (lua-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "      self.~a = ~a\n" (lua-pb-field-name sib) (lua-pb-default model sib)))
              (oneof-siblings model f))))

(define (lua-pb-decode-case model f)
  (define v (format "self.~a" (lua-pb-field-name f)))
  (define type (hash-ref f 'type))
  (define head (format "    elseif field.number == ~a then\n" (hash-ref f 'number)))
  (define clearing (lua-pb-oneof-clearing model f))
  (cond [(and (= type 11)
              (eq? (hash-ref (lua-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (lua-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~aDecode" (lua-pb-entry-flat model entry)))
         (string-append head
                        (format "      local kk, vv = ~a(field.bytesValue)\n" helper)
                        (format "      ~a[kk] = vv\n" v))]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        clearing
                        (lua-pb-decode-singular model f v
                                                (cond [(memv type lua-pb-varint-types) "field.varintValue"]
                                                      [(assv type lua-pb-fixed) "field.fixedValue"]
                                                      [else "field.bytesValue"])
                                                "      "))]
        [(memv type lua-pb-varint-types)
         (string-append head
                        "      if field.wire == 2 then\n"
                        "        local sub = Reader.new(field.bytesValue)\n"
                        "        while not sub:done() do\n"
                        "          local raw = sub:varint()\n"
                        (format "          ~a[#~a + 1] = ~a\n" v v (lua-pb-varint-decode f "raw"))
                        "        end\n      else\n"
                        (format "        ~a[#~a + 1] = ~a\n" v v (lua-pb-varint-decode f "field.varintValue"))
                        "      end\n")]
        [(assv type lua-pb-fixed)
         => (lambda (info)
              (string-append head
                             "      if field.wire == 2 then\n"
                             (format "        local payload = field.bytesValue\n")
                             (format "        for i = 1, #payload, ~a do\n" (second info))
                             (format "          ~a[#~a + 1] = string.unpack(~s, payload, i)\n" v v (string-append "<" (third info)))
                             "        end\n      else\n"
                             (format "        ~a[#~a + 1] = string.unpack(~s, field.fixedValue)\n" v v (string-append "<" (third info)))
                             "      end\n"))]
        [(= type 9) (string-append head (format "      ~a[#~a + 1] = field.bytesValue\n" v v))]
        [(= type 12) (string-append head (format "      ~a[#~a + 1] = field.bytesValue\n" v v))]
        [(= type 11)
         (string-append head
                        (format "      local item = ~a.new()\n" (lua-pb-entry-flat model (lua-pb-resolve model (hash-ref f 'type-name))))
                        "      item:unmarshalDc(field.bytesValue)\n"
                        (format "      ~a[#~a + 1] = item\n" v v))]
        [else (error 'emit-lua-pb-file "unsupported repeated field type ~a" type)]))

(define (lua-pb-map-helpers model entry)
  (define msg (hash-ref entry 'msg))
  (define base (lua-pb-entry-flat model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-lua-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (string-append
   (format "~aEncode = function(key, value)\n  local w = Writer.new()\n" base)
   (lua-pb-encode-singular model (hash-set key-f 'label 1) "key" "  ")
   (lua-pb-encode-singular model (hash-set val-f 'label 1) "value" "  ")
   "  return w:toBytes()\nend\n\n"
   (format "~aDecode = function(data)\n" base)
   (format "  local key = ~a\n  local value = ~a\n" (lua-pb-default model (hash-set key-f 'label 1)) (lua-pb-default model (hash-set val-f 'label 1)))
   "  local r = Reader.new(data)\n  while true do\n    local field = r:next()\n    if field == nil then break end\n"
   (format "    if field.number == ~a then\n~a" (hash-ref key-f 'number)
           (lua-pb-decode-singular model (hash-set key-f 'label 1) "key"
                                   (cond [(memv (hash-ref key-f 'type) lua-pb-varint-types) "field.varintValue"]
                                         [(assv (hash-ref key-f 'type) lua-pb-fixed) "field.fixedValue"]
                                         [else "field.bytesValue"]) "      "))
   (format "    elseif field.number == ~a then\n~a" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               (format "      value = ~a.new()\n      value:unmarshalDc(field.bytesValue)\n"
                       (lua-pb-entry-flat model (lua-pb-resolve model (hash-ref val-f 'type-name))))
               (lua-pb-decode-singular model (hash-set val-f 'label 1) "value"
                                       (cond [(memv (hash-ref val-f 'type) lua-pb-varint-types) "field.varintValue"]
                                             [(assv (hash-ref val-f 'type) lua-pb-fixed) "field.fixedValue"]
                                             [else "field.bytesValue"]) "      ")))
   "    end\n  end\n  return key, value\nend\n\n"))

(define lua-pb-support
  (string-append
   "-- @generated by protoc-gen-grpc-dc-lua (Racket metaprogram). DO NOT EDIT.\n"
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
  (define name (lua-pb-flat (hash-ref model 'package) (hash-ref msg 'full-name)))
  (define fields (hash-ref msg 'fields))
  (string-append
   ;; The class local is forward-declared at the top of the file
   ;; (see emit-lua-pb-file/inner): parent classes reference their
   ;; nested classes, which are defined after them.
   (format "~a = {}\n~a.__index = ~a\n\n" name name name)
   (format "function ~a.new(~a)\n  return setmetatable({ ~a }, ~a)\nend\n\n" name
           (string-join (map lua-pb-field-name fields) ", ")
           (let ([parts (map (lambda (f) (format "~a = ~a or ~a" (lua-pb-field-name f) (lua-pb-field-name f) (lua-pb-default model f))) fields)])
             (string-join (append parts (list "unknownFields = \"\"")) ", "))
           name)
   (format "function ~a:marshalDc()\n  local w = Writer.new()\n" name)
   (apply string-append (map (lambda (f) (lua-pb-encode-guard model f (lua-pb-encode-field model f))) fields))
   "  w:raw(self.unknownFields)\n"
   "  return w:toBytes()\nend\n\n"
   (format "function ~a:unmarshalDc(data)\n" name)
   "  self.unknownFields = \"\"\n"
   (apply string-append
          (map (lambda (f) (format "  self.~a = ~a\n" (lua-pb-field-name f) (lua-pb-default model f))) fields))
   "  local r = Reader.new(data)\n  while true do\n    local field = r:next()\n    if field == nil then break end\n"
   "    if false then\n"
   (apply string-append (map (lambda (f) (lua-pb-decode-case model f)) fields))
   "    else\n      self.unknownFields = self.unknownFields .. field.rawValue\n    end\n  end\nend\n\n"
   (apply string-append (map (lambda (n) (lua-pb-message-class model n)) (hash-ref msg 'nested)))))

(define (lua-pb-enum model e)
  (define name (lua-pb-flat (hash-ref model 'package)
                            (if (string=? (hash-ref model 'package) "")
                                (hash-ref e 'name)
                                (format "~a.~a" (hash-ref model 'package) (hash-ref e 'name)))))
  (string-append
   (format "local ~a = { ~a }\n\n" name
           (string-join (map (lambda (v) (format "~a = ~a" (hash-ref v 'name) (hash-ref v 'number)))
                             (hash-ref e 'values)) ", "))))

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
                         (format "local ~aMessages = require(\"~a_messages\")\n"
                                 (lua-pb-flat "" (format "~a_messages" d)) d))
                       dep-modules)))
         (define content
           (string-append
            lua-pb-support
            dep-requires
            (if (string=? dep-requires "") "" "\n")
            (apply string-append
                   (map (lambda (n) (format "local ~a\n" n)) (reverse helper-names)))
            (apply string-append
                   (map (lambda (n) (format "local ~a\n" n)) (append-map all-msg-names messages)))
            (apply string-append (map (lambda (e) (lua-pb-enum file-model e)) enums))
            (apply string-append
                   (map (lambda (m) (lua-pb-message-class file-model m))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            (apply string-append (reverse helpers))
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
           "-- @generated by protoc-gen-grpc-dc-lua (Racket metaprogram). DO NOT EDIT.\n"
         (format "-- source: ~a\n\n" (hash-ref file-model 'name))
         "local channelModule = require(\"grpcdc.channel\")\n"
         "local serverModule = require(\"grpcdc.server\")\n"
         "local statusModule = require(\"grpcdc.status\")\n"
         "local wire = require(\"grpcdc.wire\")\n"
         (format "local messages = require(\"examples.~a_messages\")\n\n" base)
         "local Channel = channelModule.Channel\n"
         "local Server = serverModule.Server\n"
         "local Status = statusModule.Status\n"
         "local EndOfStream = statusModule.EndOfStream\n\n"
         ;; trace=hooks: aliases into the runtime registrar.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "-- Tracing (trace=hooks): register an observer via set_tracer.\n"
              "local set_tracer = statusModule.setTracer\n"
              "local set_trace_filter = statusModule.setTraceFilter\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "statusModule.setTraceFilter(~s)\n" methods)
                    ""))
              "\n")
             "")
         (apply string-append
                (map (lambda (msg)
                       (format "local ~a = messages.~a\n" msg msg))
                     (lua-message-names file-model)))
         "\n"
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
  (define pb-file (emit-lua-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
