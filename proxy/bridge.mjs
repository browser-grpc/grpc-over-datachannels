// TCP <-> DataChannel proxy: translates official gRPC (HTTP/2 over
// TCP, as spoken by grpc-java/grpc-go) to the grpc-dc frame wire
// (HEADERS/DATA/TRAILERS over one DataChannel), in both directions:
//
//   http2-to-dc : HTTP/2 server; each HTTP/2 stream becomes a grpc-dc
//                 stream on the given endpoint (we are the client).
//   dc-to-http2 : grpc-dc server endpoint; each call becomes an HTTP/2
//                 client stream to the official gRPC server.
//
// Translation (per message): strip/add the 5-byte gRPC length-prefix
// (1-byte compression flag + 4-byte length); :path <-> HEADERS path;
// grpc-status/grpc-message <-> TRAILERS status.
//
// Compression lives entirely in this proxy, never on the grpc-dc wire:
// compressed messages from the official side are decompressed here and
// forwarded flag-0; toward the official side we advertise only
// encodings we decode (gzip) and always send identity ourselves. A
// peer that insists on an unsupported encoding gets UNIMPLEMENTED.
// Node stdlib only (node:http2 does HTTP/2 framing, HPACK, flow ctl).

import http2 from "node:http2";
import { spawn } from "node:child_process";
import { gunzipSync, gzipSync } from "node:zlib";
import { Endpoint, FrameType, StatusCode, StatusError, encodeFrame } from "../js/index.js";
import { headersFrame, statusFrame } from "../js/src/codec.js";

const { HTTP2_HEADER_PATH, HTTP2_HEADER_STATUS, HTTP2_HEADER_CONTENT_TYPE } = http2.constants;

// ---------------------------------------------------------------------------
// gRPC length-prefixed message framing
// ---------------------------------------------------------------------------

const MAX_MESSAGE = 16 * 1024 * 1024; // mirror the grpc-dc DATA cap

function decompress(flag, payload, encoding) {
  if (flag === 0) return payload;
  // A set compressed flag means this message is compressed with
  // the stream's encoding; grpc-java's per-message compression
  // (client_compressed_streaming) sets the flag without a
  // grpc-encoding header, and stock servers decompress it with
  // their registered gzip codec -- mirror that. A header
  // declaring a non-gzip encoding stays an error.
  if (encoding !== "gzip" && encoding !== "identity") {
    throw StatusError.unimplemented(`unsupported grpc-encoding: ${encoding}`);
  }
  const out = gunzipSync(payload, { maxOutputLength: MAX_MESSAGE });
  return out;
}

export class LpmParser {
  #buffer = Buffer.alloc(0);

  /**
   * Feed bytes; returns complete message payloads, decompressed per
   * the stream's grpc-encoding. Throws StatusError UNIMPLEMENTED on
   * unsupported encodings.
   */
  constructor(encoding = "identity") {
    this.encoding = encoding;
    this.sawCompressed = false;
  }

  push(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, chunk]);
    const out = [];
    for (;;) {
      if (this.#buffer.length < 5) return out;
      const flag = this.#buffer[0];
      const len = this.#buffer.readUInt32BE(1);
      if (this.#buffer.length < 5 + len) return out;
      if (flag === 1) this.sawCompressed = true;
      out.push(decompress(flag, this.#buffer.subarray(5, 5 + len), this.encoding));
      this.#buffer = this.#buffer.subarray(5 + len);
    }
  }
}

export function lpm(payload) {
  const out = Buffer.alloc(5 + payload.length);
  out.writeUInt32BE(payload.length, 1);
  Buffer.from(payload).copy(out, 5);
  return out;
}

// grpc-message percent-encoding (gRPC HTTP/2 spec): printable ASCII
// except '%' passes through; everything else becomes %XX.
export function grpcMessageEncode(message) {
  let out = "";
  for (const byte of Buffer.from(message, "utf8")) {
    if (byte >= 0x20 && byte <= 0x7e && byte !== 0x25) out += String.fromCharCode(byte);
    else out += "%" + byte.toString(16).toUpperCase().padStart(2, "0");
  }
  return out;
}

export function grpcMessageDecode(text) {
  const bytes = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "%" && i + 2 < text.length + 0 && /^[0-9A-Fa-f]{2}$/.test(text.slice(i + 1, i + 3))) {
      bytes.push(parseInt(text.slice(i + 1, i + 3), 16));
      i += 2;
    } else {
      bytes.push(text.charCodeAt(i) & 0xff);
    }
  }
  return Buffer.from(bytes).toString("utf8");
}

