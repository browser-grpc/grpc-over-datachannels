#!/usr/bin/env node
// grpc-dc-proxy: HTTP/2 ingress -> grpc-dc server.
//
// Scope is exactly the official gRPC transport set (grpc-java
// and peers): HTTP/2, carried over TCP — plaintext h2c by
// default, TLS (ALPN h2) with --tls-cert/--tls-key. There is
// deliberately no HTTP/3 and no custom framed-TCP ingress:
// grpc-java supports neither.
//
// Ingress: stock HTTP/2 gRPC clients connect to --http2;
// each call is translated onto the grpc-dc wire and served
// by a real grpc-dc Server (oracle/bridge.mjs
// serveHttp2ToDc). Compression is terminated here; the
// DataChannel wire is always uncompressed.
//
// DC side: --dc-dial <multiaddr> — the proxy dials the
// grpc-dc server over WebRTC-Direct (no ICE, no SDP, no
// signaling server; the listener is its certhash multiaddr,
// js/src/webrtc_direct.js). The server side runs any grpc-dc
// Server (see proxy/grpc-dc-agent.mjs for the Echo demo
// agent; real deployments serve their own generated service
// the same way).
//
//   node proxy/grpc-dc-proxy.mjs --dc-dial /ip4/127.0.0.1/udp/4001/webrtc-direct/certhash/<hash> --http2 50051

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

import { Endpoint } from "../js/index.js";
import { directClientStackEndpoint } from "../js/src/webrtc_direct.js";
import { serveHttp2ToDc } from "./bridge.mjs";

// ---------------------------------------------------------------------------
// DC dial: WebRTC-Direct to the grpc-dc server's listener.
// Returns the raw stack endpoint; the ingress proxy opens
// its "grpc" channel on it.
// ---------------------------------------------------------------------------

export async function dialDc(multiaddr) {
  const endpoint = await directClientStackEndpoint(multiaddr);
  return {
    endpoint,
    close: async () => {
      // closeDirect also closes the UDP socket; the SCTP-only
      // endpoint.close() would leak it and hang the process.
      if (typeof endpoint.closeDirect === "function") {
        await endpoint.closeDirect().catch(() => {});
      } else {
        await endpoint.close().catch(() => {});
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Ingress proxy: HTTP/2 (over TCP) listener -> grpc-dc server.
// dcStackEndpoint is the WebRTC-Direct stack endpoint to the
// server (tests inject it; the CLI obtains it via dialDc).
// ---------------------------------------------------------------------------

export async function startIngressProxy({ dcStackEndpoint, http2Port = 0, host = "127.0.0.1", dc = null, tls = null }) {
  const closers = [];
  let http2 = null;

  if (http2Port) {
    const channel = dcStackEndpoint.openChannel({ label: "grpc" });
    http2 = await serveHttp2ToDc({ port: http2Port, endpoint: new Endpoint(channel), host, tls });
    closers.push(() => new Promise((done) => http2.close(done)));
  }

  console.log(
    `grpc-dc-proxy: ingress http2=${http2Port}${tls ? " (tls)" : ""} -> grpc-dc server`,
  );
  return {
    http2,
    http2Port: http2?.address?.().port ?? http2Port,
    dc,
    close: async () => {
      for (const close of closers) await close();
      if (dc) await dc.close();
    },
  };
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const value = (name, fallback) => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : fallback;
  };
  const dcDial = value("--dc-dial");
  if (dcDial) {
    const tlsCert = value("--tls-cert");
    const tls = tlsCert
      ? { cert: readFileSync(tlsCert), key: readFileSync(value("--tls-key")) }
      : null;
    const dc = await dialDc(dcDial);
    await startIngressProxy({
      dcStackEndpoint: dc.endpoint,
      dc,
      http2Port: Number(value("--http2", "0")),
      host: value("--host", "0.0.0.0"),
      tls,
    });
  } else {
    console.error(
      "usage: node proxy/grpc-dc-proxy.mjs --dc-dial <multiaddr> [--http2 50051] [--tls-cert c.pem --tls-key k.pem]",
    );
    process.exit(2);
  }
}

