# Echo in every language

The same Echo service — unary, server-streaming,
client-streaming, and bidi — implemented per language
over the generated runtime. Server sources below are
the exported corpus examples; transcripts are real
stdio client->server runs captured at export time.

## C

```c
/* Interop harness: the C echo server over stdio. Stdout carries
   frames; diagnostics go to stderr. */
#include <stdio.h>
#include <unistd.h>

#include "echo_service_impl.h"
#include "stdio_transport.h"

int main(void) {
    stdio_transport stdio;
    stdio_transport_init(&stdio, STDIN_FILENO, STDOUT_FILENO);
    grpcdc_transport transport = stdio_transport_iface(&stdio);
    grpcdc_server *server = grpcdc_server_new();
    EchoServer_register(server, &echo_server_impl);
    grpcdc_status st = grpcdc_server_serve(server, &transport);
    fprintf(stderr, "server exit: %d %s\n", st.code, st.message);
    grpcdc_server_free(server);
    return 0;
}
```

Test suite in Docker:

    docker build -f docker/c.Dockerfile -t grpc-dc-c .
    docker run --rm grpc-dc-c

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## C++

```cpp
// Interop harness: the dynamic (descriptor-driven) C++ echo server
// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
// no generated stubs involved. Used by the oracle tests.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <thread>

#include "examples/dynamic_echo_service.hpp"
#include "examples/stdio_transport.hpp"
#include "grpcdc/dynamic.hpp"
#include "grpcdc/server.hpp"

namespace {

std::filesystem::path LocateFixtures() {
  std::filesystem::path dir = std::filesystem::current_path();
  for (int i = 0; i < 8; ++i) {
    auto direct = dir / "fixtures" / "echo_descriptor_set.bin";
    if (std::filesystem::exists(direct)) return direct;
    auto nested =
        dir / "grpc-over-datachannels" / "fixtures" / "echo_descriptor_set.bin";
    if (std::filesystem::exists(nested)) return nested;
    if (!dir.has_parent_path() || dir.parent_path() == dir) break;
    dir = dir.parent_path();
  }
  throw std::runtime_error("fixtures/echo_descriptor_set.bin not found");
}

grpcdc::Bytes ReadFile(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  return grpcdc::Bytes(std::istreambuf_iterator<char>(in),
                       std::istreambuf_iterator<char>());
}

}  // namespace

int main() {
  auto model = std::make_shared<grpcdc::dynamic::FileModel>(
      grpcdc::dynamic::ParseDescriptorSet(ReadFile(LocateFixtures())));
  auto transport = std::make_shared<echo::StdioTransport>(stdout, stdin);
  grpcdc::Server server;
  echo::DynamicEchoService impl;
  grpcdc::dynamic::RegisterDynamicService(server, *model, "echo.Echo", impl);
  server.ServeTransport(transport);
  // Exit when the driver closes our stdin (EOF), like the other
  // languages' stdio harnesses.
  while (true) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    if (std::feof(stdin) || std::ferror(stdin)) std::quick_exit(0);
  }
}
```

Test suite in Docker:

    docker build -f docker/cpp.Dockerfile -t grpc-dc-cpp .
    docker run --rm grpc-dc-cpp

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## C#

_(no stdio server example in the corpus)_

Test suite in Docker:

    docker build -f docker/csharp.Dockerfile -t grpc-dc-csharp .
    docker run --rm grpc-dc-csharp

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## Dart

_(no stdio server example in the corpus)_

Test suite in Docker:

    docker build -f docker/dart.Dockerfile -t grpc-dc-dart .
    docker run --rm grpc-dc-dart

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## Go

_(no stdio server example in the corpus)_

Test suite in Docker:

    docker build -f docker/go.Dockerfile -t grpc-dc-go .
    docker run --rm grpc-dc-go

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
error_case=INVALID-ARGUMENT: asked to fail
metadata=echo: hello [meta]
deadline=4
```

## Java

```java
package echo;

import grpcdc.Dynamic;
import grpcdc.Server;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Interop harness: the dynamic (descriptor-driven) Java echo server
 * over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
 * no generated stubs involved. Used by the oracle tests.
 */
public final class DynamicEchoServerStdio {
    private DynamicEchoServerStdio() {}

