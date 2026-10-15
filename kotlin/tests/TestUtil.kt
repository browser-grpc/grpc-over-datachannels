package tests

import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.charset.StandardCharsets

fun check(condition: Boolean, what: String) {
    if (!condition) {
        throw AssertionError("check failed: $what")
    }
}

fun fromHex(hex: String): ByteArray {
    val out = ByteArray(hex.length / 2)
    for (i in out.indices) {
        out[i] = hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
    }
    return out
}

fun toHex(bytes: ByteArray): String {
    val sb = StringBuilder()
    for (b in bytes) {
        sb.append(String.format("%02x", b.toInt() and 0xff))
    }
    return sb.toString()
}

/** Repository root, located by walking up from the cwd looking for
 * fixtures/echo_descriptor_set.bin. */
fun root(): String {
    val env = System.getenv("GRPC_DC_ROOT")
    if (!env.isNullOrEmpty()) {
        return env
    }
    var dir: File? = File("").absoluteFile
    repeat(8) {
        val current = dir ?: return@repeat
        if (File(current, "fixtures/echo_descriptor_set.bin").exists()) {
            return current.path
        }
        if (File(current, "grpc-over-datachannels/fixtures/echo_descriptor_set.bin").exists()) {
            return File(current, "grpc-over-datachannels").path
        }
        dir = current.parentFile
    }
    return "."
}

fun javaClasspath(root: String): String? {
    val target = File(root, "oracle/java/target")
    val cpFile = File(target, "cp.txt")
    if (!cpFile.exists() || !File(target, "classes").exists()) {
        return null
    }
    return File(target, "classes").path + ":" + cpFile.readText().trim()
}

fun freePort(): Int {
    ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { socket ->
        return socket.localPort
    }
}

/** Read lines from a process stream until one contains needle. */
fun waitReady(reader: BufferedReader, needle: String): Boolean {
    while (true) {
        val line = reader.readLine() ?: return false
        if (line.contains(needle)) {
            return true
        }
    }
}

fun bufferedReader(proc: Process): BufferedReader {
    return BufferedReader(InputStreamReader(proc.errorStream, StandardCharsets.UTF_8))
}

/** Read a stream fully (after the writer has exited). */
fun readAll(stream: java.io.InputStream): String {
    return String(stream.readAllBytes(), StandardCharsets.UTF_8)
}

/** Spawn helper; destroys the process forcibly on kill. */
fun kill(proc: Process) {
    proc.destroyForcibly()
    try {
        proc.waitFor()
    } catch (e: InterruptedException) {
        Thread.currentThread().interrupt()
    }
}
