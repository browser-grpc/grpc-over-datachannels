// Scala.js interop bridge over the JS grpc-dc implementation
// (createGrpcDcBridge / createGrpcDcServerBridge in
// js/src/wasm_bridge.js). Typed Scala calls execute in the tested
// JS runtime; this file is only the marshaling layer, mirroring
// wasm/kotlin/bridge.kt for the Kotlin/Wasm facade.
// Scala + Scala.js libraries only; no other dependencies.

package grpcdcscalajs

import grpcdc.{StatusException, Wire}
import scala.concurrent.{ExecutionContext, Future, Promise}
import scala.concurrent.ExecutionContext.Implicits.global
import scala.scalajs.js
import scala.scalajs.js.typedarray.Uint8Array
import scala.util.{Failure, Success}

object ScalaJsBridge {
  def bytesToUint8(bytes: Array[Byte]): Uint8Array = {
    val out = new Uint8Array(bytes.length)
    var i = 0
    while (i < bytes.length) {
      out(i) = (bytes(i) & 0xff).toShort
      i += 1
    }
    out
  }

  def uint8ToBytes(data: Uint8Array): Array[Byte] = {
    val out = new Array[Byte](data.length)
    var i = 0
    while (i < data.length) {
      out(i) = data(i).toByte
      i += 1
    }
    out
  }

  /** Flatten metadata to the bridge's [k, v, k, v, ...] wire shape. */
  def pairsOf(metadata: Map[String, String]): js.Array[String] = {
    val out = js.Array[String]()
    if (metadata != null) {
      for ((k, v) <- metadata) {
        out.push(k)
        out.push(v)
      }
    }
    out
  }

  def metadataOf(pairs: js.Array[String]): Map[String, String] = {
    val out = scala.collection.mutable.LinkedHashMap[String, String]()
    var i = 0
    while (i + 1 < pairs.length) {
      out(pairs(i)) = pairs(i + 1)
      i += 2
    }
    out.toMap
  }

  def statusOf(jsError: js.Any): StatusException = {
    if (jsError == null) {
      return StatusException(Wire.CODE_UNKNOWN, "unknown error")
    }
    val dyn = jsError.asInstanceOf[js.Dynamic]
    val code = dyn.selectDynamic("code")
    val message = dyn.selectDynamic("message")
    val codeInt =
      if (js.isUndefined(code) || code == null) Wire.CODE_UNKNOWN
      else code.asInstanceOf[Int]
    StatusException(codeInt, if (message == null) "" else message.toString)
  }

  def jsErrorOf(status: StatusException): js.Object = {
    js.Dynamic.literal(code = status.code, message = status.getMessage)
  }

  /** Settle handlers on a JS Promise (`.then` needs Dynamic in Scala). */
  def settle[T](promise: js.Promise[T], onOk: T => Unit, onErr: js.Any => Unit): Unit = {
    promise.asInstanceOf[js.Dynamic].applyDynamic("then")(
      ((v: T) => onOk(v)): js.Function1[T, Unit],
      ((e: js.Any) => onErr(e)): js.Function1[js.Any, Unit])
    ()
  }

  /** Call a method on a JS bridge object via Dynamic. */
  def call(obj: js.Dynamic, method: String, args: js.Any*): js.Dynamic = {
    obj.applyDynamic(method)(args*)
  }

  /** Success/failure as one promise, settled by the JS bridge. */
  def futureOf[T](register: (T => Unit, js.Any => Unit) => Unit): Future[T] = {
    val promise = Promise[T]()
    register(
      value => { promise.trySuccess(value); () },
      err => { promise.tryFailure(statusOf(err)); () }
    )
    promise.future
  }

  implicit class PromiseOps[T](private val future: Future[T]) extends AnyVal {
    def toJSPromise: js.Promise[T] = {
      import scala.concurrent.ExecutionContext.Implicits.global
      val result = new js.Promise[T]((resolve, reject) => {
        future.onComplete {
          case Success(value) => resolve(value)
          case Failure(err) =>
            err match {
              case status: StatusException => reject(jsErrorOf(status))
              case other => reject(other.getMessage)
            }
        }
      })
      result
    }
  }
}

/** Client bridge: wraps createGrpcDcBridge's return value. */
class GrpcdcScalaJsBridge(private val jsBridge: js.Dynamic) {
  // Options-aware unary (js/src/wasm_bridge.js forwards
  // {metadata, timeout} to the call).
  def unaryWithOptions(path: String, payload: Array[Byte], metadata: Map[String, String], timeoutMs: Int): Future[Array[Byte]] = {
    val opts = js.Dynamic.literal()
    if (metadata.nonEmpty) {
      val md = js.Dynamic.literal()
      for ((k, v) <- metadata) md.updateDynamic(k)(v)
      opts.updateDynamic("metadata")(md)
    }
    if (timeoutMs > 0) opts.updateDynamic("timeout")(timeoutMs)
    ScalaJsBridge.futureOf[Array[Byte]] { (resolve, reject) =>
      ScalaJsBridge.settle(
        ScalaJsBridge.call(jsBridge, "unary", path, ScalaJsBridge.bytesToUint8(payload), opts).asInstanceOf[js.Promise[Uint8Array]],
        (value: Uint8Array) => resolve(ScalaJsBridge.uint8ToBytes(value)),
        (err: js.Any) => reject(err))
      ()
    }
  }

