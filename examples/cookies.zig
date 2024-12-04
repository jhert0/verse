const std = @import("std");
const Verse = @import("verse");
const Router = Verse.Router;
const BuildFn = Router.BuildFn;
const print = std.fmt.bufPrint;

const routes = [_]Router.Match{
    Router.GET("", index),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var server = try Verse.Server.init(alloc, .{ .http = .{ .port = 8081 } }, .{ .routefn = route });

    server.serve() catch |err| {
        std.debug.print("error: {any}", .{err});
        std.posix.exit(1);
    };
}

fn route(verse: *Verse) Router.Error!BuildFn {
    return Verse.Router.router(verse, &routes);
}

fn index(verse: *Verse) Router.Error!void {
    var buffer: [2048]u8 = undefined;
    const found = try print(&buffer, "{} cookies found by the server\n", .{verse.request.cookie_jar.cookies.items.len});
    try verse.quickStart();
    try verse.sendRawSlice(found);
}
