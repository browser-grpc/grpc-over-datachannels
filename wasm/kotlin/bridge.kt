@file:OptIn(kotlin.js.ExperimentalJsExport::class)

package grpcdcwasm

import kotlin.js.JsAny
import kotlin.js.JsArray
import kotlin.js.JsName
import kotlin.js.JsString
import kotlin.js.Promise
import kotlin.js.js
import kotlin.js.toJsArray
import kotlin.js.unsafeCast

/** A gRPC status (code + message) carried as an exception. */
class StatusException(val code: Int, message: String) : Exception(message) {
    override fun toString(): String = "${statusName(code)}: $message"

    companion object {
        fun statusName(code: Int): String = when (code) {
            0 -> "OK"
            1 -> "CANCELLED"
            2 -> "UNKNOWN"
            3 -> "INVALID-ARGUMENT"
            4 -> "DEADLINE-EXCEEDED"
            5 -> "NOT-FOUND"
            6 -> "ALREADY-EXISTS"
            7 -> "PERMISSION-DENIED"
            8 -> "RESOURCE-EXHAUSTED"
            9 -> "FAILED-PRECONDITION"
            10 -> "ABORTED"
            11 -> "OUT-OF-RANGE"
            12 -> "UNIMPLEMENTED"
            13 -> "INTERNAL"
            14 -> "UNAVAILABLE"
            15 -> "DATA-LOSS"
            16 -> "UNAUTHENTICATED"
            else -> "CODE_$code"
        }

        /** Convert any throwable to a StatusException (OK for null). */
        fun toStatus(err: Throwable?): StatusException = when (err) {
            null -> StatusException(0, "")
            is StatusException -> err
            else -> StatusException(13, err.message ?: err.toString())
        }
    }
}

/** JavaScript Uint8Array (not in the Kotlin/Wasm stdlib). */
@JsName("Uint8Array")
external class JsUint8Array(length: Int) : JsAny {
    val length: Int
}

private fun jsUint8Get(array: JsUint8Array, index: Int): Int =
    js("array[index]")

private fun jsUint8Set(array: JsUint8Array, index: Int, value: Int) {
    js("array[index] = value")
}

operator fun JsUint8Array.get(index: Int): Int = jsUint8Get(this, index)

operator fun JsUint8Array.set(index: Int, value: Int) {
    jsUint8Set(this, index, value)
}

fun ByteArray.toJsUint8Array(): JsUint8Array {
    val out = JsUint8Array(size)
    for (i in indices) out[i] = this[i].toInt() and 0xff
    return out
}

fun JsUint8Array.toByteArray(): ByteArray = ByteArray(length) { this[it].toByte() }

/** Shape of js/src/wasm_bridge.js createGrpcDcBridge(). */
external interface GrpcdcJsBridge : JsAny {
    fun unary(path: String, payload: JsUint8Array): Promise<JsUint8Array>

    // Options-aware variants (js/src/wasm_bridge.js forwards
    // {metadata, timeout, cancelAfter} to the call).
    fun unary(path: String, payload: JsUint8Array, options: JsAny): Promise<JsUint8Array>

    fun serverStream(
        path: String,
        payload: JsUint8Array,
        onMessage: (JsUint8Array) -> Unit,
        options: JsAny
    ): Promise<JsAny?>
    fun serverStream(
        path: String,
        payload: JsUint8Array,
        onMessage: (JsUint8Array) -> Unit
    ): Promise<JsAny?>

    fun clientStream(
        path: String,
        payloads: JsArray<JsUint8Array>
    ): Promise<JsUint8Array>

    fun bidi(
        path: String,
        payloads: JsArray<JsUint8Array>,
        onMessage: (JsUint8Array) -> Unit
    ): Promise<JsAny?>
}

external interface JsStatusError : JsAny {
    val code: Int
    val message: String
}

/** Pull-based request source handed to incremental server handlers. */
external interface GrpcdcJsServerSource : JsAny {
    fun next(): Promise<JsUint8Array?>
}

