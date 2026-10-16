@file:OptIn(kotlin.js.ExperimentalJsExport::class)

package grpcdcwasm

import kotlin.js.JsAny
import kotlin.js.JsArray
import kotlin.js.JsName
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
