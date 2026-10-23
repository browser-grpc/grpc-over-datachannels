// Native Kotlin/Wasm DataChannel transport: the real grpcdc
// runtime (wasm/kotlin/grpcdc) over the browser's native
// RTCDataChannel, through the SharedArrayBuffer mailbox shared
// with the Swift/C++/Zig/Lua native workers (Int32 [state, len]
// header + payload at byte offset 8). Runs in a Web Worker:
// tryRecv polls the mailbox (the endpoint's inline pump mode
// drives it); recv Atomics.wait()s on it. Outbound frames go
// to the page via postMessage, which owns the RTCDataChannel.

package echo

import grpcdc.EndOfStream
import grpcdc.Transport
import grpcdc.TryRecvResult
import kotlin.js.JsAny
import kotlin.js.JsName
import kotlin.js.js

/** JavaScript Uint8Array (not in the Kotlin/Wasm stdlib). */
@JsName("Uint8Array")
external class JsUint8Array(length: Int) : JsAny {
    val length: Int
}

/** JavaScript Int32Array view over the mailbox buffer. */
@JsName("Int32Array")
external class JsInt32Array(buffer: JsAny) : JsAny

private fun jsU8Get(array: JsUint8Array, index: Int): Int = js("array[index]")

private fun jsU8Set(array: JsUint8Array, index: Int, value: Int) {
    js("array[index] = value")
}

private fun jsI32Load(array: JsInt32Array, index: Int): Int =
    js("Atomics.load(array, index)")

private fun jsI32Store(array: JsInt32Array, index: Int, value: Int) {
    js("Atomics.store(array, index, value)")
}

private fun jsI32Notify(array: JsInt32Array, index: Int) {
    js("Atomics.notify(array, index)")
}

private fun jsI32Wait(array: JsInt32Array, index: Int, value: Int) {
    js("Atomics.wait(array, index, value)")
}

private fun jsI32WaitTimeout(array: JsInt32Array, index: Int, value: Int, timeoutMs: Int) {
    js("Atomics.wait(array, index, value, timeoutMs)")
}

private fun jsSabBytes(sab: JsAny): JsUint8Array =
    js("new Uint8Array(sab)")

private fun jsSendObject(bytes: JsUint8Array): JsAny =
    js("({ t: 'send', bytes: bytes })")

private fun jsPostMessage(message: JsAny) {
    js("postMessage(message)")
}

class DcTransport(sab: JsAny) : Transport {
    private val i32 = JsInt32Array(sab)
    private val sabBytes: JsUint8Array = jsSabBytes(sab)

    override fun send(data: ByteArray) {
        val out = JsUint8Array(data.size)
        for (i in data.indices) jsU8Set(out, i, data[i].toInt() and 0xff)
        jsPostMessage(jsSendObject(out))
    }

    override val hasTryRecv: Boolean
        get() = true

    override fun tryRecv(): TryRecvResult =
        when (jsI32Load(i32, 0)) {
            1 -> {
                val len = jsI32Load(i32, 1)
                val data = ByteArray(len) { jsU8Get(sabBytes, 8 + it).toByte() }
                jsI32Store(i32, 0, 0)
                jsI32Notify(i32, 0)
                TryRecvResult.Message(data)
            }
            2 -> TryRecvResult.Closed
            else -> TryRecvResult.WouldBlock
        }

    override fun recv(): ByteArray {
        while (true) {
            when (val result = tryRecv()) {
                is TryRecvResult.Message -> return result.data
                TryRecvResult.Closed -> throw EndOfStream("data channel closed")
                TryRecvResult.WouldBlock -> jsI32Wait(i32, 0, 0)
            }
        }
    }

    override fun close() {}

    /** Brief mailbox wait for server pump loops (5 ms). */
    fun waitBriefly() {
        if (jsI32Load(i32, 0) == 0) jsI32WaitTimeout(i32, 0, 0, 5)
    }
}