/** Shape of js/src/wasm_bridge.js createGrpcDcServerBridge(). */
external interface GrpcdcJsServerBridge : JsAny {
    fun registerUnary(
        path: String,
        handler: (JsUint8Array, JsArray<JsString>) -> Promise<JsUint8Array>
    )

    fun registerServerStream(
        path: String,
        handler: (JsUint8Array, JsArray<JsString>, (JsUint8Array) -> Unit) -> Promise<JsAny?>
    )

    fun registerClientStream(
        path: String,
        handler: (JsArray<JsUint8Array>, JsArray<JsString>) -> Promise<JsUint8Array>
    )

    fun registerBidi(
        path: String,
        handler: (JsArray<JsUint8Array>, JsArray<JsString>, (JsUint8Array) -> Unit) -> Promise<JsAny?>
    )

    fun registerClientStreamInc(
        path: String,
        handler: (GrpcdcJsServerSource, JsArray<JsString>) -> Promise<JsUint8Array>
    )

    fun registerBidiInc(
        path: String,
        handler: (GrpcdcJsServerSource, JsArray<JsString>, (JsUint8Array) -> Unit) -> Promise<JsAny?>
    )

    fun start(serviceName: String)
}

/**
 * Byte-level pull source for incremental server handlers:
 * next() delivers one request payload, or null at end of
 * stream, as it arrives — nothing is collected up front.
 */
class GrpcdcRequestSource internal constructor(private val js: GrpcdcJsServerSource) {
    fun next(onRequest: (ByteArray?) -> Unit, onError: (StatusException) -> Unit) {
        js.next().then(
            { bytes -> onRequest(bytes?.toByteArray()); null },
            { err -> onError(err.toStatusException()); null }
        )
    }
}

private fun jsArrayLength(array: JsArray<*>): Int = js("array.length")

private fun jsArrayString(array: JsArray<JsString>, index: Int): String =
    js("array[index]")

/** Flattened [key, value, ...] bridge pairs to a metadata map. */
fun JsArray<JsString>.toMetadataMap(): Map<String, String> {
    val out = LinkedHashMap<String, String>()
    var i = 0
    while (i + 1 < jsArrayLength(this)) {
        out[jsArrayString(this, i)] = jsArrayString(this, i + 1)
        i += 2
    }
    return out
}

private fun jsErrorObject(code: Int, message: String): JsAny =
    js("({ code: code, message: message })")

private fun StatusException.toJsError(): JsAny =
    jsErrorObject(code, message ?: "")

private fun jsArrayBytes(array: JsArray<JsUint8Array>, index: Int): JsUint8Array =
    js("array[index]")

private fun JsArray<JsUint8Array>.toByteArrayList(): List<ByteArray> {
    val out = ArrayList<ByteArray>()
    var i = 0
    val n = jsArrayLength(this)
    while (i < n) {
        out.add(jsArrayBytes(this, i).toByteArray())
        i++
    }
    return out
}

/**
 * Server bridge runtime for generated Kotlin/Wasm server
 * facades. Handlers are synchronous typed functions; this
 * wrapper adapts them to the JS bridge's Promise/callback
 * shape, converting failures to {code, message} rejections
 * the JS side turns back into StatusError.
 */
class GrpcdcWasmServerBridge(private val js: GrpcdcJsServerBridge) {
    fun unary(path: String, handler: (ByteArray, Map<String, String>) -> ByteArray) {
        js.registerUnary(path) { bytes, pairs ->
            Promise { resolve, reject ->
                try {
                    resolve(handler(bytes.toByteArray(), pairs.toMetadataMap()).toJsUint8Array())
                } catch (e: Throwable) {
                    reject(StatusException.toStatus(e).toJsError())
                }
            }
        }
    }

    fun serverStream(
        path: String,
        handler: (ByteArray, Map<String, String>, (ByteArray) -> Unit) -> Unit
    ) {
        js.registerServerStream(path) { bytes, pairs, onMessage ->
            Promise { resolve, reject ->
                try {
                    handler(bytes.toByteArray(), pairs.toMetadataMap()) { resp ->
                        onMessage(resp.toJsUint8Array())
                    }
                    resolve(null)
                } catch (e: Throwable) {
                    reject(StatusException.toStatus(e).toJsError())
                }
            }
        }
    }

