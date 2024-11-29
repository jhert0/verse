pub const std = @import("std");
const Allocator = std.mem.Allocator;
const splitScalar = std.mem.splitScalar;

pub const zWSGI = @import("zwsgi.zig");
//const Auth = @import("auth.zig");

pub const zWSGIRequest = zWSGI.zWSGIRequest;

pub const Request = @import("request.zig");
pub const Response = @import("response.zig");
pub const RequestData = @import("request_data.zig");
pub const Template = @import("template.zig");
pub const HTML = @import("html.zig");
pub const DOM = @import("dom.zig");
pub const Router = @import("router.zig");
pub const UriIter = Router.UriIter;

pub const Ini = @import("ini.zig");
pub const Config = Ini.Config;

const Error = @import("errors.zig").Error;

pub const Verse = @This();

alloc: Allocator,
request: Request,
response: Response,
reqdata: RequestData,
uri: UriIter,
cfg: ?Config,

// TODO fix this unstable API
auth: Auth,
route_ctx: ?*const anyopaque = null,

pub const Auth = struct {
    user: User = User{},

    pub const User = struct {
        username: []const u8 = "invalid username",
    };

    pub fn valid(a: Auth) bool {
        _ = a;
        return true;
    }

    pub fn validOrError(a: Auth) !void {
        if (!a.valid()) return error.Unauthenticated;
    }

    pub fn currentUser(a: Auth, alloc: Allocator) !User {
        _ = alloc;
        return a.user;
    }
};

const VarPair = struct {
    []const u8,
    []const u8,
};

pub fn init(a: Allocator, cfg: ?Config, req: Request, res: Response, reqdata: RequestData) !Verse {
    std.debug.assert(req.uri[0] == '/');
    //const reqheader = req.headers
    return .{
        .alloc = a,
        .request = req,
        .response = res,
        .reqdata = reqdata,
        .uri = splitScalar(u8, req.uri[1..], '/'),
        .cfg = cfg,
        .auth = Auth{},
    };
}

pub fn sendPage(ctx: *Verse, page: anytype) Error!void {
    ctx.response.start() catch |err| switch (err) {
        error.BrokenPipe => return error.NetworkCrash,
        else => unreachable,
    };
    const loggedin = if (ctx.auth.valid()) "<a href=\"#\">Logged In</a>" else "Public";
    const T = @TypeOf(page.*);
    if (@hasField(T, "data") and @hasField(@TypeOf(page.data), "body_header")) {
        page.data.body_header.?.nav.?.nav_auth = loggedin;
    }

    const writer = ctx.response.writer();
    page.format("{}", .{}, writer) catch |err| switch (err) {
        else => std.debug.print("Page Build Error {}\n", .{err}),
    };
}

pub fn sendRawSlice(ctx: *Verse, slice: []const u8) Error!void {
    ctx.response.send(slice) catch unreachable;
}

pub fn sendError(ctx: *Verse, comptime code: std.http.Status) Error!void {
    return Router.defaultResponse(code)(ctx);
}

pub fn sendJSON(ctx: *Verse, json: anytype) Error!void {
    ctx.response.start() catch |err| switch (err) {
        error.BrokenPipe => return error.NetworkCrash,
        else => unreachable,
    };

    const data = std.json.stringifyAlloc(ctx.alloc, json, .{
        .emit_null_optional_fields = false,
    }) catch |err| {
        std.debug.print("Error trying to print json {}\n", .{err});
        return error.Unknown;
    };
    ctx.response.writeAll(data) catch unreachable;
    ctx.response.finish() catch unreachable;
}
