pub const AuthZ = @import("authorization.zig");
pub const AuthN = @import("authentication.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Auth = @This();

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