// ---------------------------------------------------------------------------
// Direction 1: HTTP/2 server -> grpc-dc client endpoint
// ---------------------------------------------------------------------------

function metadataFromHttp2(headers) {
  const metadata = {};
  for (const [key, value] of Object.entries(headers)) {
    if (key.startsWith(":")) continue;
    // Compression is terminated here (payloads cross the
    // DataChannel side uncompressed), but the declared
    // grpc-encoding is forwarded as informational metadata so
    // the receiving side can observe that compression was in
    // play (the interop expect_compressed check grades this).
    if (["content-type", "te", "user-agent", "grpc-accept-encoding"].includes(key)) {
      continue;
    }
    // -bin values are base64 on the HTTP/2 wire (gRPC spec)
    // and base64 on the grpc-dc wire too, so they pass through.
    if (typeof value === "string") metadata[key] = value;
  }
  return metadata;
}

// grpc-dc metadata -> HTTP/2 header entries (response side):
// transport-owned keys stay out; -bin values are base64 in
// both domains and pass through unchanged. A server-declared
// grpc-encoding: gzip is forwarded AND makes serveHttp2ToDc
// gzip the response messages (compression terminates here,
// at the HTTP/2 hop, by the server's declaration).
function metadataToHttp2(metadata) {
  const headers = {};
  for (const [key, value] of Object.entries(metadata ?? {})) {
    if (key.startsWith(":") || typeof value !== "string") continue;
    if (["content-type", "grpc-status", "grpc-message", "grpc-accept-encoding"].includes(key)) {
      continue;
    }
    headers[key] = value;
  }
  return headers;
}

export function serveHttp2ToDc({ port, endpoint, host = "127.0.0.1", tls = null }) {
  // HTTP/2 over TCP: plaintext h2c, or TLS (ALPN h2) when
  // tls {cert, key} is given — the full official transport set.
  const server = tls
    ? http2.createSecureServer({ ...tls, allowHTTP1: false })
    : http2.createServer();
  server.on("stream", (stream, headers) => {
    const path = headers[HTTP2_HEADER_PATH];
    const [id, input] = endpoint.openStream();
    let responded = false;
    let compressOut = false;
    let trailersToSend = null;
    // Node only flushes trailers for streams responded with
    // waitForTrailers; they go out on 'wantTrailers' as the stream ends.
    stream.on("wantTrailers", () => {
      if (trailersToSend) stream.sendTrailers(trailersToSend);
    });
    const respond = (serverMetadata = {}) => {
      if (!responded) {
        responded = true;
        // A grpc-encoding: gzip declaration in the server's
        // initial metadata turns on response compression here.
        compressOut = serverMetadata["grpc-encoding"] === "gzip";
        stream.respond(
          {
            [HTTP2_HEADER_STATUS]: 200,
            [HTTP2_HEADER_CONTENT_TYPE]: "application/grpc",
            // We decode gzip (and identity) inbound; the DataChannel side
            // of this stream is always uncompressed.
            "grpc-accept-encoding": "gzip,identity",
            // The grpc-dc server's initial metadata rides along.
            ...metadataToHttp2(serverMetadata),
          },
          { waitForTrailers: true },
        );
      }
    };
    const finish = (status) => {
      respond();
      trailersToSend = { "grpc-status": String(status.code) };
      const wireMessage = status.statusMessage ?? status.message;
      if (wireMessage) {
        trailersToSend["grpc-message"] = grpcMessageEncode(wireMessage);
      }
      // Trailing metadata from the grpc-dc status frame.
      Object.assign(trailersToSend, metadataToHttp2(status.trailers ?? {}));
      try {
        stream.end();
      } catch {
        /* stream already closed */
      }
      endpoint.closeStream(id);
    };

    const parser = new LpmParser(headers["grpc-encoding"] ?? "identity");
    // The DataChannel HEADERS frame is held until the first
    // request message (or end of stream): per-message
    // compression (grpc-java's client_compressed_streaming)
    // declares no grpc-encoding header, so whether the stream
    // arrived compressed is only observable from the first
    // message's flag -- surface it as metadata so the server
    // can run the expect_compressed check.
    const requestMetadata = metadataFromHttp2(headers);
    let headersSent = false;
    const pendingData = [];
    const sendHeaders = () => {
      if (headersSent) return;
      headersSent = true;
      if (parser.sawCompressed && !("grpc-encoding" in requestMetadata)) {
        requestMetadata["grpc-encoding"] = "gzip";
      }
      endpoint
        .sendFrame(headersFrame(id, path, requestMetadata))
        .catch(() => {});
      for (const payload of pendingData) {
        endpoint.sendFrame(encodeFrame(FrameType.DATA, id, payload)).catch(() => {});
      }
      pendingData.length = 0;
    };
    stream.on("data", (chunk) => {
      let payloads;
      try {
        payloads = parser.push(chunk);
      } catch (e) {
        finish(StatusError.unimplemented(e.message));
        return;
      }
      for (const payload of payloads) {
        if (headersSent) {
          endpoint.sendFrame(encodeFrame(FrameType.DATA, id, payload)).catch(() => {});
        } else {
          pendingData.push(payload);
          sendHeaders();
        }
      }
    });
    stream.on("end", () => {
      sendHeaders();
      endpoint.sendFrame(encodeFrame(FrameType.HALF_CLOSE, id)).catch(() => {});
    });
    stream.on("error", () => endpoint.closeStream(id));

    (async () => {
      try {
        for await (const event of input) {
          if (event.kind === "headers") {
            respond(event.headers?.metadata ?? {});
          } else if (event.kind === "data") {
            respond();
            if (compressOut) {
              const packed = gzipSync(event.payload);
              const framed = Buffer.alloc(5 + packed.length);
              framed[0] = 1;
              framed.writeUInt32BE(packed.length, 1);
              packed.copy(framed, 5);
              stream.write(framed);
            } else {
              stream.write(lpm(event.payload));
            }
          } else if (event.kind === "trailers" || event.kind === "rst") {
            finish(event.status);
            return;
          }
        }
        finish(new StatusError(StatusCode.UNAVAILABLE, "data channel closed"));
      } catch (e) {
        finish(e instanceof StatusError ? e : StatusError.internal(String(e?.message ?? e)));
      }
    })();
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => resolve(server));
  });
}

