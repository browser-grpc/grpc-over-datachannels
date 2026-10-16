#lang racket

;;; template-python.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-python.
;;;
;;; Generated code lives beside hand-written message types in a
;;; `<base>_pb` module (classes with marshal_dc()/unmarshal_dc()),
;;; and imports the runtime as grpcdc. Method names keep the proto
;;; spelling (Unary, ServerStream, ...), mirroring the Go stub.

(require "spec.rkt" "desc.rkt")
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
  (if (hash-ref m 'deprecated #f)
      "        \"\"\"Deprecated: marked deprecated in the proto schema.\"\"\"\n        import warnings as _warnings; _warnings.warn(\"deprecated\", DeprecationWarning, stacklevel=2)\n"
      ""))

(define (py-client-method/raw pb m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    def ~a(self, req, metadata=None):\n"
              "~a        return self._channel.unary(~s, req, ~a.~a(), metadata)\n\n")
             name (py-deprecated m) path pb resp)]
    [(server-streaming)
     (format (string-append
              "    def ~a(self, req, metadata=None):\n"
              "~a        stream = self._channel.server_stream(~s, req, metadata)\n"
              "        return _RecvStream(stream, ~a.~a)\n\n")
             name (py-deprecated m) path pb resp)]
    [(client-streaming)
     (format (string-append
              "    def ~a(self, reqs, metadata=None):\n"
              "~a        return self._channel.client_stream(~s, reqs, ~a.~a(), metadata)\n\n")
             name (py-deprecated m) path pb resp)]
    [(bidi)
     (format (string-append
              "    def ~a(self, reqs, metadata=None):\n"
              "~a        stream = self._channel.bidi(~s, reqs, metadata)\n"
              "        return _RecvStream(stream, ~a.~a)\n\n")
             name (py-deprecated m) path pb resp)]))

(define (py-client-method pb m)
  (py-client-method/raw pb m))

(define (py-async-client-method/raw pb m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    async def ~a(self, req, metadata=None):\n"
              "~a        return await self._channel.unary(~s, req, ~a.~a(), metadata)\n\n")
             name (py-deprecated m) path pb resp)]
    [(server-streaming)
     (format (string-append
              "    async def ~a(self, req, metadata=None):\n"
              "~a        stream = await self._channel.server_stream(~s, req, metadata)\n"
              "        return _AsyncRecvStream(stream, ~a.~a)\n\n")
             name (py-deprecated m) path pb resp)]
    [(client-streaming)
     (format (string-append
              "    async def ~a(self, reqs, metadata=None):\n"
              "~a        return await self._channel.client_stream(~s, reqs, ~a.~a(), metadata)\n\n")
             name (py-deprecated m) path pb resp)]
    [(bidi)
     (format (string-append
              "    async def ~a(self, reqs, metadata=None):\n"
              "~a        stream = await self._channel.bidi(~s, reqs, metadata)\n"
              "        return _AsyncRecvStream(stream, ~a.~a)\n\n")
             name (py-deprecated m) path pb resp)]))

(define (py-server-handler pb m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    def _~a_handler(ctx, reqs, sink):\n"
              "        req = reqs.recv_into(~a.~a())\n"
              "        resp = impl.~a(ctx, req)\n"
              "        sink.send(resp.marshal_dc())\n\n")
             name pb req impl-name)]
    [(server-streaming)
     (format (string-append
              "    def _~a_handler(ctx, reqs, sink):\n"
              "        req = reqs.recv_into(~a.~a())\n"
              "        impl.~a(req, _SendStream(ctx, sink))\n\n")
             name pb req impl-name)]
    [(client-streaming)
     (format (string-append
              "    def _~a_handler(ctx, reqs, sink):\n"
              "        stream = _ClientStreamImpl(ctx, reqs, ~a.~a)\n"
              "        impl.~a(stream)\n"
              "        if stream.resp is None:\n"
              "            raise grpcdc.StatusError(grpcdc.CODE_INTERNAL, \"client-streaming handler never called SendAndClose\")\n"
              "        sink.send(stream.resp.marshal_dc())\n\n")
             name pb req impl-name)]
    [(bidi)
     (format (string-append
              "    def _~a_handler(ctx, reqs, sink):\n"
              "        impl.~a(_BidiStream(ctx, reqs, sink, ~a.~a))\n\n")
             name impl-name pb req)]))

(define (py-method-entry m)
  (define kind-name
    (case (hash-ref m 'kind)
      [(unary) "KIND_UNARY"]
      [(server-streaming) "KIND_SERVER_STREAMING"]
      [(client-streaming) "KIND_CLIENT_STREAMING"]
      [(bidi) "KIND_BIDI"]))
  (format "        grpcdc.Method(~s, ~s, grpcdc.~a, _~a_handler),\n"
          (hash-ref m 'name) (hash-ref m 'path) kind-name (hash-ref m 'name)))

(define py-stream-helpers
  (string-append
   "class _RecvStream:\n"
   "    \"\"\"Client receiving stream: recv() raises EOFError at end.\"\"\"\n\n"
   "    def __init__(self, stream, resp_cls):\n"
   "        self._stream = stream\n"
   "        self._resp_cls = resp_cls\n\n"
   "    def recv(self):\n"
   "        return self._stream.recv(self._resp_cls())\n\n"
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
   "        self._sink.send(resp.marshal_dc())\n\n\n"
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
   "        self._sink.send(resp.marshal_dc())\n\n"
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
   "    def __aiter__(self):\n"
   "        return self\n\n"
   "    async def __anext__(self):\n"
   "        try:\n"
   "            return await self.recv()\n"
   "        except EOFError:\n"
   "            raise StopAsyncIteration\n\n\n"))

(define (py-service pb svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "class ~aClient:\n    def __init__(self, channel):\n        self._channel = channel\n\n" sname)
     (apply string-append (map (lambda (m) (py-client-method pb m)) (append methods (alias-client-methods svc))))
     (format "class ~aClientAsync:\n    \"\"\"Asyncio client: wrap a grpcdc.AsyncChannel (a sync Channel is wrapped).\"\"\"\n\n    def __init__(self, channel):\n        if isinstance(channel, grpcdc.AsyncChannel):\n            self._channel = channel\n        else:\n            self._channel = grpcdc.AsyncChannel(channel=channel)\n\n" sname)
     (apply string-append (map (lambda (m) (py-async-client-method/raw pb m)) (append methods (alias-client-methods svc))))
     (format "def register_~a_server(server, impl):\n" (snake (string->symbol sname)))
     (apply string-append (map (lambda (m) (py-server-handler pb m)) (append methods (alias-server-methods svc))))
     (format "    server.register_service(grpcdc.ServiceDesc(\n        ~s,\n        [\n"
             (hash-ref svc 'full-name))
     (apply string-append (map py-method-entry (append methods (alias-server-methods svc))))
     "        ],\n    ))\n")))

(define (emit-python-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define pb (string-append base "_pb"))
  (cons (string-append base "_grpc_dc.py")
        (string-append
         "# @generated by protoc-gen-grpc-dc-python (Racket metaprogram). DO NOT EDIT.\n"
         (format "# source: ~a\n\n" (hash-ref file-model 'name))
         (format "try:\n    from . import ~a\nexcept ImportError:  # direct module load\n    import ~a\n\n" pb pb)
         "import grpcdc\n\n"
         py-stream-helpers
         (apply string-append
                (map (lambda (svc) (py-service pb svc))
                     (hash-ref file-model 'services))))))
