const std = @import("std");

/// Minimal protobuf wire writer/reader for the hand-written messages.
pub const PbWriter = struct {
    out: std.Io.Writer.Allocating,

    pub fn init(alloc: std.mem.Allocator) PbWriter {
        return .{ .out = .init(alloc) };
    }

    pub fn deinit(self: *PbWriter) void {
        self.out.deinit();
    }

    pub fn varint(self: *PbWriter, value: u64) void {
        var v = value;
        while ((v & ~@as(u64, 0x7f)) != 0) {
            self.out.writer.writeByte(@intCast((v & 0x7f) | 0x80)) catch {};
            v >>= 7;
        }
        self.out.writer.writeByte(@intCast(v & 0xff)) catch {};
    }

    pub fn stringField(self: *PbWriter, field: u32, value: []const u8) void {
        if (value.len == 0) return;
        self.varint((@as(u64, field) << 3) | 2);
        self.varint(value.len);
        self.out.writer.writeAll(value) catch {};
    }

    pub fn int32Field(self: *PbWriter, field: u32, value: i32) void {
        if (value == 0) return;
        self.varint((@as(u64, field) << 3) | 0);
        self.varint(@bitCast(@as(i64, value)));
    }

    /// Owned by the caller (free with the writer's allocator).
    pub fn toBytes(self: *PbWriter) []u8 {
        return self.out.toOwnedSlice() catch &.{};
    }
};

pub const PbField = struct {
    number: u32,
    varint_value: u64 = 0,
    bytes_value: []const u8 = "",

    pub fn asInt32(self: PbField) i32 {
        return @truncate(@as(i64, @bitCast(self.varint_value)));
    }

    pub fn asString(self: PbField) []const u8 {
        return self.bytes_value;
    }
};

pub const PbReader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) PbReader {
        return .{ .buf = buf };
    }

    pub fn varint(self: *PbReader) u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.buf.len) return result;
            const b = self.buf[self.pos];
            self.pos += 1;
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return result;
            shift += 7;
            if (shift >= 63) return result;
        }
    }

    /// Next field, or null at end.
    pub fn next(self: *PbReader) ?PbField {
        if (self.pos >= self.buf.len) return null;
        const tag = self.varint();
        const number: u32 = @intCast(tag >> 3);
        switch (tag & 7) {
            0 => return .{ .number = number, .varint_value = self.varint() },
            2 => {
                const n: usize = @intCast(self.varint());
                if (self.pos + n > self.buf.len) return null;
                const bytes = self.buf[self.pos .. self.pos + n];
                self.pos += n;
                return .{ .number = number, .bytes_value = bytes };
            },
            1 => {
                if (self.pos + 8 > self.buf.len) return null;
                const bytes = self.buf[self.pos .. self.pos + 8];
                self.pos += 8;
                return .{ .number = number, .bytes_value = bytes };
            },
            5 => {
                if (self.pos + 4 > self.buf.len) return null;
                const bytes = self.buf[self.pos .. self.pos + 4];
                self.pos += 4;
                return .{ .number = number, .bytes_value = bytes };
            },
            else => return null,
        }
    }
};
