const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const AnyWriter = std.io.AnyWriter;
const Stream = std.net.Stream;

const Request = @import("request.zig");
const Headers = @import("headers.zig");
const Cookies = @import("cookies.zig");

const Response = @This();

const ONESHOT_SIZE = 14720;

const Pair = struct {
    name: []const u8,
    val: []const u8,
};

pub const TransferMode = enum {
    static,
    streaming,
    proxy,
    proxy_streaming,
};

const Downstream = enum {
    buffer,
    zwsgi,
    http,
};

const Error = error{
    WrongPhase,
    HeadersFinished,
    ResponseClosed,
    UnknownStatus,
};

pub const Writer = std.io.Writer(*Response, Error, write);

alloc: Allocator,
headers: Headers,
tranfer_mode: TransferMode = .static,
// This is just bad code, but I need to give the sane implementation more thought
stdhttp: struct {
    request: ?*std.http.Server.Request = null,
    response: ?std.http.Server.Response = null,
} = .{},
downstream: union(Downstream) {
    buffer: std.io.BufferedWriter(ONESHOT_SIZE, Stream.Writer),
    zwsgi: Stream.Writer,
    http: std.io.AnyWriter,
},
cookie_jar: Cookies.Jar,
status: ?std.http.Status = null,

pub fn init(a: Allocator, req: *const Request) !Response {
    var self = Response{
        .alloc = a,
        .headers = Headers.init(a),
        .downstream = switch (req.raw) {
            .zwsgi => |z| .{ .zwsgi = z.*.acpt.stream.writer() },
            .http => .{ .http = undefined },
        },
        .cookie_jar = try Cookies.Jar.init(a),
    };
    switch (req.raw) {
        .http => |h| {
            self.stdhttp.request = h;
        },
        else => {},
    }
    self.headersInit() catch @panic("unable to create Response obj");
    return self;
}

fn headersInit(res: *Response) !void {
    try res.headersAdd("Server", "zwsgi/0.0.0");
    try res.headersAdd("Content-Type", "text/html; charset=utf-8"); // Firefox is trash
}

pub fn headersAdd(res: *Response, comptime name: []const u8, value: []const u8) !void {
    try res.headers.add(name, value);
}

pub fn writer(res: *const Response) AnyWriter {
    return .{
        .writeFn = typeErasedWrite,
        .context = @ptrCast(&res),
    };
}

pub fn writeChunk(res: Response, data: []const u8) !void {
    comptime unreachable;
    var size: [19]u8 = undefined;
    const chunk = try bufPrint(&size, "{x}\r\n", .{data.len});
    try res.writeAll(chunk);
    try res.writeAll(data);
    try res.writeAll("\r\n");
}

pub fn writeAll(res: Response, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        index += try write(res, data[index..]);
    }
}

pub fn typeErasedWrite(opq: *const anyopaque, data: []const u8) anyerror!usize {
    const ptr: *const Response = @alignCast(@ptrCast(opq));
    return try write(ptr.*, data);
}

/// Raw writer, use with caution! To use phase checking, use send();
pub fn write(res: Response, data: []const u8) !usize {
    return switch (res.downstream) {
        .zwsgi => |*w| try w.write(data),
        .http => |*w| return try w.write(data),
        .buffer => return try res.write(data),
    };
}

fn flush(res: Response) !void {
    switch (res.downstream) {
        .buffer => |*w| try w.flush(),
        .http => |*h| h.flush(),
        else => {},
    }
}

pub fn finish(res: *Response) !void {
    switch (res.downstream) {
        .http => {
            if (res.stdhttp.response) |*h| try h.endChunked(.{});
        },
        else => {},
    }
}
