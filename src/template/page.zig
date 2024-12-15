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
        slice: void,
        directive: Directive,
        array: struct {
            name: []const u8,
            len: usize,
        },
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

fn getOffset(T: type, name: []const u8) ?usize {
    switch (@typeInfo(T)) {
        .Struct => {
            var local: [0xff]u8 = undefined;
            const field = local[0..makeFieldName(name, &local)];
            return @offsetOf(T, field);
        },
        else => return null,
    }
}

fn getChildType(T: type, name: []const u8) type {
    var local: [0xff]u8 = undefined;
    const field = local[0..makeFieldName(name, &local)];
    //return @TypeOf(@FieldType(T, field)); // not in 0.13.0
    for (std.meta.fields(T)) |f| {
        if (eql(u8, f.name, field)) {
            switch (@typeInfo(f.type)) {
                .Pointer => |ptr| return ptr.child,
                .Optional => |opt| return opt.child,
                .Struct => return f.type,
                else => unreachable,
            }
        }
    } else unreachable;
}

pub fn commentTag(blob: []const u8) ?usize {
    if (blob.len > 2 and blob[1] == '!' and blob.len > 4 and blob[2] == '-' and blob[3] == '-') {
        if (indexOfPosLinear(u8, blob, 4, "-->")) |comment| {
            return comment + 3;
        }
    }
    return null;
}

fn validateBlockSplit(
    index: usize,
    offset: usize,
    end: usize,
    pblob: []const u8,
    drct: Directive,
    os: Offset,
) []const Offset {
    // TODO Split needs whitespace postfix
    const ws_start: usize = offset + end;
    var wsidx = ws_start;
    while (wsidx < pblob.len and
        (pblob[wsidx] == ' ' or pblob[wsidx] == '\t' or
        pblob[wsidx] == '\n' or pblob[wsidx] == '\r'))
    {
        wsidx += 1;
    }
    if (wsidx > 0) {
        return &[_]Offset{
            .{
                .start = index + drct.tag_block.len,
                .end = index + wsidx,
                .kind = .{ .array = .{ .name = drct.noun, .len = 2 } },
            },
            os,
            .{ .start = 0, .end = wsidx - end, .kind = .slice },
        };
    } else {
        return &[_]Offset{
            .{
                .start = index + drct.tag_block.len,
                .end = index + end,
                .kind = .{ .array = .{ .name = drct.noun, .len = 1 } },
            },
            os,
        };
    }
}

