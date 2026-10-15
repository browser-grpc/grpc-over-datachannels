const std = @import("std");
const pb = @import("pb.zig");

/// Hand-written protobuf messages for proto/echo.proto (package echo).
///
/// Deliberately minimal (two messages) so the example needs no
/// protobuf codegen dependency — the wire bytes are genuine protobuf:
/// EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
/// Mirrors the other languages' echo messages.
pub const EchoRequest = struct {
    message: []const u8 = "",
    count: i32 = 0,
    delay_ms: i32 = 0,

    pub fn marshalDc(self: *const EchoRequest, alloc: std.mem.Allocator) []u8 {
        var w = pb.PbWriter.init(alloc);
        defer w.deinit();
        w.stringField(1, self.message);
        w.int32Field(2, self.count);
        w.int32Field(3, self.delay_ms);
        const bytes = w.toBytes();
        return bytes;
    }

    /// Decoded strings are duplicated with alloc (they outlive the
    /// payload buffer); free them with the same allocator.
    pub fn unmarshalDc(self: *EchoRequest, alloc: std.mem.Allocator, data: []const u8) void {
        self.message = "";
        self.count = 0;
        self.delay_ms = 0;
        var r = pb.PbReader.init(data);
        while (r.next()) |field| {
            switch (field.number) {
                1 => self.message = alloc.dupe(u8, field.asString()) catch "",
                2 => self.count = field.asInt32(),
                3 => self.delay_ms = field.asInt32(),
                else => {}, // skip unknown fields
            }
        }
    }
};

pub const EchoResponse = struct {
    message: []const u8 = "",
    index: i32 = 0,

    pub fn marshalDc(self: *const EchoResponse, alloc: std.mem.Allocator) []u8 {
        var w = pb.PbWriter.init(alloc);
        defer w.deinit();
        w.stringField(1, self.message);
        w.int32Field(2, self.index);
        return w.toBytes();
    }

    pub fn unmarshalDc(self: *EchoResponse, alloc: std.mem.Allocator, data: []const u8) void {
        self.message = "";
        self.index = 0;
        var r = pb.PbReader.init(data);
        while (r.next()) |field| {
            switch (field.number) {
                1 => self.message = alloc.dupe(u8, field.asString()) catch "",
                2 => self.index = field.asInt32(),
                else => {}, // skip unknown fields
            }
        }
    }
};