    public static void main(String[] args) throws Exception {
        Path fixtures = locateFixtures();
        Dynamic.FileModel model = Dynamic.parseDescriptorSet(Files.readAllBytes(fixtures));
        StdioTransport transport = new StdioTransport(System.out, System.in);
        transport.onEof = () -> System.exit(0);
        Server server = new Server();
        Dynamic.registerDynamicService(server, model, "echo.Echo", new DynamicEchoService());
        server.serveTransport(transport);
        Object lock = new Object();
        synchronized (lock) {
            lock.wait();
        }
    }

    private static Path locateFixtures() {
        Path dir = Path.of("").toAbsolutePath();
        for (int i = 0; i < 8 && dir != null; i++) {
            Path candidate = dir.resolve("fixtures/echo_descriptor_set.bin");
            if (Files.exists(candidate)) {
                return candidate;
            }
            candidate = dir.resolve("grpc-over-datachannels/fixtures/echo_descriptor_set.bin");
            if (Files.exists(candidate)) {
                return candidate;
            }
            dir = dir.getParent();
        }
        throw new IllegalStateException("fixtures/echo_descriptor_set.bin not found");
    }
}
```

Test suite in Docker:

    docker build -f docker/java.Dockerfile -t grpc-dc-java .
    docker run --rm grpc-dc-java

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## JavaScript

```js
// Interop harness: the dynamic (descriptor-driven) JS echo server
// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
// no generated stubs involved. Used by the oracle tests.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { Endpoint, Server, createDynamicService, parseDescriptorSet } from "../index.js";
import { dynamicEchoHandlers } from "./dynamic_echo.js";
import { StdioChannel } from "../../oracle/bridge.mjs";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const descriptors = readFileSync(`${ROOT}fixtures/echo_descriptor_set.bin`);
const model = parseDescriptorSet(new Uint8Array(descriptors));

const server = new Server();
server.addService(createDynamicService(model, "echo.Echo", dynamicEchoHandlers));
const endpoint = new Endpoint(new StdioChannel(process.stdin, process.stdout), { parity: "even" });
server.serve(endpoint);

setInterval(() => {}, 1000);
```

Test suite in Docker:

    docker build -f docker/js.Dockerfile -t grpc-dc-js .
    docker run --rm grpc-dc-js

## Kotlin

_(no stdio server example in the corpus)_

Test suite in Docker:

    docker build -f docker/kotlin.Dockerfile -t grpc-dc-kotlin .
    docker run --rm grpc-dc-kotlin

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## Lua

```lua
local scriptDir = arg[0]:match("^(.*)/lua/examples/[^/]+$") or "."
package.path = scriptDir .. "/lua/?.lua;" .. package.path

local serverModule = require("grpcdc.server")
local dynamic = require("grpcdc.dynamic")
local stdioModule = require("examples.stdio_transport")
local impl = require("examples.dynamic_echo_service")

--- Interop harness: the dynamic (descriptor-driven) Lua echo server
--- over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
--- no generated stubs involved. Used by the oracle tests.
local function locateFixtures()
  local dir = scriptDir
  for _ = 1, 8 do
    local direct = dir .. "/fixtures/echo_descriptor_set.bin"
    local f = io.open(direct, "rb")
    if f then
      f:close()
      return direct
    end
    local nested = dir .. "/grpc-over-datachannels/fixtures/echo_descriptor_set.bin"
    f = io.open(nested, "rb")
    if f then
      f:close()
      return nested
    end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent == nil or parent == dir then break end
    dir = parent
  end
  return nil
end

local fixture = locateFixtures()
if fixture == nil then
  io.stderr:write("fixtures/echo_descriptor_set.bin not found\n")
  os.exit(1)
end
local fh = assert(io.open(fixture, "rb"))
local data = fh:read("a")
fh:close()

local model = dynamic.parseDescriptorSet(data)
local transport = stdioModule.StdioTransport.new(io.stdin, io.stdout)
local server = serverModule.Server.new()
dynamic.registerDynamicService(server, model, "echo.Echo", impl)
local endpoint = server:serveTransport(transport)
while not transport.eof do
  endpoint:pump()
end
```

Test suite in Docker:

    docker build -f docker/lua.Dockerfile -t grpc-dc-lua .
    docker run --rm grpc-dc-lua

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=no error
error_case=INVALID-ARGUMENT: asked to fail
```

## PHP

