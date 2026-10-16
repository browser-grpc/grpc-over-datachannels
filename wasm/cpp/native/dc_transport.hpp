#pragma once

// Native DataChannel transport for the browser/WASM build:
// the real generated grpcdc runtime (cpp/grpcdc) over the
// page's RTCDataChannel. Runs in a Web Worker; js_dc_recv
// waits on a SharedArrayBuffer mailbox the page fills (see
// browser-test/wasm_cpp_native_worker.js). Provides TryRecv,
// so the grpcdc endpoint runs in its inline pump mode (no
// read/dispatch threads under wasm32-wasi). Built with
// wasi-sdk's exception-enabled libc++ (see the Makefile's
// test-cpp-wasm-native-browser target): the native runtime
// reports failures by throwing grpcdc::StatusException.

#include <cstddef>
#include <cstdint>
#include <vector>

#include "grpcdc/transport.hpp"

#define GRPCDC_WASM_IMPORT(name) \
  __attribute__((import_module("env"), import_name(name)))

extern "C" {
GRPCDC_WASM_IMPORT("js_dc_send")
void js_dc_send(const std::uint8_t* ptr, std::size_t len);
/// Returns message length, -1 on timeout, -2 when closed.
GRPCDC_WASM_IMPORT("js_dc_recv")
int js_dc_recv(std::uint8_t* ptr, std::size_t cap, int timeout_ms);
}

class DcTransport : public grpcdc::Transport {
 public:
  void Send(const grpcdc::Bytes& data) override {
    js_dc_send(data.data(), data.size());
  }

  grpcdc::Bytes Recv() override {
    while (true) {
      grpcdc::Bytes out;
      TryRecvResult result = TryRecv(out);
      if (result == TryRecvResult::kMessage) return out;
      if (result == TryRecvResult::kClosed) throw grpcdc::EndOfStream();
    }
  }

  bool HasTryRecv() const override { return true; }

  TryRecvResult TryRecv(grpcdc::Bytes& out) override {
    const int n = js_dc_recv(Buffer().data(), kMaxMessage, 50);
    if (n == -1) return TryRecvResult::kWouldBlock;
    if (n < 0) return TryRecvResult::kClosed;
    out.assign(Buffer().begin(), Buffer().begin() + n);
    return TryRecvResult::kMessage;
  }

  void Close() override {}

 private:
  static constexpr std::size_t kMaxMessage = 256 * 1024;

  static std::vector<std::uint8_t>& Buffer() {
    static std::vector<std::uint8_t> buffer(kMaxMessage);
    return buffer;
  }
};