// ---------------------------------------------------------------------------
// Direction 2: grpc-dc server endpoint -> HTTP/2 client
// ---------------------------------------------------------------------------

export function serveDcToHttp2({ grpcAuthority, endpoint }) {
  const session = http2.connect(`http://${grpcAuthority}`);
  endpoint.dispatcher = async (path, headers, input, sink) => {
    const requestHeaders = {
      ":path": path,
      ":method": "POST",
      ":scheme": "http",
      ":authority": grpcAuthority,
      "content-type": "application/grpc",
      // The official server may answer gzip-compressed; we decompress
      // here and forward flag-0 onto the DataChannel.
      "grpc-accept-encoding": "gzip,identity",
      te: "trailers",
    };
    for (const [key, value] of Object.entries(headers.metadata ?? {})) {
      if (key === "grpc-encoding" || key === "grpc-accept-encoding") continue;
      if (!(key in requestHeaders)) requestHeaders[key] = value;
    }
    const stream = session.request(requestHeaders);

    let grpcStatus = null;
    let grpcMessage = "";
    let initialMeta = {};
    let trailerMeta = {};
    let headersSent = false;
    const sendHeadersOnce = async () => {
      if (!headersSent) {
        headersSent = true;
        await sink.sendHeaders(initialMeta);
      }
    };
    const parser = new LpmParser();
    const noteTrailers = (t) => {
      if (t["grpc-status"] !== undefined) {
        grpcStatus = Number(t["grpc-status"]);
        grpcMessage = grpcMessageDecode(t["grpc-message"] ?? "");
      }
      trailerMeta = metadataFromHttp2(t);
      delete trailerMeta["grpc-status"];
      delete trailerMeta["grpc-message"];
    };
    stream.on("response", (h) => {
      // Response messages may be compressed with this encoding.
      parser.encoding = h["grpc-encoding"] ?? "identity";
      initialMeta = metadataFromHttp2(h);
      delete initialMeta["grpc-status"];
      delete initialMeta["grpc-message"];
      noteTrailers(h);
    });
    stream.on("trailers", noteTrailers);
    // Response payloads forward in order (headers flush first);
    // outDone waits for the chain so no DATA lands after the
    // terminal trailers the endpoint sends on our return.
    let chain = Promise.resolve();
    const outDone = new Promise((resolve, reject) => {
      stream.on("data", (chunk) => {
        let payloads;
        try {
          payloads = parser.push(chunk);
        } catch (e) {
          reject(e);
          return;
        }
        for (const payload of payloads) {
          chain = chain.then(async () => {
            await sendHeadersOnce();
            await sink.sendData(payload);
          });
        }
      });
      stream.on("end", () => chain.then(resolve, reject));
      stream.on("error", reject);
    });

    const inDone = (async () => {
      for await (const event of input) {
        if (event.kind === "data") {
          stream.write(lpm(event.payload));
        } else if (event.kind === "half-close") {
          stream.end();
          return;
        } else if (event.kind === "trailers" || event.kind === "rst") {
          throw event.status;
        }
      }
      stream.end();
    })();

    await Promise.all([inDone, outDone]);
    if (grpcStatus === null) {
      throw StatusError.internal("official server sent no grpc-status");
    }
    if (grpcStatus !== 0) {
      const status = new StatusError(grpcStatus, grpcMessage);
      status.trailers = trailerMeta;
      throw status;
    }
    await sendHeadersOnce();
    // The endpoint merges returned trailers into the OK status.
    return { trailers: trailerMeta };
  };
  return session;
}