  // Server-streaming call that aborts after cancelAfter
  // responses (the bridge breaks the iteration, tearing the
  // call down); the future completes normally.
  def serverStreamCancelAfter(path: String, payload: Array[Byte], cancelAfter: Int, onMessage: Array[Byte] => Unit): Future[Unit] = {
    ScalaJsBridge.futureOf[Unit] { (resolve, reject) =>
      val onPayload: js.Function1[Uint8Array, Unit] =
        bytes => onMessage(ScalaJsBridge.uint8ToBytes(bytes))
      val opts = js.Dynamic.literal(cancelAfter = cancelAfter)
      ScalaJsBridge.settle(
        ScalaJsBridge.call(jsBridge, "serverStream", path, ScalaJsBridge.bytesToUint8(payload), onPayload, opts).asInstanceOf[js.Promise[js.Any]],
        (_: js.Any) => resolve(()),
        (err: js.Any) => reject(err))
      ()
    }
  }

  def unary(path: String, payload: Array[Byte]): Future[Array[Byte]] = {
    ScalaJsBridge.futureOf[Array[Byte]] { (resolve, reject) =>
      ScalaJsBridge.settle(
        ScalaJsBridge.call(jsBridge, "unary", path, ScalaJsBridge.bytesToUint8(payload)).asInstanceOf[js.Promise[Uint8Array]],
        (value: Uint8Array) => resolve(ScalaJsBridge.uint8ToBytes(value)),
        (err: js.Any) => reject(err))
      ()
    }
  }

  def serverStream(path: String, payload: Array[Byte], onMessage: Array[Byte] => Unit): Future[Unit] = {
    ScalaJsBridge.futureOf[Unit] { (resolve, reject) =>
      val onPayload: js.Function1[Uint8Array, Unit] =
        bytes => onMessage(ScalaJsBridge.uint8ToBytes(bytes))
      ScalaJsBridge.settle(
        ScalaJsBridge.call(jsBridge, "serverStream", path, ScalaJsBridge.bytesToUint8(payload), onPayload).asInstanceOf[js.Promise[js.Any]],
        (_: js.Any) => resolve(()),
        (err: js.Any) => reject(err))
      ()
    }
  }

  def clientStream(path: String, payloads: List[Array[Byte]]): Future[Array[Byte]] = {
    ScalaJsBridge.futureOf[Array[Byte]] { (resolve, reject) =>
      val arr = js.Array[Uint8Array]()
      for (p <- payloads) arr.push(ScalaJsBridge.bytesToUint8(p))
      ScalaJsBridge.settle(
        ScalaJsBridge.call(jsBridge, "clientStream", path, arr).asInstanceOf[js.Promise[Uint8Array]],
        (value: Uint8Array) => resolve(ScalaJsBridge.uint8ToBytes(value)),
        (err: js.Any) => reject(err))
      ()
    }
  }

  def bidi(path: String, payloads: List[Array[Byte]], onMessage: Array[Byte] => Unit): Future[Unit] = {
    ScalaJsBridge.futureOf[Unit] { (resolve, reject) =>
      val arr = js.Array[Uint8Array]()
      for (p <- payloads) arr.push(ScalaJsBridge.bytesToUint8(p))
      val onPayload: js.Function1[Uint8Array, Unit] =
        bytes => onMessage(ScalaJsBridge.uint8ToBytes(bytes))
      ScalaJsBridge.settle(
        ScalaJsBridge.call(jsBridge, "bidi", path, arr, onPayload).asInstanceOf[js.Promise[js.Any]],
        (_: js.Any) => resolve(()),
        (err: js.Any) => reject(err))
      ()
    }
  }
}

/** Pull-based request source handed to incremental server handlers. */
class GrpcdcRequestSource(private val jsSource: js.Dynamic) {
  /** Next request payload, or None at end of stream. */
  def next(): Future[Option[Array[Byte]]] = {
    ScalaJsBridge.futureOf[Option[Array[Byte]]] { (resolve, reject) =>
      ScalaJsBridge.settle(
        ScalaJsBridge.call(jsSource, "next").asInstanceOf[js.Promise[Uint8Array]],
        (value: Uint8Array) => resolve(if (value == null) None else Some(ScalaJsBridge.uint8ToBytes(value))),
        (err: js.Any) => reject(err))
      ()
    }
  }
}

/** Server bridge: wraps createGrpcDcServerBridge's return value. */
class GrpcdcScalaJsServerBridge(private val jsBridge: js.Dynamic) {
  def registerUnary(path: String, handler: (Array[Byte], Map[String, String]) => Array[Byte]): Unit = {
    val fn: js.Function2[Uint8Array, js.Array[String], js.Promise[Uint8Array]] =
      (payload, pairs) => {
        try {
          js.Promise.resolve[Uint8Array](
            ScalaJsBridge.bytesToUint8(handler(ScalaJsBridge.uint8ToBytes(payload), ScalaJsBridge.metadataOf(pairs))))
        } catch {
          case status: StatusException => js.Promise.reject(ScalaJsBridge.jsErrorOf(status)).asInstanceOf[js.Promise[Uint8Array]]
          case other: Throwable => js.Promise.reject(other.getMessage).asInstanceOf[js.Promise[Uint8Array]]
        }
      }
    ScalaJsBridge.call(jsBridge, "registerUnary", path, fn)
    ()
  }