```php
<?php
// Interop harness: the dynamic (descriptor-driven) PHP echo
// server over stdio. Loads fixtures/echo_descriptor_set.bin at
// runtime — no generated stubs involved. Used by the oracle tests.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/dynamic_echo.php";
require_once __DIR__ . "/stdio.php";

$root = dirname(__DIR__, 2);
$model = \Grpcdc\Dyn::parseDescriptorSet(file_get_contents($root . "/fixtures/echo_descriptor_set.bin"));
$transport = new StdioTransport(STDOUT, STDIN);
$transport->onEof = function () {
    exit(0);
};
$server = new \Grpcdc\Server();
\Grpcdc\Dyn::registerDynamicService($server, $model, "echo.Echo", new DynamicEchoService());
$endpoint = $server->serveTransport($transport);
$server->serveForever($endpoint);
```

Test suite in Docker:

    docker build -f docker/php.Dockerfile -t grpc-dc-php .
    docker run --rm grpc-dc-php

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## Python

```python
# Interop harness: the dynamic (descriptor-driven) Python echo
# server over stdio. Loads fixtures/echo_descriptor_set.bin at
# runtime — no generated stubs involved. Used by the oracle tests.
import os
import sys
import threading

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import grpcdc
from dynamic_echo import DynamicEchoService
from stdio import StdioTransport

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


def main():
    with open(os.path.join(ROOT, "fixtures", "echo_descriptor_set.bin"), "rb") as f:
        model = grpcdc.parse_descriptor_set(f.read())
    transport = StdioTransport(sys.stdout.buffer, sys.stdin.buffer)
    transport.on_eof = lambda: os._exit(0)
    server = grpcdc.Server()
    grpcdc.register_dynamic_service(server, model, "echo.Echo", DynamicEchoService())
    server.serve_transport(transport)
    threading.Event().wait()


if __name__ == "__main__":
    main()
```

Test suite in Docker:

    docker build -f docker/python.Dockerfile -t grpc-dc-python .
    docker run --rm grpc-dc-python

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
Fatal Python error: _enter_buffered_busy: could not acquire lock for <_io.BufferedReader name='<stdin>'> at interpreter shutdown, possibly due to daemon threads
Python runtime state: finalizing (tstate=0x0000000000b8a848)

Current thread 0x0000f1b088a17720 (most recent call first):
  <no Python frame>
```

## Ruby

```ruby
# Interop harness: the dynamic (descriptor-driven) Ruby echo
# server over stdio. Loads fixtures/echo_descriptor_set.bin at
# runtime — no generated stubs involved. Used by the oracle tests.

$LOAD_PATH.unshift(File.expand_path("..", __dir__))
$LOAD_PATH.unshift(__dir__)

require "grpcdc"
require_relative "dynamic_echo"
require_relative "stdio"

ROOT = File.expand_path("../..", __dir__)

model = Grpcdc.parse_descriptor_set(File.binread(File.join(ROOT, "fixtures", "echo_descriptor_set.bin")))
transport = StdioTransport.new($stdout, $stdin)
transport.on_eof = -> { exit!(0) }
server = Grpcdc::Server.new
Grpcdc.register_dynamic_service(server, model, "echo.Echo", DynamicEchoService.new)
server.serve_transport(transport)
sleep
```

Test suite in Docker:

    docker build -f docker/ruby.Dockerfile -t grpc-dc-ruby .
    docker run --rm grpc-dc-ruby

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## Rust

```rust
//! Interop harness: the Rust echo server over stdio.
//!
//! JS tests spawn this binary and drive it with the JavaScript client,
//! proving the two runtimes interoperate on the same frames. The 4-byte
//! length prefix exists only to frame messages on a byte stream (stdio);
//! each framed unit is exactly one DataChannel message (one grpc-dc
//! frame). Run via: `cargo run --example echo_server_stdio`

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{CallCtx, DcTransport, RequestStream, ResponseStream, Server, Status};
use std::sync::Arc;
use stub::{echo_service, Echo};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct StdioDc {
    tx: tokio::sync::Mutex<tokio::io::Stdout>,
    rx: tokio::sync::Mutex<tokio::io::Stdin>,
}

#[async_trait]
impl DcTransport for StdioDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        let mut tx = self.tx.lock().await;
        tx.write_u32(msg.len() as u32)
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        tx.write_all(&msg)
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        tx.flush()
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        Ok(())
    }

    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut rx = self.rx.lock().await;
        let len = match rx.read_u32().await {
            Ok(n) => n as usize,
            Err(_) => return None,
        };
        let mut buf = vec![0u8; len];
        match rx.read_exact(&mut buf).await {
            Ok(_) => Some(Ok(Bytes::from(buf))),
            Err(e) => Some(Err(Status::unavailable(format!("stdio read: {e}")))),
        }
    }
}

