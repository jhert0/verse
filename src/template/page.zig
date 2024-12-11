const Templates = @import("../template.zig");
const Template = Templates.Template;
const Directive = Templates.Directive;

const Offset = struct { usize, usize };

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
            index += offset;
            if (Directive.init(pblob)) |drct| {
                const end = drct.tag_block.len;
                found_offsets = found_offsets ++ [_]Offset{.{ index, index + end }};
                pblob = pblob[end..];
                index += end;
            } else {
                if (indexOfPosLinear(u8, pblob, 1, "<")) |next| {
                    index += next;
                    pblob = pblob[next..];
                } else break;
            }
        } else break;
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
            //std.debug.print("data offsets {any}\n", .{Self.DataOffsets});
            const blob = Self.PageTemplate.blob;
            if (Self.DataOffsets.len == 0)
                return try out.writeAll(blob);

            for (Self.DataOffsets) |offs| {
                const start = offs[0];
                const end = offs[0];
                try out.writeAll(blob[0..start]);
                //blob = blob[start..];

                if (Directive.init(blob[start..])) |drct| {
                    drct.formatTyped(PageDataType, self.data, out) catch |err| switch (err) {
                        error.IgnoreDirective => try out.writeAll(blob[start..end]),
                        error.VariableMissing => {
                            if (!is_test) log.err("Template Error, variable missing {{{s}}}", .{blob[start..end]});
                            try out.writeAll(blob[start..end]);
                        },
                        else => return err,
                    };

                    //blob = blob[end..];
                } else {
                    std.debug.print("init failed ?\n", .{});
                    try out.writeAll(blob[end..]);
                }
                continue;
            } else {
                const last_end = Self.DataOffsets[Self.DataOffsets.len - 1][1];
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
