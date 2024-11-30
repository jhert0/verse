const std = @import("std");
const log = std.log.scoped(.Verse);
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
pub const UriIter = std.mem.SplitIterator(u8, .scalar);

const Verse = @import("verse.zig");

const Request = @import("request.zig");
const StaticFile = @import("static-file.zig");

pub const Errors = @import("errors.zig");
pub const Error = Errors.ServerError || Errors.ClientError || Errors.NetworkError;

pub const RouteFn = *const fn (*Verse) Error!BuildFn;
pub const BuildFn = *const fn (*Verse) Error!void;
pub const PrepareFn = *const fn (*Verse, BuildFn) Error!void;

pub const Router = @This();

routefn: RouteFn,
// TODO better naming
buildfn: PrepareFn = basePrepare,

/// Methods is a struct so bitwise or will work as expected
pub const Methods = packed struct {
    GET: bool = false,
    HEAD: bool = false,
    POST: bool = false,
    PUT: bool = false,
    DELETE: bool = false,
    CONNECT: bool = false,
    OPTIONS: bool = false,
    TRACE: bool = false,

    pub fn matchMethod(self: Methods, req: Request.Methods) bool {
        return switch (req) {
            .GET => self.GET,
            .HEAD => self.HEAD,
            .POST => self.POST,
            .PUT => self.PUT,
            .DELETE => self.DELETE,
            .CONNECT => self.CONNECT,
            .OPTIONS => self.OPTIONS,
            .TRACE => self.TRACE,
        };
    }
};

pub const Endpoint = struct {
    builder: BuildFn,
    methods: Methods = .{ .GET = true },
};

pub const Match = struct {
    name: []const u8,
    match: union(enum) {
        build: BuildFn,
        route: RouteFn,
        simple: []const Match,
    },
    methods: Methods = .{ .GET = true },
};

pub fn ROUTE(comptime name: []const u8, comptime match: anytype) Match {
    return comptime Match{
        .name = name,
        .match = switch (@typeInfo(@TypeOf(match))) {
            .Pointer => |ptr| switch (@typeInfo(ptr.child)) {
                .Fn => |fnc| switch (fnc.return_type orelse null) {
                    Error!void => .{ .build = match },
                    Error!BuildFn => .{ .route = match },
                    else => @compileError("unknown function return type"),
                },
                else => .{ .simple = match },
            },
            .Fn => |fnc| switch (fnc.return_type orelse null) {
                Error!void => .{ .build = match },
                Error!BuildFn => .{ .route = match },
                else => @compileError("unknown function return type"),
            },
            else => |el| @compileError("match type not supported, for provided type [" ++
                @typeName(@TypeOf(el)) ++
                "]"),
        },

        .methods = .{ .GET = true, .POST = true },
    };
}

pub fn any(comptime name: []const u8, comptime match: BuildFn) Match {
    var mr = ROUTE(name, match);
    mr.methods = .{ .GET = true, .POST = true };
    return mr;
}

pub fn GET(comptime name: []const u8, comptime match: BuildFn) Match {
    var mr = ROUTE(name, match);
    mr.methods = .{ .GET = true };
    return mr;
}

pub fn POST(comptime name: []const u8, comptime match: BuildFn) Match {
    var mr = ROUTE(name, match);
    mr.methods = .{ .POST = true };
    return mr;
}

pub fn STATIC(comptime name: []const u8) Match {
    var mr = ROUTE(name, StaticFile.fileOnDisk);
    mr.methods = .{ .GET = true };
    return mr;
}

pub fn defaultResponse(comptime code: std.http.Status) BuildFn {
    return switch (code) {
        .not_found => notFound,
        .internal_server_error => internalServerError,
        else => default,
    };
}

fn notFound(vrs: *Verse) Error!void {
    vrs.response.status = .not_found;
    const E4XX = @embedFile("fallback_html/4XX.html");
    return vrs.sendRawSlice(E4XX);
}

fn internalServerError(vrs: *Verse) Error!void {
    vrs.response.status = .internal_server_error;
    const E5XX = @embedFile("fallback_html/5XX.html");
    return vrs.sendRawSlice(E5XX);
}

fn default(vrs: *Verse) Error!void {
    const index = @embedFile("fallback_html/index.html");
    return vrs.sendRawSlice(index);
}

pub fn router(vrs: *Verse, comptime routes: []const Match) BuildFn {
    const search = vrs.uri.peek() orelse {
        log.warn("No endpoint found: URI is empty.", .{});
        return notFound;
    };
    inline for (routes) |ep| {
        if (eql(u8, search, ep.name)) {
            switch (ep.match) {
                .build => |call| {
                    if (ep.methods.matchMethod(vrs.request.method))
                        return call;
                },
                .route => |route| {
                    return route(vrs) catch |err| switch (err) {
                        error.Unrouteable => return notFound,
                        else => unreachable,
                    };
                },
                .simple => |simple| {
                    _ = vrs.uri.next();
                    if (vrs.uri.peek() == null and
                        eql(u8, simple[0].name, "") and
                        simple[0].match == .build)
                        return simple[0].match.build;
                    return router(vrs, simple);
                },
            }
        }
    }
    return notFound;
}

const root = [_]Match{
    ROUTE("", default),
};

pub fn basePrepare(vrs: *Verse, build: BuildFn) Error!void {
    return build(vrs);
}

pub fn baseRouter(vrs: *Verse) Error!void {
    log.debug("baserouter {s}", .{vrs.uri.peek().?});
    if (vrs.uri.peek()) |first| {
        if (first.len > 0) {
            const route: BuildFn = router(vrs, &root);
            return route(vrs);
        }
    }
    return default(vrs);
}

const root_with_static = root ++
    [_]Match{.{ .name = "static", .match = .{ .call = StaticFile.file } }};

pub fn baseRouterHtml(vrs: *Verse) Error!void {
    log.debug("baserouter {s}\n", .{vrs.uri.peek().?});
    if (vrs.uri.peek()) |first| {
        if (first.len > 0) {
            const route: BuildFn = router(vrs, &root_with_static);
            return route(vrs);
        }
    }
    return default(vrs);
}
