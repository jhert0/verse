const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //const lib = b.addStaticLibrary(.{
    //    .name = "verse",
    //    .root_source_file = b.path("src/verse.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});

    //const lib_share = b.addSharedLibrary(.{
    //    .name = "verse",
    //    .root_source_file = b.path("src/verse.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});

    //b.installArtifact(lib);
    //b.installArtifact(lib_share);

    const module = b.addModule("verse", .{
        .root_source_file = b.path("src/verse.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = module;

    const t_compiler = b.addExecutable(.{
        .name = "template-compiler",
        .root_source_file = b.path("src/template-compiler.zig"),
        .target = target,
    });

    //t_compiler.root_module.addImport("comptime_templates", comptime_templates);
    const tc_build_run = b.addRunArtifact(t_compiler);
    //const tc_structs = tc_build_run.addOutputFileArg("compiled-structs.zig");
    const tc_build_step = b.step("templates", "Compile templates down into struct");
    tc_build_step.dependOn(&tc_build_run.step);

    //const exe = b.addExecutable(.{
    //    .name = "verse",
    //    .root_source_file = b.path("src/main.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});

    //b.installArtifact(exe);

    //const run_cmd = b.addRunArtifact(exe);

    //run_cmd.step.dependOn(b.getInstallStep());

    //if (b.args) |args| {
    //    run_cmd.addArgs(args);
    //}

    //const run_step = b.step("run", "Run the app");
    //run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    //const exe_unit_tests = b.addTest(.{
    //    .root_source_file = b.path("src/main.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});

    //const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

pub const Compiler = struct {
    pub fn buildTemplates(b: *std.Build, srcdir: []const u8) !*std.Build.Module {
        const list = try buildList(b, srcdir);
        const local_dir = std.fs.path.dirname(@src().file) orelse ".";
        const compiled = b.createModule(.{
            .root_source_file = .{
                .cwd_relative = b.pathJoin(&.{ local_dir, "src/template/comptime.zig" }),
            },
        });

        const found = b.addOptions();
        found.addOption([]const []const u8, "names", list.items);
        compiled.addOptions("config", found);

        for (list.items) |file| {
            _ = compiled.addAnonymousImport(file, .{
                .root_source_file = b.path(file),
            });
        }

        return compiled;
    }

    pub fn buildStructs(b: *std.Build, srcdir: []const u8) !*std.Build.Module {
        const local_dir = std.fs.path.dirname(@src().file) orelse ".";
        const t_compiler = b.addExecutable(.{
            .name = "template-compiler",
            .root_source_file = .{
                .cwd_relative = b.pathJoin(&.{ local_dir, "src/template-compiler.zig" }),
            },
            .target = b.host,
        });
        //const list = try buildList(b, srcdir);
        //const found = b.addOptions();
        //found.addOption([]const []const u8, "names", list.items);
        //t_compiler.root_module.addOptions("config", found);

        const comptime_templates = try buildTemplates(b, srcdir);
        t_compiler.root_module.addImport("comptime_templates", comptime_templates);
        const tc_build_run = b.addRunArtifact(t_compiler);
        const tc_structs = tc_build_run.addOutputFileArg("compiled-structs.zig");
        const tc_build_step = b.step("templates", "Compile templates down into struct");
        tc_build_step.dependOn(&tc_build_run.step);
        const module = b.createModule(.{
            .root_source_file = tc_structs,
        });

        return module;
    }

    fn buildList(b: *std.Build, srcdir: []const u8) !std.ArrayList([]const u8) {
        var cwd = std.fs.cwd();
        var idir = cwd.openDir(srcdir, .{ .iterate = true }) catch |err| {
            std.debug.print("template build error {}", .{err});
            return err;
        };
        var list = std.ArrayList([]const u8).init(b.allocator);
        errdefer list.deinit();
        var itr = idir.iterate();
        while (try itr.next()) |file| {
            if (!std.mem.endsWith(u8, file.name, ".html")) continue;
            try list.append(b.pathJoin(&[2][]const u8{ srcdir, file.name }));
        }
        return list;
    }
};
