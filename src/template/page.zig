const Templates = @import("../template.zig");
const Template = Templates.Template;
const Directive = Templates.Directive;

const Kind = enum {
    slice,
    directive,
};

const Offset = struct {
    start: usize,
    end: usize,
    kind: Kind,
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

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
            //var ctx = self.data;
            var blob = self.template.blob;
            while (blob.len > 0) {
                if (indexOfScalar(u8, blob, '<')) |offset| {
                    try out.writeAll(blob[0..offset]);
                    blob = blob[offset..];
                    if (Directive.init(blob)) |drct| {
                        const end = drct.tag_block.len;
                        drct.formatTyped(PageDataType, self.data, out) catch |err| switch (err) {
                            error.IgnoreDirective => try out.writeAll(blob[0..end]),
                            error.VariableMissing => {
                                if (!is_test) log.err("Template Error, variable missing {{{s}}}", .{blob[0..end]});
                                try out.writeAll(blob[0..end]);
                            },
                            else => return err,
                        };

                        blob = blob[end..];
                    } else {
                        if (indexOfPosLinear(u8, blob, 1, "<")) |next| {
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
    @setEvalBranchQuota(5000);
    var found_offsets: []const Offset = &[0]Offset{};
    var pblob = template.blob;
    var index: usize = 0;
    // Originally attempted to write this just using index, but got catastrophic
    // backtracking errors when compiling. I'd have assumed this version would
    // be more expensive, but here we are :D
    while (pblob.len > 0) {
        if (indexOfScalar(u8, pblob, '<')) |offset| {
            pblob = pblob[offset..];
            if (index != offset and offset != 0) {
                found_offsets = found_offsets ++ [_]Offset{.{
                    .start = index,
                    .end = index + offset,
                    .kind = .slice,
                }};
            }
            index += offset;
            if (Directive.init(pblob)) |drct| {
                const end = drct.tag_block.len;
                found_offsets = found_offsets ++ [_]Offset{.{
                    .start = index,
                    .end = index + end,
                    .kind = .directive,
                }};
                pblob = pblob[end..];
                index += end;
            } else {
                if (indexOfPosLinear(u8, pblob, 1, "<")) |next| {
                    if (index != next) {
                        found_offsets = found_offsets ++ [_]Offset{.{
                            .start = index,
                            .end = index + next,
                            .kind = .slice,
                        }};
                    }
                    index += next;
                    pblob = pblob[next..];
                } else break;
            }
        } else break;
    }
    if (index != pblob.len) {
        found_offsets = found_offsets ++ [_]Offset{.{
            .start = index,
            .end = index + pblob.len,
            .kind = .slice,
        }};
    }
    const offset_len = found_offsets.len;
    const offsets: [offset_len]Offset = found_offsets[0..offset_len].*;

    return struct {
        pub const Self = @This();
        pub const Kind = PageDataType;
        pub const PageTemplate = template;
        pub const DataOffsets: [offset_len]Offset = offsets;
        data: PageDataType,

        pub fn init(d: PageDataType) Page(template, PageDataType) {
            return .{ .data = d };
        }

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
            //std.debug.print("offs {any}\n", .{Self.DataOffsets});
            const blob = Self.PageTemplate.blob;
            if (Self.DataOffsets.len == 0)
                return try out.writeAll(blob);

            var last_end: usize = 0;
            for (Self.DataOffsets) |os| {
                switch (os.kind) {
                    .slice => try out.writeAll(blob[os.start..os.end]),
                    .directive => {
                        if (Directive.init(blob[os.start..os.end])) |drct| {
                            drct.formatTyped(PageDataType, self.data, out) catch |err| switch (err) {
                                error.IgnoreDirective => try out.writeAll(blob[os.start..os.end]),
                                error.VariableMissing => {
                                    if (!is_test) log.err(
                                        "Template Error, variable missing {{{s}}}",
                                        .{blob[os.start..os.end]},
                                    );
                                    try out.writeAll(blob[os.start..os.end]);
                                },
                                else => return err,
                            };
                        } else {
                            std.debug.print("init failed ?\n", .{});
                            //try out.writeAll(blob[end..]);
                            unreachable;
                        }
                    },
                }
                last_end = os.end;
            } else {
                return try out.writeAll(blob[last_end..]);
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
const indexOfScalarPos = std.mem.indexOfScalarPos;
const indexOfPosLinear = std.mem.indexOfPosLinear;
const log = std.log.scoped(.Verse);
