const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;

const Request = @import("request.zig");
const Headers = @import("headers.zig");
const Cookies = @import("cookies.zig");

const Response = @This();

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

headers: Headers,
tranfer_mode: TransferMode = .static,
// This is just bad code, but I need to give the sane implementation more thought
stdhttp: struct {
    request: ?*std.http.Server.Request = null,
    response: ?std.http.Server.Response = null,
} = .{},
cookie_jar: Cookies.Jar,
status: ?std.http.Status = null,

pub fn init(a: Allocator, req: *const Request) !Response {
    var self = Response{
        .headers = Headers.init(a),
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
