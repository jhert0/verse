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

pub const Options = struct {
    file: []const u8 = "./zwsgi_file.sock",
};

pub fn init(a: Allocator, opts: Options, router: Router) zWSGI {
    return .{
        .alloc = a,
        .unix_file = opts.file,
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

        var zreq = try readHeader(a, &acpt);
        var request = try Request.init(a, &zreq);
        var verse = try buildVerse(a, &request);

        defer {
            const vars = verse.request.raw.zwsgi.vars;
            log.err("zWSGI: [{d:.3}] {s} - {s}: {s} -- \"{s}\"", .{
                @as(f64, @floatFromInt(timer.lap())) / 1000000.0,
                findOr(vars, "REMOTE_ADDR"),
                findOr(vars, "REQUEST_METHOD"),
                findOr(vars, "REQUEST_URI"),
                findOr(vars, "HTTP_USER_AGENT"),
            });
        }

        const callable = z.router.routerfn(&verse, z.router.routefn);
        z.router.builderfn(&verse, callable);
    }
}

pub const zWSGIRequest = struct {
    acpt: *net.Server.Connection,
    header: uProtoHeader = uProtoHeader{},
    vars: []uWSGIVar = &[0]uWSGIVar{},
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

fn readHeader(a: Allocator, conn: *net.Server.Connection) !zWSGIRequest {
    var uwsgi_header = uProtoHeader{};
    var ptr: [*]u8 = @ptrCast(&uwsgi_header);
    _ = try conn.stream.read(@alignCast(ptr[0..4]));

    const buf: []u8 = try a.alloc(u8, uwsgi_header.size);
    const read = try conn.stream.read(buf);
    if (read != uwsgi_header.size) {
        std.log.err("unexpected read size {} {}", .{ read, uwsgi_header.size });
    }

    const vars = try readVars(a, buf);
    for (vars) |v| {
        log.debug("{}", .{v});
    }

    return .{
        .acpt = conn,
        .header = uwsgi_header,
        .vars = vars,
    };
}

fn buildVerse(a: Allocator, req: *Request) !Verse {
    var post_data: ?RequestData.PostData = null;
    var reqdata: RequestData = undefined;

    if (find(req.raw.zwsgi.vars, "HTTP_CONTENT_LENGTH")) |h_len| {
        const h_type = findOr(req.raw.zwsgi.vars, "HTTP_CONTENT_TYPE");

        const post_size = try std.fmt.parseInt(usize, h_len, 10);
        if (post_size > 0) {
            var reader = req.raw.zwsgi.acpt.stream.reader().any();
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
    if (find(req.raw.zwsgi.vars, "QUERY_STRING")) |qs| {
        query = try RequestData.readQuery(a, qs);
    }
    reqdata = RequestData{
        .post = post_data,
        .query = query,
    };

    const response = try Response.init(a, req);
    return Verse.init(a, req, response, reqdata);
}
