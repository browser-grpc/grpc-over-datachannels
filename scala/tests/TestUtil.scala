package tests

import java.io.{BufferedReader, File, InputStreamReader}
import java.net.{InetAddress, ServerSocket}
import java.nio.charset.StandardCharsets

def check(condition: Boolean, what: String): Unit = {
  if (!condition) {
    throw new AssertionError(s"check failed: $what")
  }
}

def fromHex(hex: String): Array[Byte] = {
  val out = new Array[Byte](hex.length / 2)
  for (i <- out.indices) {
    out(i) = Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16).toByte
  }
  out
}

def toHex(bytes: Array[Byte]): String = {
  val sb = new StringBuilder
  for (b <- bytes) {
    sb.append(String.format("%02x", b.toInt & 0xff))
  }
  sb.toString
}

/** Repository root, located by walking up from the cwd looking for
 * fixtures/echo_descriptor_set.bin. */
def root(): String = {
  val env = System.getenv("GRPC_DC_ROOT")
  if (env != null && env.nonEmpty) {
    return env
  }
  var dir: File = new File("").getAbsoluteFile
  for (_ <- 0 until 8) {
    if (dir != null) {
      if (new File(dir, "fixtures/echo_descriptor_set.bin").exists()) {
        return dir.getPath
      }
      if (new File(dir, "grpc-over-datachannels/fixtures/echo_descriptor_set.bin").exists()) {
        return new File(dir, "grpc-over-datachannels").getPath
      }
      dir = dir.getParentFile
    }
  }
  "."
}

def javaClasspath(root: String): String = {
  val target = new File(root, "oracle/java/target")
  val cpFile = new File(target, "cp.txt")
  if (!cpFile.exists() || !new File(target, "classes").exists()) {
    return null
  }
  new File(target, "classes").getPath + ":" + scala.io.Source.fromFile(cpFile).mkString.trim
}

def freePort(): Int = {
  val socket = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
  try {
    socket.getLocalPort
  } finally {
    socket.close()
  }
}

/** Read lines from a process stream until one contains needle. */
def waitReady(reader: BufferedReader, needle: String): Boolean = {
  var line = reader.readLine()
  while (line != null) {
    if (line.contains(needle)) {
      return true
    }
    line = reader.readLine()
  }
  false
}

def bufferedReader(proc: Process): BufferedReader = {
  new BufferedReader(new InputStreamReader(proc.getErrorStream, StandardCharsets.UTF_8))
}

/** Read a stream fully (after the writer has exited). */
def readAll(stream: java.io.InputStream): String = {
  new String(stream.readAllBytes(), StandardCharsets.UTF_8)
}

/** Spawn helper; destroys the process forcibly on kill. */
def kill(proc: Process): Unit = {
  proc.destroyForcibly()
  try {
    proc.waitFor()
  } catch {
    case e: InterruptedException => Thread.currentThread().interrupt()
  }
}
