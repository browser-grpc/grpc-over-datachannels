const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const scenarios = @import("oracle_scenarios.zig");
const util = @import("test_util.zig");

const EchoRequest = examples.echo_messages.EchoRequest;
const DynamicClient = grpcdc.dynamic.DynamicClient;
const GenericMessage = grpcdc.dynamic.GenericMessage;

fn unmsg(token: []const u8) []const u8 {
    return if (std.mem.eql(u8, token, "-")) "" else token;
}

fn req(message: []const u8, count: i32) EchoRequest {
    return .{ .message = message, .count = count };
}

/// Shared oracle-scenario runner for the typed stub client
/// (TestOracle) and the dynamic client (TestDynamic).
pub fn runScenarios(alloc: std.mem.Allocator, client: *examples.echo_grpc_dc.EchoClient) void {
    for (scenarios.cases) |c| {
        var messages: std.ArrayList([]const u8) = .empty;
        defer messages.deinit(alloc);
        for (c.messages) |m| messages.append(alloc, unmsg(m)) catch {};
        if (std.mem.eql(u8, c.kind, "UNARY")) {
            switch (client.unary(&req(messages.items[0], 0), null, null)) {
                .ok => |resp| {
                    util.check(c.expect_status < 0, "UNARY: expected failure");
                    const want = std.fmt.allocPrint(alloc, "echo: {s}", .{messages.items[0]}) catch "";
                    util.check(std.mem.eql(u8, resp.message, want) and resp.index == 0, "UNARY: response");
                },
                .status => |st| {
                    util.check(c.expect_status >= 0 and st.code == c.expect_status, "UNARY: status");
                },
            }
        } else if (std.mem.eql(u8, c.kind, "SERVER_STREAM")) {
            var stream = switch (client.serverStream(&req(messages.items[0], c.count), null, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.checkFmt(false, "SERVER_STREAM open status {d}", .{st.code});
                    unreachable;
                },
            };
            defer stream.deinit();
            var got: i32 = 0;
            while (true) {
                switch (stream.recv()) {
                    .message => |resp| {
                        util.check(std.mem.eql(u8, resp.message, messages.items[0]) and resp.index == got, "SERVER_STREAM: response");
                        got += 1;
                    },
                    .end => break,
                    .status => |st| {
                        util.checkFmt(false, "SERVER_STREAM status {d}", .{st.code});
                        break;
                    },
                }
            }
            util.check(got == c.count, "SERVER_STREAM: count");
        } else if (std.mem.eql(u8, c.kind, "CLIENT_STREAM")) {
            var reqs: std.ArrayList(EchoRequest) = .empty;
            defer reqs.deinit(alloc);
            for (messages.items) |m| reqs.append(alloc, req(m, 0)) catch {};
            switch (client.clientStream(reqs.items, null, null)) {
                .ok => |resp| {
                    var joined: std.ArrayList(u8) = .empty;
                    defer joined.deinit(alloc);
                    for (messages.items, 0..) |m, i| {
                        if (i > 0) joined.append(alloc, '+') catch {};
                        joined.appendSlice(alloc, m) catch {};
                    }
                    util.check(std.mem.eql(u8, resp.message, joined.items) and resp.index == @as(i32, @intCast(messages.items.len)), "CLIENT_STREAM: response");
                },
                .status => |st| util.checkFmt(false, "CLIENT_STREAM status {d}", .{st.code}),
            }
        } else if (std.mem.eql(u8, c.kind, "BIDI")) {
            var reqs: std.ArrayList(EchoRequest) = .empty;
            defer reqs.deinit(alloc);
            for (messages.items) |m| reqs.append(alloc, req(m, 0)) catch {};
            var stream = switch (client.bidi(reqs.items, null, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.checkFmt(false, "BIDI open status {d}", .{st.code});
                    unreachable;
                },
            };
            defer stream.deinit();
            var got: usize = 0;
            while (true) {
                switch (stream.recv()) {
                    .message => |resp| {
                        util.check(got < messages.items.len and std.mem.eql(u8, resp.message, messages.items[got]) and resp.index == @as(i32, @intCast(got)), "BIDI: response");
                        got += 1;
                    },
                    .end => break,
                    .status => |st| {
                        util.checkFmt(false, "BIDI status {d}", .{st.code});
                        break;
                    },
                }
            }
            util.check(got == messages.items.len, "BIDI: count");
        } else {
            util.checkFmt(false, "unknown scenario kind: {s}", .{c.kind});
        }
    }
}

const service_name = "echo.Echo";