    fun clientStream(
        path: String,
        handler: (List<ByteArray>, Map<String, String>) -> ByteArray
    ) {
        js.registerClientStream(path) { payloads, pairs ->
            Promise { resolve, reject ->
                try {
                    resolve(handler(payloads.toByteArrayList(), pairs.toMetadataMap()).toJsUint8Array())
                } catch (e: Throwable) {
                    reject(StatusException.toStatus(e).toJsError())
                }
            }
        }
    }

    fun bidi(
        path: String,
        handler: (List<ByteArray>, Map<String, String>, (ByteArray) -> Unit) -> Unit
    ) {
        js.registerBidi(path) { payloads, pairs, onMessage ->
            Promise { resolve, reject ->
                try {
                    handler(payloads.toByteArrayList(), pairs.toMetadataMap()) { resp ->
                        onMessage(resp.toJsUint8Array())
                    }
                    resolve(null)
                } catch (e: Throwable) {
                    reject(StatusException.toStatus(e).toJsError())
                }
            }
        }
    }

    fun clientStreamInc(
        path: String,
        handler: (GrpcdcRequestSource, Map<String, String>, (ByteArray) -> Unit, (StatusException) -> Unit) -> Unit
    ) {
        js.registerClientStreamInc(path) { source, pairs ->
            Promise { resolve, reject ->
                handler(
                    GrpcdcRequestSource(source),
                    pairs.toMetadataMap(),
                    { resp -> resolve(resp.toJsUint8Array()) },
                    { st -> reject(st.toJsError()) }
                )
            }
        }
    }

    fun bidiInc(
        path: String,
        handler: (GrpcdcRequestSource, Map<String, String>, (ByteArray) -> Unit, () -> Unit, (StatusException) -> Unit) -> Unit
    ) {
        js.registerBidiInc(path) { source, pairs, onMessage ->
            Promise { resolve, reject ->
                handler(
                    GrpcdcRequestSource(source),
                    pairs.toMetadataMap(),
                    { resp -> onMessage(resp.toJsUint8Array()) },
                    { resolve(null) },
                    { st -> reject(st.toJsError()) }
                )
            }
        }
    }

    fun start(serviceName: String) {
        js.start(serviceName)
    }
}

private fun JsAny.toStatusException(): StatusException {
    val err = unsafeCast<JsStatusError>()
    return StatusException(err.code, err.message)
}

/**
 * Bridge runtime for generated Kotlin/Wasm client facades. It
 * hands protobuf payloads to the page's JS grpc-dc bridge as
 * Uint8Array values; the JS implementation owns the wire.
 */
class GrpcdcWasmBridge(private val js: GrpcdcJsBridge) {
    fun unary(path: String, payload: ByteArray, callback: (Result<ByteArray>) -> Unit) {
        js.unary(path, payload.toJsUint8Array()).then(
            { bytes ->
                callback(Result.success(bytes.toByteArray()))
                null
            },
            { err ->
                callback(Result.failure(err.toStatusException()))
                null
            }
        )
    }

    fun serverStream(
        path: String,
        payload: ByteArray,
        onMessage: (ByteArray) -> Unit,
        onDone: (StatusException?) -> Unit
    ) {
        js.serverStream(path, payload.toJsUint8Array()) { bytes ->
            onMessage(bytes.toByteArray())
        }.then(
            {
                onDone(null)
                null
            },
            { err ->
                onDone(err.toStatusException())
                null
            }
        )
    }

    fun clientStream(
        path: String,
        payloads: List<ByteArray>,
        callback: (Result<ByteArray>) -> Unit
    ) {
        js.clientStream(path, payloads.map { it.toJsUint8Array() }.toJsArray()).then(
            { bytes ->
                callback(Result.success(bytes.toByteArray()))
                null
            },
            { err ->
                callback(Result.failure(err.toStatusException()))
                null
            }
        )
    }

    fun bidi(
        path: String,
        payloads: List<ByteArray>,
        onMessage: (ByteArray) -> Unit,
        onDone: (StatusException?) -> Unit
    ) {
        js.bidi(path, payloads.map { it.toJsUint8Array() }.toJsArray()) { bytes ->
            onMessage(bytes.toByteArray())
        }.then(
            {
                onDone(null)
                null
            },
            { err ->
                onDone(err.toStatusException())
                null
            }
        )
    }
}
