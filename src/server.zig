const std = @import("std");
const Allocator = std.mem.Allocator;

const Verse = @import("verse.zig");
const Router = @import("router.zig");

/// Thin wrapper for zWSGI
pub const Server = @This();

pub const zWSGI = @import("zwsgi.zig");
pub const Http = @import("http.zig");

alloc: Allocator,
router: Router,
//runmode: RunMode,
interface: union(RunMode) {
    unix: zWSGI,
    http: Http,
    other: void,
},

pub const RunMode = enum {
    unix,
    http,
    other,
};

pub const Options = struct {
    file: []const u8 = "./zwsgi_file.sock",
    host: []const u8 = "127.0.0.1",
    port: u16 = 80,
};

pub fn init(a: Allocator, runmode: RunMode, router: Router, opts: Options) !Server {
    return .{
        .alloc = a,
        //.config = config,
        .router = router,
        .interface = switch (runmode) {
            .unix => .{ .unix = zWSGI.init(a, opts.file, router) },
            .http => .{ .http = try Http.init(a, opts.host, opts.port, router) },
            .other => unreachable,
        },
    };
}

pub fn serve(srv: *Server) !void {
    switch (srv.interface) {
        .unix => |*zw| try zw.serve(),
        .http => |*ht| try ht.serve(),
        else => {},
    }
}
