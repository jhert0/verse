const std = @import("std");
const Verse = @import("verse.zig");
const Route = @import("router.zig");

pub fn fileOnDisk(vrs: *Verse) Route.Error!void {
    _ = vrs.uri.next(); // clear /static
    const fname = vrs.uri.next() orelse return error.Unrouteable;
    if (fname.len == 0) return error.Unrouteable;
    for (fname) |c| switch (c) {
        'A'...'Z', 'a'...'z', '-', '_', '.' => continue,
        else => return error.Abusive,
    };
    if (std.mem.indexOf(u8, fname, "/../")) |_| return error.Abusive;

    const static = std.fs.cwd().openDir("static", .{}) catch return error.Unrouteable;
    const fdata = static.readFileAlloc(vrs.alloc, fname, 0xFFFFFF) catch return error.Unknown;

    try vrs.quickStart();
    try vrs.sendRawSlice(fdata);
}