  def registerServerStream(path: String, handler: (Array[Byte], Map[String, String], Array[Byte] => Unit) => Unit): Unit = {
    val fn: js.Function3[Uint8Array, js.Array[String], js.Function1[Uint8Array, Unit], js.Promise[js.Any]] =
      (payload, pairs, onMessage) => {
        try {
          handler(
            ScalaJsBridge.uint8ToBytes(payload),
            ScalaJsBridge.metadataOf(pairs),
            resp => onMessage(ScalaJsBridge.bytesToUint8(resp))
          )
          js.Promise.resolve[js.Any](())
        } catch {
          case status: StatusException => js.Promise.reject(ScalaJsBridge.jsErrorOf(status)).asInstanceOf[js.Promise[js.Any]]
          case other: Throwable => js.Promise.reject(other.getMessage).asInstanceOf[js.Promise[js.Any]]
        }
      }
    ScalaJsBridge.call(jsBridge, "registerServerStream", path, fn)
    ()
  }

  def registerClientStream(path: String, handler: (List[Array[Byte]], Map[String, String]) => Array[Byte]): Unit = {
    val fn: js.Function2[js.Array[Uint8Array], js.Array[String], js.Promise[Uint8Array]] =
      (payloads, pairs) => {
        try {
          val list = List.tabulate(payloads.length)(i => ScalaJsBridge.uint8ToBytes(payloads(i)))
          js.Promise.resolve[Uint8Array](
            ScalaJsBridge.bytesToUint8(handler(list, ScalaJsBridge.metadataOf(pairs))))
        } catch {
          case status: StatusException => js.Promise.reject(ScalaJsBridge.jsErrorOf(status)).asInstanceOf[js.Promise[Uint8Array]]
          case other: Throwable => js.Promise.reject(other.getMessage).asInstanceOf[js.Promise[Uint8Array]]
        }
      }
    ScalaJsBridge.call(jsBridge, "registerClientStream", path, fn)
    ()
  }

  def registerBidi(path: String, handler: (List[Array[Byte]], Map[String, String], Array[Byte] => Unit) => Unit): Unit = {
    val fn: js.Function3[js.Array[Uint8Array], js.Array[String], js.Function1[Uint8Array, Unit], js.Promise[js.Any]] =
      (payloads, pairs, onMessage) => {
        try {
          val list = List.tabulate(payloads.length)(i => ScalaJsBridge.uint8ToBytes(payloads(i)))
          handler(
            list,
            ScalaJsBridge.metadataOf(pairs),
            resp => onMessage(ScalaJsBridge.bytesToUint8(resp))
          )
          js.Promise.resolve[js.Any](())
        } catch {
          case status: StatusException => js.Promise.reject(ScalaJsBridge.jsErrorOf(status)).asInstanceOf[js.Promise[js.Any]]
          case other: Throwable => js.Promise.reject(other.getMessage).asInstanceOf[js.Promise[js.Any]]
        }
      }
    ScalaJsBridge.call(jsBridge, "registerBidi", path, fn)
    ()
  }

  def registerClientStreamInc(path: String, handler: (GrpcdcRequestSource, Map[String, String]) => Future[Array[Byte]]): Unit = {
    val fn: js.Function2[js.Dynamic, js.Array[String], js.Promise[Uint8Array]] =
      (source, pairs) => {
        import ScalaJsBridge.PromiseOps
        handler(new GrpcdcRequestSource(source), ScalaJsBridge.metadataOf(pairs))
          .map(ScalaJsBridge.bytesToUint8)
          .toJSPromise
          .asInstanceOf[js.Promise[Uint8Array]]
      }
    ScalaJsBridge.call(jsBridge, "registerClientStreamInc", path, fn)
    ()
  }

  def registerBidiInc(path: String, handler: (GrpcdcRequestSource, Map[String, String], Array[Byte] => Unit) => Future[Unit]): Unit = {
    val fn: js.Function3[js.Dynamic, js.Array[String], js.Function1[Uint8Array, Unit], js.Promise[js.Any]] =
      (source, pairs, onMessage) => {
        import ScalaJsBridge.PromiseOps
        handler(
          new GrpcdcRequestSource(source),
          ScalaJsBridge.metadataOf(pairs),
          resp => onMessage(ScalaJsBridge.bytesToUint8(resp))
        ).toJSPromise.asInstanceOf[js.Promise[js.Any]]
      }
    ScalaJsBridge.call(jsBridge, "registerBidiInc", path, fn)
    ()
  }

  def start(serviceName: String): Unit = {
    ScalaJsBridge.call(jsBridge, "start", serviceName)
    ()
  }
}
