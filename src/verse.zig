pub const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const splitScalar = std.mem.splitScalar;
const log = std.log.scoped(.Verse);

pub const Server = @import("server.zig");

pub const Request = @import("request.zig");
pub const Response = @import("response.zig");
pub const RequestData = @import("request_data.zig");
pub const Template = @import("template.zig");
pub const Router = @import("router.zig");
pub const UriIter = Router.UriIter;

pub const Auth = @import("auth.zig");
pub const Cookies = @import("cookies.zig");

const Error = @import("errors.zig").Error;
const NetworkError = @import("errors.zig").NetworkError;

pub const Verse = @This();

alloc: Allocator,
request: *const Request,
response: Response,
reqdata: RequestData,
uri: UriIter,

// TODO fix this unstable API
auth: Auth,
route_ctx: ?*const anyopaque = null,

const VarPair = struct {
    []const u8,
    []const u8,
};

pub fn init(a: Allocator, req: *const Request, res: Response, reqdata: RequestData) !Verse {
    std.debug.assert(req.uri[0] == '/');
    return .{
        .alloc = a,
        .request = req,
        .response = res,
        .reqdata = reqdata,
        .uri = splitScalar(u8, req.uri[1..], '/'),
        .auth = Auth{
            .provider = Auth.InvalidProvider.empty(),
        },
    };
}

fn sendHTTPHeader(vrs: *Verse) !void {
    if (vrs.response.status == null) vrs.response.status = .ok;
    switch (vrs.response.status.?) {
        .ok => try vrs.response.writeAll("HTTP/1.1 200 OK\r\n"),
        .found => try vrs.response.writeAll("HTTP/1.1 302 Found\r\n"),
        .forbidden => try vrs.response.writeAll("HTTP/1.1 403 Forbidden\r\n"),
        .not_found => try vrs.response.writeAll("HTTP/1.1 404 Not Found\r\n"),
        .internal_server_error => try vrs.response.writeAll("HTTP/1.1 500 Internal Server Error\r\n"),
        else => return error.UnknownStatus,
    }
}

pub fn sendHeaders(vrs: *Verse) !void {
    switch (vrs.response.downstream) {
        .http => try vrs.response.stdhttp.response.?.flush(),
        .zwsgi, .buffer => {
            try vrs.sendHTTPHeader();
            var itr = vrs.response.headers.headers.iterator();
            while (itr.next()) |header| {
                var buf: [512]u8 = undefined;
                const b = try std.fmt.bufPrint(&buf, "{s}: {s}\r\n", .{
                    header.key_ptr.*,
                    header.value_ptr.*.value,
                });
                _ = try vrs.response.write(b);
            }
            _ = try vrs.response.write("Transfer-Encoding: chunked\r\n");
        },
    }
}

pub fn redirect(vrs: *Verse, loc: []const u8, see_other: bool) !void {
    try vrs.response.writeAll("HTTP/1.1 ");
    if (see_other) {
        try vrs.response.writeAll("303 See Other\r\n");
    } else {
        try vrs.response.writeAll("302 Found\r\n");
    }

    try vrs.response.writeAll("Location: ");
    try vrs.response.writeAll(loc);
    try vrs.response.writeAll("\r\n\r\n");
}

/// sendPage is the default way to respond in verse using the Template system.
/// sendPage will flush headers to the client before sending Page data
pub fn sendPage(vrs: *Verse, page: anytype) NetworkError!void {
    try vrs.quickStart();
    const loggedin = if (vrs.auth.valid()) "<a href=\"#\">Logged In</a>" else "Public";
    const T = @TypeOf(page.*);
    if (@hasField(T, "data") and @hasField(@TypeOf(page.data), "body_header")) {
        page.data.body_header.?.nav.?.nav_auth = loggedin;
    }

    const writer = vrs.response.writer();
    page.format("{}", .{}, writer) catch |err| switch (err) {
        else => log.err("Page Build Error {}", .{err}),
    };
    return vrs.finish();
}

/// sendRawSlice will allow you to send data directly to the client. It will not
/// verify the current state, and will allow you to inject data into the HTTP
/// headers. If you only want to send response body data, call quickStart() to
/// send all headers to the client
pub fn sendRawSlice(vrs: *Verse, slice: []const u8) NetworkError!void {
    vrs.response.writeAll(slice) catch |err| switch (err) {
        error.BrokenPipe => |e| return e,
        else => unreachable,
    };
}

/// Helper function to return a default error page for a given http status code.
pub fn sendError(vrs: *Verse, comptime code: std.http.Status) !void {
    return Router.defaultResponse(code)(vrs);
}

/// Takes a any object, that can be represented by json, converts it into a
/// json string, and sends to the client.
pub fn sendJSON(vrs: *Verse, json: anytype) !void {
    try vrs.quickStart();
    const data = std.json.stringifyAlloc(vrs.alloc, json, .{
        .emit_null_optional_fields = false,
    }) catch |err| {
        log.err("Error trying to print json {}", .{err});
        return error.Unknown;
    };
    vrs.response.writeAll(data) catch |err| switch (err) {
        error.BrokenPipe => |e| return e,
        else => unreachable,
    };
    return vrs.finish();
}

/// This function may be removed in the future
pub fn quickStart(vrs: *Verse) NetworkError!void {
    if (vrs.response.status == null) vrs.response.status = .ok;

    switch (vrs.response.downstream) {
        .http => {
            vrs.response.stdhttp.response = vrs.response.stdhttp.request.?.*.respondStreaming(.{
                .send_buffer = vrs.response.alloc.alloc(u8, 0xffffff) catch unreachable,
                .respond_options = .{
                    .transfer_encoding = .chunked,
                    .keep_alive = false,
                    .extra_headers = @ptrCast(vrs.response.cookie_jar.toHeaderSlice(vrs.response.alloc) catch unreachable),
                },
            });

            // I don't know why/where the writer goes invalid, but I'll probably
            // fix it later?
            if (vrs.response.stdhttp.response) |*h| vrs.response.downstream.http = h.writer();

            vrs.sendHeaders() catch |err| switch (err) {
                error.BrokenPipe => |e| return e,
                else => unreachable,
            };
        },
        else => {
            vrs.sendHeaders() catch |err| switch (err) {
                error.BrokenPipe => |e| return e,
                else => unreachable,
            };

            for (vrs.response.cookie_jar.cookies.items) |cookie| {
                var buffer: [1024]u8 = undefined;
                const cookie_str = bufPrint(&buffer, "{header}\r\n", .{cookie}) catch unreachable;
                _ = vrs.response.write(cookie_str) catch |err| switch (err) {
                    error.BrokenPipe => |e| return e,
                    else => unreachable,
                };
            }

            _ = vrs.response.write("\r\n") catch |err| switch (err) {
                error.BrokenPipe => |e| return e,
                else => unreachable,
            };
        },
    }
}

// TODO: remove this function?
/// Finish sending response, this is only necessary if using sendRawSlice in http mode.
pub fn finish(vrs: *Verse) NetworkError!void {
    vrs.response.finish() catch |err| switch (err) {
        error.BrokenPipe => |e| return e,
        else => unreachable,
    };
}

test "Verse" {
    std.testing.refAllDecls(@This());
}
