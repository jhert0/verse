const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.Verse);
const net = std.net;

const Verse = @import("verse.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("router.zig");
const RequestData = @import("request_data.zig");

pub const zWSGI = @This();

alloc: Allocator,
unix_file: []const u8,
router: Router,

pub fn init(a: Allocator, file: []const u8, router: Router) zWSGI {
    return .{
        .alloc = a,
        .unix_file = file,
        .router = router,
    };
}

pub fn serve(z: *zWSGI) !void {
    var cwd = std.fs.cwd();
    if (cwd.access(z.unix_file, .{})) {
        try cwd.deleteFile(z.unix_file);
    } else |_| {}

    const uaddr = try std.net.Address.initUnix(z.unix_file);
    var server = try uaddr.listen(.{});
    defer server.deinit();

    const path = try std.fs.cwd().realpathAlloc(z.alloc, z.unix_file);
    defer z.alloc.free(path);
    const zpath = try z.alloc.dupeZ(u8, path);
    defer z.alloc.free(zpath);
    const mode = std.os.linux.chmod(zpath, 0o777);
    if (false) std.debug.print("mode {o}\n", .{mode});
    log.warn("Unix server listening\n", .{});

    while (true) {
        var acpt = try server.accept();
        defer acpt.stream.close();
        var timer = try std.time.Timer.start();

        var arena = std.heap.ArenaAllocator.init(z.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var ctx = try buildVerseuWSGI(a, &acpt);

        defer {
            log.err("zWSGI: [{d:.3}] {s} - {s}: {s} -- \"{s}\"", .{
                @as(f64, @floatFromInt(timer.lap())) / 1000000.0,
                findOr(ctx.request.raw_request.zwsgi.vars, "REMOTE_ADDR"),
                findOr(ctx.request.raw_request.zwsgi.vars, "REQUEST_METHOD"),
                findOr(ctx.request.raw_request.zwsgi.vars, "REQUEST_URI"),
                findOr(ctx.request.raw_request.zwsgi.vars, "HTTP_USER_AGENT"),
            });
        }

        const callable = try z.router.routefn(&ctx);
        z.router.buildfn(&ctx, callable) catch |err| {
            switch (err) {
                error.NetworkCrash => log.err("client disconnect", .{}),
                error.Unrouteable => {
                    log.err("Unrouteable", .{});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                },
                error.NotImplemented,
                error.Unknown,
                error.ReqResInvalid,
                error.AndExit,
                error.NoSpaceLeft,
                => {
                    log.err("Unexpected error '{}'", .{err});
                    return err;
                },
                error.InvalidURI => unreachable,
                error.OutOfMemory => {
                    log.err("Out of memory at '{}'", .{arena.queryCapacity()});
                    return err;
                },
                error.Abusive,
                error.Unauthenticated,
                error.BadData,
                error.DataMissing,
                => {
                    log.err("Abusive {} because {}", .{ ctx.request, err });
                    for (ctx.request.raw_request.zwsgi.vars) |vars| {
                        log.err("Abusive var '{s}' => '''{s}'''", .{ vars.key, vars.val });
                    }
                    if (ctx.reqdata.post) |post_data| {
                        log.err("post data => '''{s}'''", .{post_data.rawpost});
                    }
                },
            }
        };
    }
}

pub const zWSGIRequest = struct {
    header: uProtoHeader,
    acpt: net.Server.Connection,
    vars: []uWSGIVar,
    body: ?[]u8 = null,
};

fn readU16(b: *const [2]u8) u16 {
    std.debug.assert(b.len >= 2);
    return @as(u16, @bitCast(b[0..2].*));
}

test "readu16" {
    const buffer = [2]u8{ 238, 1 };
    const size: u16 = 494;
    try std.testing.expectEqual(size, readU16(&buffer));
}

fn readVars(a: Allocator, b: []const u8) ![]uWSGIVar {
    var list = std.ArrayList(uWSGIVar).init(a);
    var buf = b;
    while (buf.len > 0) {
        const keysize = readU16(buf[0..2]);
        buf = buf[2..];
        const key = try a.dupe(u8, buf[0..keysize]);
        buf = buf[keysize..];

        const valsize = readU16(buf[0..2]);
        buf = buf[2..];
        const val = try a.dupe(u8, if (valsize == 0) "" else buf[0..valsize]);
        buf = buf[valsize..];

        try list.append(uWSGIVar{
            .key = key,
            .val = val,
        });
    }
    return try list.toOwnedSlice();
}

const uProtoHeader = packed struct {
    mod1: u8 = 0,
    size: u16 = 0,
    mod2: u8 = 0,
};

const uWSGIVar = struct {
    key: []const u8,
    val: []const u8,

    pub fn read(_: []u8) uWSGIVar {
        return uWSGIVar{ .key = "", .val = "" };
    }

    pub fn format(self: uWSGIVar, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try std.fmt.format(out, "\"{s}\" = \"{s}\"", .{
            self.key,
            if (self.val.len > 0) self.val else "[Empty]",
        });
    }
};

fn find(list: []uWSGIVar, search: []const u8) ?[]const u8 {
    for (list) |each| {
        if (std.mem.eql(u8, each.key, search)) return each.val;
    }
    return null;
}

fn findOr(list: []uWSGIVar, search: []const u8) []const u8 {
    return find(list, search) orelse "[missing]";
}

pub fn buildVerse(a: Allocator, request: *Request) !Verse {
    var post_data: ?RequestData.PostData = null;
    var reqdata: RequestData = undefined;
    switch (request.raw_request) {
        .zwsgi => |zreq| {
            if (find(zreq.vars, "HTTP_CONTENT_LENGTH")) |h_len| {
                const h_type = findOr(zreq.vars, "HTTP_CONTENT_TYPE");

                const post_size = try std.fmt.parseInt(usize, h_len, 10);
                if (post_size > 0) {
                    var reader = zreq.acpt.stream.reader().any();
                    post_data = try RequestData.readBody(a, &reader, post_size, h_type);
                    log.debug(
                        "post data \"{s}\" {{{any}}}",
                        .{ post_data.?.rawpost, post_data.?.rawpost },
                    );

                    for (post_data.?.items) |itm| {
                        log.debug("{}", .{itm});
                    }
                }
            }

            var query: RequestData.QueryData = undefined;
            if (find(zreq.vars, "QUERY_STRING")) |qs| {
                query = try RequestData.readQuery(a, qs);
            }
            reqdata = RequestData{
                .post = post_data,
                .query = query,
            };
        },
        .http => |hreq| {
            if (hreq.head.content_length) |h_len| {
                if (h_len > 0) {
                    const h_type = hreq.head.content_type orelse "text/plain";
                    var reader = try hreq.reader();
                    post_data = try RequestData.readBody(a, &reader, h_len, h_type);
                    log.debug(
                        "post data \"{s}\" {{{any}}}",
                        .{ post_data.?.rawpost, post_data.?.rawpost },
                    );

                    for (post_data.?.items) |itm| {
                        log.debug("{}", .{itm});
                    }
                }
            }

            var query_data: RequestData.QueryData = undefined;
            if (std.mem.indexOf(u8, hreq.head.target, "/")) |i| {
                query_data = try RequestData.readQuery(a, hreq.head.target[i..]);
            }
            reqdata = RequestData{
                .post = post_data,
                .query = query_data,
            };
        },
    }

    const response = try Response.init(a, request);
    return Verse.init(a, null, request.*, response, reqdata);
}

fn readuWSGIHeader(a: Allocator, acpt: net.Server.Connection) !Request {
    var uwsgi_header = uProtoHeader{};
    var ptr: [*]u8 = @ptrCast(&uwsgi_header);
    _ = try acpt.stream.read(@alignCast(ptr[0..4]));

    const buf: []u8 = try a.alloc(u8, uwsgi_header.size);
    const read = try acpt.stream.read(buf);
    if (read != uwsgi_header.size) {
        std.log.err("unexpected read size {} {}", .{ read, uwsgi_header.size });
    }

    const vars = try readVars(a, buf);
    for (vars) |v| {
        log.debug("{}", .{v});
    }

    return try Request.init(
        a,
        zWSGIRequest{
            .header = uwsgi_header,
            .acpt = acpt,
            .vars = vars,
        },
    );
}

fn buildVerseuWSGI(a: Allocator, conn: *net.Server.Connection) !Verse {
    var request = try readuWSGIHeader(a, conn.*);

    return buildVerse(a, &request);
}
