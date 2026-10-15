#pragma once

#include <cstdio>
#include <mutex>

#include "grpcdc/transport.hpp"

namespace echo {

/// Stdio transport: frames DataChannel messages over a byte stream
/// with a 4-byte big-endian length prefix (the prefix exists only to
/// frame messages on stdio; each framed unit is exactly one
/// DataChannel message). Used by the cross-language interop harnesses.
/// Reader/writer are FILE* streams (stdin/stdout or process pipes).
class StdioTransport : public grpcdc::Transport {
 public:
  StdioTransport(FILE* writer, FILE* reader) : writer_(writer), reader_(reader) {}

  void Send(const grpcdc::Bytes& data) override {
    std::lock_guard<std::mutex> lock(mu_);
    std::uint32_t len = static_cast<std::uint32_t>(data.size());
    std::uint8_t header[4] = {static_cast<std::uint8_t>(len >> 24),
                              static_cast<std::uint8_t>(len >> 16),
                              static_cast<std::uint8_t>(len >> 8),
                              static_cast<std::uint8_t>(len)};
    if (std::fwrite(header, 1, 4, writer_) != 4 ||
        std::fwrite(data.data(), 1, data.size(), writer_) != data.size() ||
        std::fflush(writer_) != 0) {
      throw grpcdc::EndOfStream();
    }
  }

  grpcdc::Bytes Recv() override {
    std::uint8_t header[4];
    if (!ReadExact(header, 4)) throw grpcdc::EndOfStream();
    std::uint32_t len = (static_cast<std::uint32_t>(header[0]) << 24) |
                        (static_cast<std::uint32_t>(header[1]) << 16) |
                        (static_cast<std::uint32_t>(header[2]) << 8) |
                        static_cast<std::uint32_t>(header[3]);
    grpcdc::Bytes payload(len);
    if (len > 0 && !ReadExact(payload.data(), len)) throw grpcdc::EndOfStream();
    return payload;
  }

 private:
  bool ReadExact(std::uint8_t* out, std::size_t n) {
    std::size_t got = 0;
    while (got < n) {
      std::size_t r = std::fread(out + got, 1, n - got, reader_);
      if (r == 0) return false;
      got += r;
    }
    return true;
  }

  FILE* writer_;
  FILE* reader_;
  std::mutex mu_;
};

}  // namespace echo