pub fn validateBlock(comptime html: []const u8, PageDataType: type) []const Offset {
    @setEvalBranchQuota(20000);
    var found_offsets: []const Offset = &[0]Offset{};
    var pblob = html;
    var index: usize = 0;
    var open_idx: usize = 0;
    // Originally attempted to write this just using index, but got catastrophic
    // backtracking errors when compiling. I'd have assumed this version would
    // be more expensive, but here we are :D
    while (pblob.len > 0) {
        if (indexOfScalar(u8, pblob, '<')) |offset| {
            // TODO this implementation makes tracking whitespace much harder.
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
                switch (drct.verb) {
                    .variable => {
                        // TODO FIXME There is a really nasty bug here, where after
                        // the first recurse, it will calculate the offsets based on
                        // the root type, and not for the child type.
                        os.kind.directive.known_offset = getOffset(PageDataType, drct.noun);
                        found_offsets = found_offsets ++ [_]Offset{os};
                    },
                    .split => {
                        found_offsets = found_offsets ++
                            validateBlockSplit(index, offset, end, pblob, drct, os)[0..];
                    },
                    else => {
                        // left in for testing
                        if (drct.tag_block_body) |body| {
                            const loop = validateBlock(
                                body,
                                getChildType(PageDataType, drct.noun),
                            );
                            found_offsets = found_offsets ++ [_]Offset{.{
                                .start = index + drct.tag_block_skip.?,
                                .end = index + end,
                                .kind = .{ .array = .{ .name = drct.noun, .len = loop.len } },
                            }} ++ loop;
                        } else {
                            found_offsets = found_offsets ++ [_]Offset{os};
                        }
                    },
                }
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
    if (index != pblob.len or open_idx == 0) {
        found_offsets = found_offsets ++ [_]Offset{.{
            .start = open_idx,
            .end = html.len,
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

        fn offsetDirective(T: type, data: T, directive: Directive, out: anytype) !void {
            std.debug.assert(directive.verb == .variable);
            if (directive.known_offset) |offset| {
                if (directive.known_type) |_| {
                    directive.formatTyped(T, data, out) catch unreachable;
                    return;
                }

                const ptr: [*]const u8 = @ptrCast(&data);
                var vari: ?[]const u8 = null;
                switch (directive.otherwise) {
                    .required => vari = @as(*const []const u8, @ptrCast(@alignCast(&ptr[offset]))).*,
                    .delete => vari = @as(*const ?[]const u8, @ptrCast(@alignCast(&ptr[offset]))).*,
                    .default => |default| {
                        const sptr: *const ?[]const u8 = @ptrCast(@alignCast(&ptr[offset]));
                        vari = if (sptr.*) |sp| sp else default;
                    },
                    else => unreachable,
                }
                if (vari) |v| {
                    try out.writeAll(v);
                }
            } else {
                try directive.formatTyped(T, data, out);
            }
        }

        fn offsetArrayItem(T: type, list: []const T, ofs: []const Offset, html: []const u8, out: anytype) !void {
            //std.debug.print("item {any}\n", .{T});
            if (T == []const u8) {
                for (list) |item| {
                    try out.writeAll(item);
                    // I should find a better way to write this hack
                    if (ofs.len == 2) {
                        if (ofs[1].kind == .slice) {
                            try out.writeAll(html[ofs[1].start..ofs[1].end]);
                        }
                    }
                }
            } else {
                for (list) |item| {
                    try formatDirective(T, item, ofs, html, out);
                }
            }
        }

        fn offsetOptionalItem(T: type, item: ?T, ofs: []const Offset, html: []const u8, out: anytype) !void {
            if (comptime T == ?[]const u8) {
                return offsetDirective(T, item.?, ofs[0], out);
            }
            switch (@typeInfo(T)) {
                .Int => {
                    std.debug.print("skipped int\n", .{});
                },
                else => {
                    if (item) |itm| {
                        try formatDirective(T, itm, ofs, html, out);
                    }
                },
            }
        }

        fn offsetArray(T: type, data: T, name: []const u8, ofs: []const Offset, html: []const u8, out: anytype) !void {
            inline for (std.meta.fields(T)) |field| {
                if (eql(u8, name, field.name)) {
                    //std.debug.print("array found {s}\n", .{name});
                    return switch (field.type) {
                        []const u8 => try out.writeAll(@field(data, field.name)),
                        []const []const u8 => try offsetArrayItem([]const u8, @field(data, field.name), ofs, html, out),
                        else => {
                            //std.debug.print("array found {}\n", .{@typeInfo(field.type)});
                            switch (@typeInfo(field.type)) {
                                .Pointer => |ptr| {
                                    std.debug.assert(ptr.size == .Slice);
                                    try offsetArrayItem(ptr.child, @field(data, field.name), ofs, html, out);
                                },
                                .Optional => |opt| {
                                    if (opt.child == []const u8) {
                                        return;
                                        //return offsetDirective(field.type, @field(data, field.name), ofs[0].kind.directive, out);
                                    }

                                    try offsetOptionalItem(opt.child, @field(data, field.name), ofs, html, out);
                                },
                                else => {
                                    std.debug.print("unexpected type {any}\n", .{field.type});
                                    //unreachable;
                                },
                            }
                        },
                    };
                }
            } else {
                std.debug.print("error generating page, field {s} is missing\n", .{name});
            }
        }

        fn formatDirective(T: type, data: T, ofs: []const Offset, html: []const u8, out: anytype) !void {
            var last_end: usize = 0;
            var idx: usize = 0;
            while (idx < ofs.len) {
                const os = ofs[idx];
                idx += 1;
                switch (os.kind) {
                    .array => |array| {
                        //std.debug.print("array for {s}\n", .{array.name});
                        var local: [0xff]u8 = undefined;
                        const name = local[0..makeFieldName(array.name, &local)];
                        if (T == []const []const u8) {
                            try offsetArrayItem([]const u8, data, ofs[idx .. idx + 1], html, out);
                        } else if (T == []const u8) {
                            // skip
                        } else {
                            try offsetArray(T, data, name, ofs[idx..][0..array.len], html[os.start..os.end], out);
                        }
                        idx += array.len;
                    },
                    .slice => {
                        if (idx == 1) {
                            try out.writeAll(std.mem.trimLeft(u8, html[os.start..os.end], " \n\r"));
                        } else if (idx == ofs.len) {
                            //try out.writeAll(std.mem.trimRight(u8, html[os.start..os.end], " \n\r"));
                            try out.writeAll(html[os.start..os.end]);
                        } else if (ofs.len == 1) {
                            try out.writeAll(std.mem.trim(u8, html[os.start..os.end], " \n\r"));
                        } else {
                            try out.writeAll(html[os.start..os.end]);
                        }
                    },
                    .directive => |directive| switch (directive.verb) {
                        .variable => {
                            //std.debug.print("directive\n", .{});
                            offsetDirective(T, data, directive, out) catch |err| switch (err) {
                                error.IgnoreDirective => try out.writeAll(html[os.start..os.end]),
                                error.VariableMissing => {
                                    if (!is_test) log.err(
                                        "Template Error, variable missing {{{s}}}",
                                        .{html[os.start..os.end]},
                                    );
                                    try out.writeAll(html[os.start..os.end]);
                                },
                                else => return err,
                            };
                        },
                        else => {
                            //std.debug.print("directive skipped {}\n", .{directive.verb});
                        },
                    },
                }
                last_end = os.end;
            }
        }

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
            //std.debug.print("offs {any}\n", .{Self.DataOffsets});
            const blob = Self.PageTemplate.blob;
            if (Self.DataOffsets.len == 0)
                return try out.writeAll(blob);

            try formatDirective(PageDataType, self.data, Self.DataOffsets[0..], blob, out);
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
