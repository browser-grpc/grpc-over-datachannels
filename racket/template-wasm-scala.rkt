#lang racket

;;; template-wasm-scala.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-wasm-scala.
;;;
;;; Generated Scala.js facade stubs live beside hand-written
;;; message types (marshalDc/unmarshalDc) and wrap the JS runtime
;;; through grpcdcscalajs (wasm/scalajs/bridge.scala), mirroring
;;; the Kotlin/Wasm facade: Future-based client, sync server trait,
;;; and an incremental StreamServer over the pull-based request
;;; source. Method names keep the proto spelling.

(require "spec.rkt" "desc.rkt")
(provide emit-wasm-scala-file)

(define current-service (make-parameter ""))

(define (wasm-scala-client-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        def ~a(req: ~a): scala.concurrent.Future[~a] = {\n"
              "            bridge.unary(~s, req.marshalDc()).map { bytes =>\n"
              "                val resp = new ~a()\n"
              "                resp.unmarshalDc(bytes)\n"
              "                resp\n"
              "            }\n"
              "        }\n\n")
             name req resp path resp)]
    [(server-streaming)
     (format (string-append
              "        def ~a(req: ~a): ~aServerStreamStream = {\n"
              "            new ~aServerStreamStream(onMessage =>\n"
              "                bridge.serverStream(~s, req.marshalDc(), onMessage))\n"
              "        }\n\n")
             name req svc svc path)]
    [(client-streaming)
     (format (string-append
              "        def ~a(reqs: List[~a]): scala.concurrent.Future[~a] = {\n"
              "            bridge.clientStream(~s, reqs.map(_.marshalDc())).map { bytes =>\n"
              "                val resp = new ~a()\n"
              "                resp.unmarshalDc(bytes)\n"
              "                resp\n"
              "            }\n"
              "        }\n\n")
             name req resp path resp)]
    [(bidi)
     (format (string-append
              "        def ~a(reqs: List[~a]): ~aBidiStream = {\n"
              "            new ~aBidiStream(onMessage =>\n"
              "                bridge.bidi(~s, reqs.map(_.marshalDc()), onMessage))\n"
              "        }\n\n")
             name req svc svc path)]))

(define (wasm-scala-server-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        def ~a(req: ~a, metadata: Map[String, String]): ~a\n" name req resp)]
    [(server-streaming)
     (format "        def ~a(req: ~a, metadata: Map[String, String], sink: ~aServerSink): Unit\n" name req svc)]
    [(client-streaming)
     (format "        def ~a(reqs: List[~a], metadata: Map[String, String]): ~a\n" name req resp)]
    [(bidi)
     (format "        def ~a(reqs: List[~a], metadata: Map[String, String], sink: ~aServerSink): Unit\n" name req svc)]))

(define (wasm-scala-register-method m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        bridge.registerUnary(~s, (payload, metadata) =>\n"
              "            val req = new ~a()\n"
              "            req.unmarshalDc(payload)\n"
              "            impl.~a(req, metadata).marshalDc())\n")
             path req impl-name)]
    [(server-streaming)
     (format (string-append
              "        bridge.registerServerStream(~s, (payload, metadata, onMessage) =>\n"
              "            val req = new ~a()\n"
              "            req.unmarshalDc(payload)\n"
              "            impl.~a(req, metadata, resp => onMessage(resp.marshalDc())))\n")
             path req impl-name)]
    [(client-streaming)
     (format (string-append
              "        bridge.registerClientStream(~s, (payloads, metadata) =>\n"
              "            val reqs = payloads.map { payload =>\n"
              "                val req = new ~a()\n"
              "                req.unmarshalDc(payload)\n"
              "                req\n"
              "            }\n"
              "            impl.~a(reqs, metadata).marshalDc())\n")
             path req impl-name)]
    [(bidi)
     (format (string-append
              "        bridge.registerBidi(~s, (payloads, metadata, onMessage) =>\n"
              "            val reqs = payloads.map { payload =>\n"
              "                val req = new ~a()\n"
              "                req.unmarshalDc(payload)\n"
              "                req\n"
              "            }\n"
              "            impl.~a(reqs, metadata, resp => onMessage(resp.marshalDc())))\n")
             path req impl-name)]))

