// Struct-codec C ABI for the C++ Wasm build: implements the
// grpcdc_struct_* symbols generated struct companions link
// against, using the pure grpcdc::structdc transcoder
// (cpp/grpcdc/structdc.hpp) instead of the native Rust
// cdylib. All output/error buffers are malloc'd; callers free
// results with grpcdc_struct_free and errors with
// grpcdc_struct_error_free, matching the native ABI.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

#include "grpcdc/structdc.hpp"

namespace {

using Bytes = grpcdc::structdc::Bytes;

char* DupError(const std::string& msg) {
  char* out = static_cast<char*>(std::malloc(msg.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, msg.c_str(), msg.size() + 1);
  return out;
}

int Transcode(bool encode, const std::uint8_t* desc, std::size_t desc_len,
              const std::uint8_t* type, std::size_t type_len,
              const std::uint8_t* input, std::size_t input_len,
              std::uint8_t** out, std::size_t* out_len, char** err) {
  Bytes descriptor(desc, desc + desc_len);
  std::string typeName(reinterpret_cast<const char*>(type), type_len);
  Bytes in(input, input + input_len);
  Bytes result;
  std::string error;
  if (!grpcdc::structdc::Transcode(descriptor, typeName, in, encode, result,
                                   error)) {
    if (err != nullptr) *err = DupError(error);
    return -1;
  }
  std::uint8_t* buf =
      static_cast<std::uint8_t*>(std::malloc(result.empty() ? 1 : result.size()));
  if (buf == nullptr) {
    if (err != nullptr) *err = DupError("out of memory");
    return -1;
  }
  if (!result.empty()) std::memcpy(buf, result.data(), result.size());
  *out = buf;
  *out_len = result.size();
  return 0;
}

}  // namespace

extern "C" int grpcdc_struct_encode(const std::uint8_t* desc,
                                    std::size_t desc_len,
                                    const std::uint8_t* type,
                                    std::size_t type_len,
                                    const std::uint8_t* input,
                                    std::size_t input_len, std::uint8_t** out,
                                    std::size_t* out_len, char** err) {
  return Transcode(true, desc, desc_len, type, type_len, input, input_len, out,
                   out_len, err);
}

extern "C" int grpcdc_struct_decode(const std::uint8_t* desc,
                                    std::size_t desc_len,
                                    const std::uint8_t* type,
                                    std::size_t type_len,
                                    const std::uint8_t* input,
                                    std::size_t input_len, std::uint8_t** out,
                                    std::size_t* out_len, char** err) {
  return Transcode(false, desc, desc_len, type, type_len, input, input_len, out,
                   out_len, err);
}

extern "C" void grpcdc_struct_free(std::uint8_t* ptr, std::size_t /*len*/) {
  std::free(ptr);
}

extern "C" void grpcdc_struct_error_free(char* ptr) { std::free(ptr); }
