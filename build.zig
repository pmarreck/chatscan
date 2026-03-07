const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_vec_dep = b.dependency("sqlite_vec", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite3_lib = sqlite_vec_dep.artifact("sqlite3");
    const vec_static_lib = sqlite_vec_dep.artifact("sqlite_vec0");

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "chatscan",
        .root_module = main_module,
    });
    linkCommon(exe, sqlite3_lib, vec_static_lib);
    b.installArtifact(exe);

    // Aggregated unit tests
    const unit_aggregate_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/all_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkCommon(unit_aggregate_tests, sqlite3_lib, vec_static_lib);
    const test_unit_step = b.step("test-unit", "Run aggregated unit tests");
    test_unit_step.dependOn(&b.addRunArtifact(unit_aggregate_tests).step);

    // Per-module tests
    const test_step = b.step("test", "Run unit tests");

    const test_modules = [_][]const u8{
        "src/cli.zig",
        "src/config.zig",
        "src/storage.zig",
        "src/conversation.zig",
        "src/indexer.zig",
        "src/search.zig",
        "src/ripgrep.zig",
        "src/output.zig",
        "src/ollama.zig",
        "src/embedding.zig",
        "src/rename.zig",
        "src/main.zig",
    };

    for (test_modules) |mod_path| {
        const mod_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(mod_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        linkCommon(mod_tests, sqlite3_lib, vec_static_lib);
        test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    }
}

fn linkCommon(
    compile: *std.Build.Step.Compile,
    sqlite3_lib: *std.Build.Step.Compile,
    vec_static_lib: *std.Build.Step.Compile,
) void {
    compile.linkLibrary(sqlite3_lib);
    compile.linkLibrary(vec_static_lib);
}