(define (wasm-scala-stream-iface-method m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (format "        def ~a(source: ~aSource, metadata: Map[String, String]): scala.concurrent.Future[~a]\n"
             name (hash-ref m 'input) resp)]
    [(bidi)
     (format "        def ~a(source: ~aSource, metadata: Map[String, String], sink: ~a => Unit): scala.concurrent.Future[Unit]\n"
             name (hash-ref m 'input) resp)]
    [else ""]))

(define (wasm-scala-stream-register-method m)
  (define name (hash-ref m 'name))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(client-streaming)
     (format (string-append
              "        bridge.registerClientStreamInc(~s, (source, metadata) =>\n"
              "            impl.~a(new ~aSource(source), metadata).map(_.marshalDc()))\n")
             path name (hash-ref m 'input))]
    [(bidi)
     (format (string-append
              "        bridge.registerBidiInc(~s, (source, metadata, onMessage) =>\n"
              "            impl.~a(new ~aSource(source), metadata, resp => onMessage(resp.marshalDc())))\n")
             path name (hash-ref m 'input))]
    [else ""]))

(define (wasm-scala-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (define req (hash-ref (car methods) 'input))
  (define resp (hash-ref (car methods) 'output))
  (parameterize ([current-service sname])
    (string-append
     (format "    /** Client for ~a (browser/Scala.js facade; see file doc). */\n" (hash-ref svc 'full-name))
     (format "    class ~aClient(private val bridge: grpcdcscalajs.GrpcdcScalaJsBridge) {\n" sname)
     (format "        class ~aServerStreamStream(call: (Array[Byte] => Unit) => scala.concurrent.Future[Unit]) extends ~aRecvStream(call)\n\n" sname sname)
     (format "        class ~aBidiStream(call: (Array[Byte] => Unit) => scala.concurrent.Future[Unit]) extends ~aRecvStream(call)\n\n" sname sname)
     (apply string-append (map wasm-scala-client-method (append methods (alias-client-methods svc))))
     "    }\n\n"
     (format "    /** Receiving stream: recv() futures queue in arrival order. */\n")
     (format "    class ~aRecvStream(call: (Array[Byte] => Unit) => scala.concurrent.Future[Unit]) {\n" sname)
     "        private val buffer = scala.collection.mutable.Queue[Array[Byte]]()\n"
     "        private var finished = false\n"
     "        private var failure: Throwable = null\n"
     "        private var waiter: scala.concurrent.Promise[Array[Byte]] = null\n"
     "        call { bytes =>\n"
     "            if (waiter != null) {\n"
     "                val w = waiter\n"
     "                waiter = null\n"
     "                w.success(bytes)\n"
     "            } else {\n"
     "                buffer.enqueue(bytes)\n"
     "            }\n"
     "            ()\n"
     "        }.onComplete {\n"
     "            case scala.util.Success(_) =>\n"
     "                finished = true\n"
     "                if (waiter != null) {\n"
     "                    val w = waiter\n"
     "                    waiter = null\n"
     "                    w.failure(new java.io.EOFException(\"call completed\"))\n"
     "                }\n"
     "            case scala.util.Failure(err) =>\n"
     "                failure = err\n"
     "                if (waiter != null) {\n"
     "                    val w = waiter\n"
     "                    waiter = null\n"
     "                    w.failure(err)\n"
     "                }\n"
     "        }\n\n"
     (format "        def recvBytes(): scala.concurrent.Future[~a] = {\n" resp)
     (format "            val buffered =\n")
     (format "                if (buffer.nonEmpty) scala.concurrent.Future.successful(buffer.dequeue())\n")
     (format "                else if (failure != null) scala.concurrent.Future.failed(failure)\n")
     (format "                else if (finished) scala.concurrent.Future.failed(new java.io.EOFException(\"call completed\"))\n")
     (format "                else {\n")
     (format "                    waiter = scala.concurrent.Promise[Array[Byte]]()\n")
     (format "                    waiter.future\n")
     (format "                }\n")
     (format "            buffered.map { bytes =>\n")
     (format "                val resp = new ~a()\n" resp)
     "                resp.unmarshalDc(bytes)\n"
     "                resp\n"
     "            }\n"
     "        }\n"
     "    }\n\n"
     (format "    /** Streaming response sink for server handlers. */\n")
     (format "    type ~aServerSink = ~a => Unit\n\n" sname resp)
     (format "    /** Service implementation for ~a (browser/Scala.js facade). */\n" (hash-ref svc 'full-name))
     (format "    trait ~aServer {\n" sname)
     (apply string-append (map wasm-scala-server-iface-method methods))
     "    }\n\n"
     (format "    /** Register an implementation of ~a on a server bridge. */\n" (hash-ref svc 'full-name))
     (format "    def register~aServer(bridge: grpcdcscalajs.GrpcdcScalaJsServerBridge, impl: ~aServer): Unit = {\n" sname sname)
     (apply string-append (map wasm-scala-register-method (append methods (alias-server-methods svc))))
     (format "        bridge.start(~s)\n" (hash-ref svc 'full-name))
     "    }\n\n"
     (format "    /** Typed pull source for incremental server handlers. */\n")
     (format "    class ~aSource(private val raw: grpcdcscalajs.GrpcdcRequestSource) {\n" req)
     (format "        def next(): scala.concurrent.Future[Option[~a]] = {\n" req)
     "            raw.next().map(_.map { bytes =>\n"
     (format "                val req = new ~a()\n" req)
     "                req.unmarshalDc(bytes)\n"
     "                req\n"
     "            })\n"
     "        }\n"
     "    }\n\n"
     (format "    /** Incremental service implementation for ~a: requests arrive one at a time. */\n" (hash-ref svc 'full-name))
     (format "    trait ~aStreamServer {\n" sname)
     (apply string-append (map wasm-scala-stream-iface-method methods))
     "    }\n\n"
     (format "    /** Register an incremental implementation; call bridge.start after all registrations. */\n")
     (format "    def register~aStreamServer(bridge: grpcdcscalajs.GrpcdcScalaJsServerBridge, impl: ~aStreamServer): Unit = {\n" sname sname)
     (apply string-append (map wasm-scala-stream-register-method (append methods (alias-server-methods svc))))
     "    }\n")))

(define (emit-wasm-scala-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define obj-name (string-append (pascal (string->symbol base)) "ScalaJsGrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (cons (string-append obj-name ".scala")
        (string-append
         "// @generated by protoc-gen-grpc-dc-wasm-scala (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         (format "package ~a\n\n" pkg)
         "import scala.concurrent.ExecutionContext.Implicits.global\n\n"
         "/** Generated Scala.js facade stubs (wrap the JS runtime). */\n"
         (format "object ~a {\n" obj-name)
         (apply string-append
                (map wasm-scala-service (hash-ref file-model 'services)))
         "}\n")))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "_"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))
