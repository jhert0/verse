const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.Verse);
const Server = std.http.Server;

const Verse = @import("verse.zig");
const Router = @import("router.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");
const RequestData = @import("request_data.zig");

const MAX_HEADER_SIZE = 1 <<| 13;

pub const HTTP = @This();

alloc: Allocator,
listen_addr: std.net.Address,
router: Router,
max_request_size: usize = 0xffff,

pub fn init(a: Allocator, host: []const u8, port: u16, router: Router) !HTTP {
    return .{
        .alloc = a,
        .listen_addr = try std.net.Address.parseIp(host, port),
        .router = router,
    };
}

pub fn serve(http: *HTTP) !void {
    var srv = try http.listen_addr.listen(.{ .reuse_address = true });
    defer srv.deinit();
    log.warn("HTTP Server listening", .{});

    const request_buffer: []u8 = try http.alloc.alloc(u8, http.max_request_size);
    defer http.alloc.free(request_buffer);

    while (true) {
        var conn = try srv.accept();
        defer conn.stream.close();
        log.info("HTTP connection from {}", .{conn.address});
        var hsrv = std.http.Server.init(conn, request_buffer);
        var arena = std.heap.ArenaAllocator.init(http.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var hreq = try hsrv.receiveHead();

        var ctx = try buildVerse(a, &hreq);
        var ipbuf: [0x20]u8 = undefined;
        const ipport = try std.fmt.bufPrint(&ipbuf, "{}", .{conn.address});
        if (std.mem.indexOfScalar(u8, ipport, ':')) |i| {
            try ctx.request.addHeader("REMOTE_ADDR", ipport[0..i]);
            try ctx.request.addHeader("REMOTE_PORT", ipport[i + 1 ..]);
        } else unreachable;

        const callable = try http.router.routefn(&ctx);
        http.router.buildfn(&ctx, callable) catch |err| {
            switch (err) {
                error.NetworkCrash => std.debug.print("client disconnect'\n", .{}),
                error.Unrouteable => {
                    std.debug.print("Unrouteable'\n", .{});
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
                    log.err("Unexpected error '{}'\n", .{err});
                    return err;
                },
                error.InvalidURI => unreachable,
                error.OutOfMemory => {
                    log.err("Out of memory at '{}'\n", .{arena.queryCapacity()});
                    return err;
                },
                error.Abusive,
                error.Unauthenticated,
                error.BadData,
                error.DataMissing,
                => {
                    log.err("Abusive {} because {}\n", .{ ctx.request, err });
                    for (ctx.request.raw_request.zwsgi.vars) |vars| {
                        log.err("Abusive var '{s}' => '''{s}'''\n", .{ vars.key, vars.val });
                    }
                },
            }
        };
    }
    unreachable;
}

fn readHttpHeaders(a: Allocator, req: *std.http.Server.Request) !Request {
    //const vars = try readVars(a, buf);

    var itr_headers = req.iterateHeaders();
    while (itr_headers.next()) |header| {
        log.debug("http header => {s} -> {s}\n", .{ header.name, header.value });
        log.debug("{}", .{header});
    }

    return try Request.init(a, req);
}

// TODO refactor
const zwsgi = @import("zwsgi.zig");

fn buildVerse(a: Allocator, req: *std.http.Server.Request) !Verse {
    var request = try readHttpHeaders(a, req);
    log.debug("http target -> {s}\n", .{request.uri});
    return zwsgi.buildVerse(a, &request);
}
