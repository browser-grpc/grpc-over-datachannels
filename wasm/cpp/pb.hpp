#pragma once

#include <cstdint>
#include <string>

#include "bridge.hpp"

namespace echo {

/// Minimal protobuf wire writer/reader for the WASM messages.
/// Exception-free counterpart of cpp/examples/pb.hpp: the
/// reader reports malformed input by returning false instead
/// of throwing grpcdc::StatusException.
namespace pb {

class Writer {
 public:
  void Varint(std::int64_t value) {
    std::uint64_t v = static_cast<std::uint64_t>(value);
    while ((v & ~0x7fULL) != 0) {
      out_.push_back(static_cast<std::uint8_t>((v & 0x7f) | 0x80));
      v >>= 7;
    }
    out_.push_back(static_cast<std::uint8_t>(v));
  }
  void StringField(int field, const std::string& value) {
    if (value.empty()) return;
    Varint((field << 3) | 2);
    Varint(static_cast<std::int64_t>(value.size()));
    out_.insert(out_.end(), value.begin(), value.end());
  }
  void Int32Field(int field, std::int32_t value) {
    if (value == 0) return;
    Varint((field << 3) | 0);
    Varint(value);
  }
  grpcdc_wasm::Bytes ToBytes() const { return out_; }

 private:
  grpcdc_wasm::Bytes out_;
};

struct Field {
  int number = 0;
  std::int64_t varint_value = 0;
  grpcdc_wasm::Bytes bytes_value;
  int AsInt32() const { return static_cast<std::int32_t>(varint_value); }
  std::string AsString() const {
    return std::string(bytes_value.begin(), bytes_value.end());
  }
};

class Reader {
 public:
  explicit Reader(const grpcdc_wasm::Bytes& buf) : buf_(buf) {}

  bool Varint(std::int64_t& out) {
    std::int64_t result = 0;
    int shift = 0;
    while (true) {
      if (pos_ >= buf_.size()) return false;
      std::uint8_t b = buf_[pos_++];
      result |= static_cast<std::int64_t>(b & 0x7f) << shift;
      if ((b & 0x80) == 0) {
        out = result;
        return true;
      }
      shift += 7;
      if (shift >= 64) return false;
    }
  }

  /// Next field. Returns 1 on a field, 0 at end, -1 on error.
  int Next(Field& field) {
    if (pos_ >= buf_.size()) return 0;
    std::int64_t tag = 0;
    if (!Varint(tag)) return -1;
    field = Field{};
    field.number = static_cast<int>(tag >> 3);
    switch (static_cast<int>(tag & 7)) {
      case 0:
        return Varint(field.varint_value) ? 1 : -1;
      case 2: {
        std::int64_t len = 0;
        if (!Varint(len) || len < 0) return -1;
        const auto n = static_cast<std::size_t>(len);
        if (pos_ + n > buf_.size()) return -1;
        field.bytes_value.assign(buf_.begin() + pos_, buf_.begin() + pos_ + n);
        pos_ += n;
        return 1;
      }
      case 1: {
        if (pos_ + 8 > buf_.size()) return -1;
        field.bytes_value.assign(buf_.begin() + pos_, buf_.begin() + pos_ + 8);
        pos_ += 8;
        return 1;
      }
      case 5: {
        if (pos_ + 4 > buf_.size()) return -1;
        field.bytes_value.assign(buf_.begin() + pos_, buf_.begin() + pos_ + 4);
        pos_ += 4;
        return 1;
      }
      default:
        return -1;
    }
  }

 private:
  const grpcdc_wasm::Bytes& buf_;
  std::size_t pos_ = 0;
};

}  // namespace pb
}  // namespace echo