struct EchoService;

#[async_trait]
impl Echo for EchoService {
    async fn unary(&self, req: pb::EchoRequest, ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        if req.delay_ms > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(req.delay_ms as u64)).await;
        }
        if req.message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        let suffix =
            ctx.metadata.get("x-echo").map(|v| format!(" [{v}]")).unwrap_or_default();
        Ok(pb::EchoResponse { message: format!("echo: {}{}", req.message, suffix), index: 0, ..Default::default() })
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let responses = (0..req.count.max(0))
            .map(move |i| Ok(pb::EchoResponse { message: req.message.clone(), index: i, ..Default::default() }));
        Ok(Box::pin(futures_util::stream::iter(responses)))
    }

    async fn client_stream(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let parts: Vec<String> = reqs.map_ok(|r| r.message).try_collect().await?;
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32, ..Default::default() })
    }

    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream =
            futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut index)| async move {
                match reqs.next().await {
                    Some(Ok(req)) => {
                        let resp = pb::EchoResponse { message: req.message, index, ..Default::default() };
                        index += 1;
                        Some((Ok(resp), (reqs, index)))
                    }
                    Some(Err(e)) => Some((Err(e), (reqs, index))),
                    None => None,
                }
            });
        Ok(Box::pin(stream))
    }
}

#[tokio::main]
async fn main() {
    let transport: Arc<dyn DcTransport> = Arc::new(StdioDc {
        tx: tokio::sync::Mutex::new(tokio::io::stdout()),
        rx: tokio::sync::Mutex::new(tokio::io::stdin()),
    });
    Server::serve(transport, vec![echo_service(Arc::new(EchoService))]).await;
}
```

Test suite in Docker:

    docker build -f docker/rust.Dockerfile -t grpc-dc-rust .
    docker run --rm grpc-dc-rust

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
error_case=INVALID-ARGUMENT: asked to fail
metadata=echo: hello [meta]
deadline=4
```

## Scala

_(no stdio server example in the corpus)_

Test suite in Docker:

    docker build -f docker/scala.Dockerfile -t grpc-dc-scala .
    docker run --rm grpc-dc-scala

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## Swift

_(no stdio server example in the corpus)_

Test suite in Docker:

    docker build -f docker/swift.Dockerfile -t grpc-dc-swift .
    docker run --rm grpc-dc-swift

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

## Zig

```zig
const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");

/// Interop harness: the dynamic (descriptor-driven) Zig echo server
/// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
/// no generated stubs involved. Used by the oracle tests.
pub fn main() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();
    const fixture = locateFixtures(alloc) orelse {
        std.debug.print("fixtures/echo_descriptor_set.bin not found\n", .{});
        std.process.exit(1);
    };
    const data = std.fs.cwd().readFileAlloc(alloc, fixture, 1 << 24) catch {
        std.debug.print("cannot read {s}\n", .{fixture});
        std.process.exit(1);
    };
    const model = grpcdc.dynamic.parseDescriptorSet(alloc, data);
    var transport = examples.stdio_transport.StdioTransport.init(alloc, std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO);
    var server = grpcdc.server.Server.init(alloc);
    grpcdc.dynamic.registerDynamicService(&server, model, "echo.Echo", &examples.dynamic_echo_service.dynamic_echo_handler);
    _ = server.serveTransport(transport.transport());
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

fn locateFixtures(alloc: std.mem.Allocator) ?[]const u8 {
    var dir = std.fs.cwd().realpathAlloc(alloc, ".") catch return null;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        const direct = std.fmt.allocPrint(alloc, "{s}/fixtures/echo_descriptor_set.bin", .{dir}) catch return null;
        if (exists(direct)) return direct;
        const nested = std.fmt.allocPrint(alloc, "{s}/grpc-over-datachannels/fixtures/echo_descriptor_set.bin", .{dir}) catch return null;
        if (exists(nested)) return nested;
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = @constCast(parent);
    }
    return null;
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
```

Test suite in Docker:

    docker build -f docker/zig.Dockerfile -t grpc-dc-zig .
    docker run --rm grpc-dc-zig

Stdout/stderr transcript (stdio client -> own server,
captured when this export was built):

```
unary=echo: hello
server_stream=tick#0,tick#1,tick#2
client_stream=a+b+c
bidi=x,y
metadata=echo: hello [meta]
deadline=4
error_case=INVALID-ARGUMENT: asked to fail
```

