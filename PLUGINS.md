# protoc plugins: install

grpc-dc ships one dependency-free `protoc` plugin per
language. The only requirements are `protoc` itself and
Node.js 18+. Pick whichever channel fits your workflow:

## 1. Release zip (any platform)

Download `grpc-dc-v0.32.16.zip` and `SHA256SUMS` from
the [v0.32.16 release](https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.32.16), verify, and unzip:

    sha256sum -c SHA256SUMS
    unzip grpc-dc-v0.32.16.zip
    export PATH="$PWD/grpc-dc-v0.32.16/bin:$PATH"
    protoc -I. --grpc-dc-rust_out=gen echo.proto

With `bin/` on your `PATH`, `protoc` finds each plugin by
name (`protoc-gen-grpc-dc-rust`, `-go`, `-python`, ...).
Or name a wrapper explicitly:

    protoc -I. --plugin=protoc-gen-grpc-dc-rust=$PWD/grpc-dc-v0.32.16/bin/protoc-gen-grpc-dc-rust \
      --grpc-dc-rust_out=gen echo.proto

## 2. npm (JS/web tooling)

The `grpc-dc` npm package ships the same plugins as bin
entries:

    npm install --save-dev grpc-dc
    protoc -I. --plugin=protoc-gen-grpc-dc-rust=node_modules/.bin/protoc-gen-grpc-dc-rust \
      --grpc-dc-rust_out=gen echo.proto

## 3. Container (no host Node)

`protoc` and all plugins, preinstalled on `PATH`:

    docker run --rm -v "$PWD":/work ghcr.io/browser-grpc/protoc-plugins:v0.32.16 \
      -I. --grpc-dc-rust_out=gen echo.proto

## From a clone of this repo

The `bin/` wrappers in the repo root work in place; see
the per-language READMEs (e.g. `rust/README.md`) for the
exact `protoc` invocation per language. The example
schema used above is `proto/echo.proto` in this repo.

Languages: `js`, `c`, `go`, `python`, `rust`, `java`, `csharp`, `cpp`, `swift`, `kotlin`, `dart`, `zig`, `lua`, `ruby`, `php`, `scala`, `wasm-go`, `wasm-zig`, `wasm-cpp`, `wasm-swift`, `wasm-kotlin`, `wasm-scala`, `kotlin-native`.