// ---------------------------------------------------------------------------
// Framed stdio channel (4-byte length prefix per DataChannel message),
// the same bridge the interop tests use.
// ---------------------------------------------------------------------------

export class StdioChannel {
  #buffer = Buffer.alloc(0);
  #listeners = new Map();
  readyState = "open";
  bufferedAmount = 0;
  binaryType = "arraybuffer";

  constructor(input, output) {
    this.output = output;
    input.on("data", (chunk) => {
      this.#buffer = Buffer.concat([this.#buffer, chunk]);
      for (;;) {
        if (this.#buffer.length < 4) return;
        const len = this.#buffer.readUInt32BE(0);
        if (this.#buffer.length < 4 + len) return;
        const frame = this.#buffer.subarray(4, 4 + len);
        this.#buffer = this.#buffer.subarray(4 + len);
        this.#emit("message", { data: frame });
      }
    });
  }

  addEventListener(type, fn) {
    if (!this.#listeners.has(type)) this.#listeners.set(type, []);
    this.#listeners.get(type).push(fn);
  }

  removeEventListener(type, fn) {
    const list = this.#listeners.get(type) ?? [];
    this.#listeners.set(type, list.filter((f) => f !== fn));
  }

  #emit(type, event) {
    for (const fn of [...(this.#listeners.get(type) ?? [])]) fn(event);
  }

  send(data) {
    const bytes = Buffer.from(data instanceof Uint8Array ? data : new Uint8Array(data));
    const header = Buffer.alloc(4);
    header.writeUInt32BE(bytes.length, 0);
    this.output.write(header);
    this.output.write(bytes);
  }

  close() {
    this.readyState = "closed";
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function arg(name, fallback = null) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

async function main() {
  const mode = process.argv[2];
  if (mode === "http2-to-dc") {
    const cmd = arg("--target-cmd");
    if (!cmd) throw new Error("--target-cmd required");
    const proc = spawn(cmd, {
      shell: true,
      detached: true,
      stdio: ["pipe", "pipe", "inherit"],
    });
    // The bridge owns the target: when the bridge dies (test cleanup
    // kills it), the target must not outlive it holding inherited
    // stdio pipes open. The target runs via a shell, so kill the
    // whole process group.
    const killTarget = () => {
      try {
        process.kill(-proc.pid, "SIGKILL");
      } catch {
        try {
          proc.kill("SIGKILL");
        } catch {
          /* already gone */
        }
      }
    };
    process.on("exit", killTarget);
    process.on("SIGTERM", () => {
      killTarget();
      process.exit(143);
    });
    process.on("SIGINT", () => {
      killTarget();
      process.exit(130);
    });
    const channel = new StdioChannel(proc.stdout, proc.stdin);
    const endpoint = new Endpoint(channel);
    const port = Number(arg("--port", "50051"));
    await serveHttp2ToDc({ port, endpoint });
    console.error(`bridge http2-to-dc listening on ${port}`);
  } else if (mode === "dc-to-http2") {
    const grpcAuthority = arg("--grpc", "127.0.0.1:50051");
    const channel = new StdioChannel(process.stdin, process.stdout);
    const endpoint = new Endpoint(channel, { parity: "even" });
    serveDcToHttp2({ grpcAuthority, endpoint });
    console.error(`bridge dc-to-http2 -> ${grpcAuthority}`);
  } else {
    console.error("usage: bridge.mjs http2-to-dc --port N --target-cmd CMD");
    console.error("       bridge.mjs dc-to-http2 --grpc HOST:PORT   (stdio = datachannel)");
    process.exit(2);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
