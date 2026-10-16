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
              "function ~aClient:~a(req, metadata)\n"
              "  local resp = ~a.new()\n"
              "  self.channel:unary(~s, req, resp, metadata)\n"
              "  return resp\n"
              "end\n\n")
             svc name resp path)]
    [(server-streaming)
     (format (string-append
              "function ~aClient:~a(req, metadata)\n"
              "  return ~a~aStream.new(\n"
              "    self.channel:serverStream(~s, req, metadata))\n"
              "end\n\n")
             svc name svc orig-name path)]
    [(client-streaming)
     (format (string-append
              "function ~aClient:~a(reqs, metadata)\n"
              "  local resp = ~a.new()\n"
              "  self.channel:clientStreamCall(~s, reqs, resp, metadata)\n"
              "  return resp\n"
              "end\n\n")
             svc name resp path)]
    [(bidi)
     (format (string-append
              "function ~aClient:~a(reqs, metadata)\n"
              "  return ~a~aStream.new(self.channel:bidi(~s, reqs, metadata))\n"
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
              "function ~aClientCoro:~a(req, metadata)\n"
              "  local resp = ~a.new()\n"
              "  self.channel:unary(~s, req, resp, metadata)\n"
              "  return resp\n"
              "end\n\n")
             svc name resp path)]
    [(server-streaming)
     (format (string-append
              "function ~aClientCoro:~a(req, metadata)\n"
              "  return ~a~aCoroStream.new(\n"
              "    self.channel:serverStream(~s, req, metadata))\n"
              "end\n\n")
             svc name svc orig-name path)]
    [(client-streaming)
     (format (string-append
              "function ~aClientCoro:~a(reqs, metadata)\n"
              "  local resp = ~a.new()\n"
              "  self.channel:clientStreamCall(~s, reqs, resp, metadata)\n"
              "  return resp\n"
              "end\n\n")
             svc name resp path)]
    [(bidi)
     (format (string-append
              "function ~aClientCoro:~a(reqs, metadata)\n"
              "  return ~a~aCoroStream.new(self.channel:bidi(~s, reqs, metadata))\n"
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

(define (emit-lua-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
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