fn dynReq(alloc: std.mem.Allocator, model: *grpcdc.dynamic.FileModel, message: []const u8, count: i64) *GenericMessage {
    const msg_type = model.message(".echo.EchoRequest").?;
    const msg = alloc.create(GenericMessage) catch @panic("out of memory");
    msg.* = GenericMessage.init(alloc, msg_type);
    _ = msg.set(alloc, 1, .{ .string = alloc.dupe(u8, message) catch "" });
    _ = msg.set(alloc, 2, .{ .int = count });
    return msg;
}

pub fn runDynamicScenarios(alloc: std.mem.Allocator, client: *DynamicClient, model: *grpcdc.dynamic.FileModel) void {
    for (scenarios.cases) |c| {
        var messages: std.ArrayList([]const u8) = .empty;
        defer messages.deinit(alloc);
        for (c.messages) |m| messages.append(alloc, unmsg(m)) catch {};
        if (std.mem.eql(u8, c.kind, "UNARY")) {
            switch (client.unary(service_name, "Unary", dynReq(alloc, model, messages.items[0], 0), null, null)) {
                .ok => |resp| {
                    util.check(c.expect_status < 0, "dyn UNARY: expected failure");
                    const want = std.fmt.allocPrint(alloc, "echo: {s}", .{messages.items[0]}) catch "";
                    util.check(std.mem.eql(u8, resp.getString(1), want) and resp.getInt(2) == 0, "dyn UNARY: response");
                },
                .status => |st| {
                    util.check(c.expect_status >= 0 and st.code == c.expect_status, "dyn UNARY: status");
                },
            }
        } else if (std.mem.eql(u8, c.kind, "SERVER_STREAM")) {
            var stream = switch (client.serverStream(service_name, "ServerStream", dynReq(alloc, model, messages.items[0], c.count), null, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.checkFmt(false, "dyn SERVER_STREAM open {d}", .{st.code});
                    unreachable;
                },
            };
            defer stream.deinit();
            const responses = switch (grpcdc.dynamic.collectStream(alloc, &stream)) {
                .ok => |r| r,
                .status => |st| {
                    util.checkFmt(false, "dyn SERVER_STREAM collect {d}", .{st.code});
                    unreachable;
                },
            };
            util.check(responses.len == @as(usize, @intCast(c.count)), "dyn SERVER_STREAM: count");
            for (responses, 0..) |resp, i| {
                util.check(std.mem.eql(u8, resp.getString(1), messages.items[0]) and resp.getInt(2) == @as(i64, @intCast(i)), "dyn SERVER_STREAM: item");
            }
        } else if (std.mem.eql(u8, c.kind, "CLIENT_STREAM")) {
            var reqs: std.ArrayList(*GenericMessage) = .empty;
            defer reqs.deinit(alloc);
            for (messages.items) |m| reqs.append(alloc, dynReq(alloc, model, m, 0)) catch {};
            switch (client.clientStream(service_name, "ClientStream", reqs.items, null, null)) {
                .ok => |resp| {
                    var joined: std.ArrayList(u8) = .empty;
                    defer joined.deinit(alloc);
                    for (messages.items, 0..) |m, i| {
                        if (i > 0) joined.append(alloc, '+') catch {};
                        joined.appendSlice(alloc, m) catch {};
                    }
                    util.check(std.mem.eql(u8, resp.getString(1), joined.items) and resp.getInt(2) == @as(i64, @intCast(messages.items.len)), "dyn CLIENT_STREAM: response");
                },
                .status => |st| util.checkFmt(false, "dyn CLIENT_STREAM status {d}", .{st.code}),
            }
        } else if (std.mem.eql(u8, c.kind, "BIDI")) {
            var reqs: std.ArrayList(*GenericMessage) = .empty;
            defer reqs.deinit(alloc);
            for (messages.items) |m| reqs.append(alloc, dynReq(alloc, model, m, 0)) catch {};
            var stream = switch (client.bidi(service_name, "Bidi", reqs.items, null, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.checkFmt(false, "dyn BIDI open {d}", .{st.code});
                    unreachable;
                },
            };
            defer stream.deinit();
            const responses = switch (grpcdc.dynamic.collectStream(alloc, &stream)) {
                .ok => |r| r,
                .status => |st| {
                    util.checkFmt(false, "dyn BIDI collect {d}", .{st.code});
                    unreachable;
                },
            };
            util.check(responses.len == messages.items.len, "dyn BIDI: count");
            for (responses, 0..) |resp, i| {
                util.check(std.mem.eql(u8, resp.getString(1), messages.items[i]) and resp.getInt(2) == @as(i64, @intCast(i)), "dyn BIDI: item");
            }
        } else {
            util.checkFmt(false, "unknown scenario kind: {s}", .{c.kind});
        }
    }
}
