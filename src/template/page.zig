const Templates = @import("../template.zig");
const Template = Templates.Template;
const Directive = Templates.Directive;

pub const Injector = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, []const u8) ?[]const u8,
};

pub fn PageRuntime(comptime PageDataType: type) type {
    return struct {
        pub const Self = @This();
        pub const Kind = PageDataType;
        template: Template,
        data: PageDataType,

        pub fn init(t: Template, d: PageDataType) PageRuntime(PageDataType) {
            return .{
                .template = t,
                .data = d,
            };
        }

        pub fn format(self: Self, comptime f: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
            return try self.format2(f, null, out);
        }

        pub fn format2(self: Self, comptime _: []const u8, injt: ?Injector, out: anytype) !void {
            //var ctx = self.data;
            var blob = self.template.blob;
            while (blob.len > 0) {
                if (indexOfScalar(u8, blob, '<')) |offset| {
                    try out.writeAll(blob[0..offset]);
                    blob = blob[offset..];
                    if (Directive.init(blob)) |drct| {
                        const end = drct.tag_block.len;
                        drct.formatTyped(PageDataType, self.data, injt, out) catch |err| switch (err) {
                            error.IgnoreDirective => try out.writeAll(blob[0..end]),
                            error.VariableMissing => {
                                if (injt) |inj| {
                                    if (inj.func(inj.ctx, blob[0..end])) |str| {
                                        try out.writeAll(str);
                                    } else {
                                        if (!is_test) log.err("Template Error, variable missing {{{s}}} Injection failed", .{blob[0..end]});
                                        try out.writeAll(blob[0..end]);
                                    }
                                } else {
                                    if (!is_test) log.err("Template Error, variable missing {{{s}}}", .{blob[0..end]});
                                    try out.writeAll(blob[0..end]);
                                }
                            },
                            else => return err,
                        };

                        blob = blob[end..];
                    } else {
                        if (std.mem.indexOfPos(u8, blob, 1, "<")) |next| {
                            try out.writeAll(blob[0..next]);
                            blob = blob[next..];
                        } else {
                            return try out.writeAll(blob);
                        }
                    }
                    continue;
                }
                return try out.writeAll(blob);
            }
        }
    };
}

pub fn Page(comptime template: Template, comptime PageDataType: type) type {
    return struct {
        pub const Self = @This();
        pub const Kind = PageDataType;
        pub const PageTemplate = template;
        data: PageDataType,

        pub fn init(d: PageDataType) Page(template, PageDataType) {
            return .{ .data = d };
        }

        pub fn format(self: Self, comptime f: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
            return try self.format2(f, null, out);
        }

        pub fn format2(self: Self, comptime _: []const u8, injt: ?Injector, out: anytype) !void {
            var blob = Self.PageTemplate.blob;
            while (blob.len > 0) {
                if (indexOfScalar(u8, blob, '<')) |offset| {
                    try out.writeAll(blob[0..offset]);
                    blob = blob[offset..];

                    if (Directive.init(blob)) |drct| {
                        const end = drct.tag_block.len;
                        drct.formatTyped(PageDataType, self.data, injt, out) catch |err| switch (err) {
                            error.IgnoreDirective => try out.writeAll(blob[0..end]),
                            error.VariableMissing => {
                                if (injt) |inj| {
                                    if (inj.func(inj.ctx, blob[0..end])) |str| {
                                        try out.writeAll(str);
                                    } else {
                                        if (!is_test) log.err("Template Error, variable missing {{{s}}} Injection failed", .{blob[0..end]});
                                        try out.writeAll(blob[0..end]);
                                    }
                                } else {
                                    if (!is_test) log.err("Template Error, variable missing {{{s}}}", .{blob[0..end]});
                                    try out.writeAll(blob[0..end]);
                                }
                            },
                            else => return err,
                        };

                        blob = blob[end..];
                    } else {
                        if (std.mem.indexOfPos(u8, blob, 1, "<")) |next| {
                            try out.writeAll(blob[0..next]);
                            blob = blob[next..];
                        } else {
                            return try out.writeAll(blob);
                        }
                    }
                    continue;
                }
                return try out.writeAll(blob);
            }
        }
    };
}

const std = @import("std");
const is_test = @import("builtin").is_test;
const Allocator = std.mem.Allocator;
const AnyWriter = std.io.AnyWriter;
const eql = std.mem.eql;
const indexOfScalar = std.mem.indexOfScalar;
const log = std.log.scoped(.Verse);
