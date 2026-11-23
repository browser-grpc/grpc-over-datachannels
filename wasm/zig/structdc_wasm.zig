// Struct-codec C ABI for the Zig Wasm build: implements the
// grpcdc_struct_* symbols generated struct companions link
// against, using the pure grpcdc structdc transcoder
// (zig/grpcdc/structdc.zig) instead of the native Rust
// cdylib. Output/error buffers are allocated with the Wasm
// allocator; callers free results with grpcdc_struct_free and
// errors with grpcdc_struct_error_free, matching the native
// ABI (errors are NUL-terminated).

const std = @import("std");
const structdc = @import("grpcdc_structdc");

const alloc = std.heap.wasm_allocator;

fn transcodeInner(encode: bool, desc: [*]const u8, desc_len: usize, type_name: [*]const u8, type_len: usize, input: [*]const u8, input_len: usize, out: *?[*]u8, out_len: *usize, err_out: *?[*]u8) i32 {
    const result = structdc.transcode(alloc, desc[0..desc_len], type_name[0..type_len], input[0..input_len], encode) catch {
        const msg = "struct codec transcode failed";
        const buf = alloc.alloc(u8, msg.len + 1) catch return -1;
        @memcpy(buf[0..msg.len], msg);
        buf[msg.len] = 0;
        err_out.* = buf.ptr;
        return -1;
    };
    out.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

pub export fn grpcdc_struct_encode(desc: [*]const u8, desc_len: usize, type_name: [*]const u8, type_len: usize, input: [*]const u8, input_len: usize, out: *?[*]u8, out_len: *usize, err_out: *?[*]u8) i32 {
    return transcodeInner(true, desc, desc_len, type_name, type_len, input, input_len, out, out_len, err_out);
}

pub export fn grpcdc_struct_decode(desc: [*]const u8, desc_len: usize, type_name: [*]const u8, type_len: usize, input: [*]const u8, input_len: usize, out: *?[*]u8, out_len: *usize, err_out: *?[*]u8) i32 {
    return transcodeInner(false, desc, desc_len, type_name, type_len, input, input_len, out, out_len, err_out);
}

pub export fn grpcdc_struct_free(ptr: [*]u8, len: usize) void {
    alloc.free(ptr[0..len]);
}

pub export fn grpcdc_struct_error_free(ptr: [*]u8) void {
    // Errors are NUL-terminated; recover the length.
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    alloc.free(ptr[0 .. len + 1]);
}
