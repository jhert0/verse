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
    kind: union(enum) {
        directive: Directive,
        slice: void,
    },
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

fn getOffset(T: type, name: []const u8) usize {
    var local: [0xff]u8 = undefined;
    const field = local[0..makeFieldName(name, &local)];
    return @offsetOf(T, field);
}

pub fn commentTag(blob: []const u8) ?usize {
    if (blob.len > 2 and blob[1] == '!' and blob.len > 4 and blob[2] == '-' and blob[3] == '-') {
        if (indexOfPosLinear(u8, blob, 4, "-->")) |comment| {
            return comment + 3;
        }
    }
    return null;
}

pub fn validateBlock(comptime html: []const u8, PageDataType: type) []const Offset {
    @setEvalBranchQuota(6000);
    var found_offsets: []const Offset = &[0]Offset{};
    var pblob = html;
    var index: usize = 0;
    var open_idx: usize = 0;
    // Originally attempted to write this just using index, but got catastrophic
    // backtracking errors when compiling. I'd have assumed this version would
    // be more expensive, but here we are :D
    while (pblob.len > 0) {
        if (indexOfScalar(u8, pblob, '<')) |offset| {
            pblob = pblob[offset..];
            index += offset;
            if (Directive.init(pblob)) |drct| {
                found_offsets = found_offsets ++ [_]Offset{.{
                    .start = open_idx,
                    .end = index,
                    .kind = .slice,
                }};

                const end = drct.tag_block.len;
                var os = Offset{
                    .start = index,
                    .end = index + end,
                    .kind = .{ .directive = drct },
                };
                if (drct.verb == .variable and PageDataType != void) {
                    os.kind.directive.known_offset = getOffset(PageDataType, drct.noun);
                }
                found_offsets = found_offsets ++ [_]Offset{os};
                pblob = pblob[end..];
                index += end;
                open_idx = index;
            } else if (commentTag(pblob)) |skip| {
                pblob = pblob[skip..];
                index += skip;
            } else {
                if (indexOfPosLinear(u8, pblob, 1, "<")) |next| {
                    pblob = pblob[next..];
                    index += next;
                } else break;
            }
        } else break;
    }
    if (index != pblob.len) {
        found_offsets = found_offsets ++ [_]Offset{.{
            .start = open_idx,
            .end = open_idx + pblob.len,
            .kind = .slice,
        }};
    }
    return found_offsets;
}

pub fn Page(comptime template: Template, comptime PageDataType: type) type {
    const offsets = validateBlock(template.blob, PageDataType);
    const offset_len = offsets.len;

    return struct {
        data: PageDataType,

        pub const Self = @This();
        pub const Kind = PageDataType;
        pub const PageTemplate = template;
        pub const DataOffsets: [offset_len]Offset = offsets[0..offset_len].*;

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
                    .directive => |directive| {
                        switch (directive.verb) {
                            .variable => {
                                if (directive.known_offset) |offset| {
                                    if (directive.known_type) |_| {
                                        directive.formatTyped(PageDataType, self.data, out) catch unreachable;
                                        continue;
                                    }

                                    const ptr: [*]const u8 = @ptrCast(&self.data);
                                    var vari: ?[]const u8 = null;
                                    switch (directive.otherwise) {
                                        .required => {
                                            vari = @as(*const []const u8, @ptrCast(@alignCast(&ptr[offset]))).*;
                                        },
                                        .delete => {
                                            vari = @as(*const ?[]const u8, @ptrCast(@alignCast(&ptr[offset]))).*;
                                        },
                                        .default => |default| {
                                            const sptr: *const ?[]const u8 = @ptrCast(@alignCast(&ptr[offset]));
                                            vari = if (sptr.*) |sp| sp else default;
                                        },
                                        else => unreachable,
                                    }
                                    if (vari) |v| {
                                        try out.writeAll(v);
                                    }
                                }
                            },
                            else => {
                                directive.formatTyped(PageDataType, self.data, out) catch |err| switch (err) {
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
                            },
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

const makeFieldName = Templates.makeFieldName;
fn typeField(T: type, name: []const u8, data: T) ?[]const u8 {
    if (@typeInfo(T) != .Struct) return null;
    var local: [0xff]u8 = undefined;
    const realname = local[0..makeFieldName(name, &local)];
    inline for (std.meta.fields(T)) |field| {
        if (eql(u8, field.name, realname)) {
            switch (field.type) {
                []const u8,
                ?[]const u8,
                => return @field(data, field.name),

                else => return null,
            }
        }
    }
    return null;
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
