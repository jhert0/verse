const std = @import("std");
const Allocator = std.mem.Allocator;

const Verse = @import("verse.zig");
const Router = @import("router.zig");

pub const Server = @This();

pub const zWSGI = @import("zwsgi.zig");
pub const Http = @import("http.zig");

alloc: Allocator,
router: Router,
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
    zwsgi: zWSGI.Options = .{},
    http: Http.Options = .{},
};

pub fn init(a: Allocator, runmode: RunMode, router: Router, opts: Options) !Server {
    return .{
        .alloc = a,
        .router = router,
        .interface = switch (runmode) {
            .unix => .{ .unix = zWSGI.init(a, opts.zwsgi, router) },
            .http => .{ .http = try Http.init(a, opts.http, router) },
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
