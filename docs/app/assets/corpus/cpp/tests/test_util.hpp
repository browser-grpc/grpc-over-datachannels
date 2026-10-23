#pragma once

#include <cstdio>
#include <filesystem>
#include <cstdlib>
#include <stdexcept>
#include <string>

#include "grpcdc/codec.hpp"

namespace tests {

inline void Check(bool condition, const std::string& what) {
  if (!condition) throw std::runtime_error("check failed: " + what);
}

inline grpcdc::Bytes FromHex(const std::string& hex) {
  grpcdc::Bytes out;
  auto val = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
  };
  for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
    out.push_back(static_cast<std::uint8_t>(val(hex[i]) * 16 + val(hex[i + 1])));
  }
  return out;
}

inline std::string ToHex(const grpcdc::Bytes& bytes) {
  static const char* digits = "0123456789abcdef";
  std::string out;
  for (auto b : bytes) {
    out += digits[b >> 4];
    out += digits[b & 0xf];
  }
  return out;
}

/// Repository root, located by walking up from the cwd looking for
/// fixtures/echo_descriptor_set.bin (mirrors the Rust dynamic harness).
inline std::string Root() {
  const char* env = std::getenv("GRPC_DC_ROOT");
  if (env && *env) return env;
  std::filesystem::path dir = std::filesystem::current_path();
  for (int i = 0; i < 8; ++i) {
    if (std::filesystem::exists(dir / "fixtures" / "echo_descriptor_set.bin")) {
      return dir.string();
    }
    if (std::filesystem::exists(dir / "grpc-over-datachannels" / "fixtures" /
                                "echo_descriptor_set.bin")) {
      return (dir / "grpc-over-datachannels").string();
    }
    if (!dir.has_parent_path() || dir.parent_path() == dir) break;
    dir = dir.parent_path();
  }
  return ".";
}

}  // namespace tests
