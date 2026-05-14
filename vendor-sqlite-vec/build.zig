const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const amalgamation_dir = getAmalgamationDir(b);

	const header_text = renderHeader(b) catch @panic("failed to render sqlite-vec.h");
	const write_files = b.addWriteFiles();
	const header_path = write_files.add("sqlite-vec.h", header_text);
	const header_dir = write_files.getDirectory();

	const sqlite3_module = b.createModule(.{
		.target = target,
		.optimize = optimize,
	});
	const sqlite3_lib = b.addLibrary(.{
		.name = "sqlite3",
		.root_module = sqlite3_module,
		.linkage = .static,
	});
	sqlite3_module.addCSourceFile(.{
		.file = amalgamation_dir.path(b, "sqlite3.c"),
		.flags = &.{"-DSQLITE_ENABLE_FTS5"},
	});
	sqlite3_module.addIncludePath(amalgamation_dir);
	sqlite3_module.link_libc = true;
	sqlite3_lib.installHeader(amalgamation_dir.path(b, "sqlite3.h"), "sqlite3.h");
	sqlite3_lib.installHeader(amalgamation_dir.path(b, "sqlite3ext.h"), "sqlite3ext.h");
	b.installArtifact(sqlite3_lib);

	const vec_static_module = b.createModule(.{
		.target = target,
		.optimize = optimize,
	});
	const vec_static = b.addLibrary(.{
		.name = "sqlite_vec0",
		.root_module = vec_static_module,
		.linkage = .static,
	});
	vec_static_module.addCSourceFile(.{
		.file = b.path("sqlite-vec.c"),
		.flags = &.{ "-DSQLITE_CORE", "-DSQLITE_VEC_STATIC" },
	});
	vec_static_module.addIncludePath(amalgamation_dir);
	vec_static_module.addIncludePath(header_dir);
	vec_static_module.link_libc = true;
	vec_static.installHeader(header_path, "sqlite-vec.h");
	b.installArtifact(vec_static);

	const vec_shared_module = b.createModule(.{
		.target = target,
		.optimize = optimize,
	});
	const vec_shared = b.addLibrary(.{
		.name = "vec0",
		.root_module = vec_shared_module,
		.linkage = .dynamic,
	});
	vec_shared_module.addCSourceFile(.{
		.file = b.path("sqlite-vec.c"),
	});
	vec_shared_module.addIncludePath(amalgamation_dir);
	vec_shared_module.addIncludePath(header_dir);
	vec_shared_module.link_libc = true;
	vec_shared.installHeader(header_path, "sqlite-vec.h");
	b.installArtifact(vec_shared);
}

fn getAmalgamationDir(b: *std.Build) std.Build.LazyPath {
	if (b.graph.environ_map.get("SQLITE_VEC_SQLITE_AMALGAMATION_DIR")) |path| {
		return .{ .cwd_relative = b.dupe(path) };
	}

	const cwd = std.Io.Dir.cwd();
	if (cwd.access(b.graph.io, "vendor/sqlite3.c", .{})) |_| {
		return b.path("vendor");
	} else |_| {}

	@panic("sqlite amalgamation not found; set SQLITE_VEC_SQLITE_AMALGAMATION_DIR or run scripts/vendor.sh");
}

const VersionParts = struct {
	major: u32,
	minor: u32,
	patch: u32,
};

fn renderHeader(b: *std.Build) ![]u8 {
	const allocator = b.allocator;
	const io = b.graph.io;
	const cwd = std.Io.Dir.cwd();

	const version_raw = try cwd.readFileAlloc(io, b.pathFromRoot("VERSION"), allocator, .limited(256));
	defer allocator.free(version_raw);
	const version = std.mem.trim(u8, version_raw, " \t\r\n");
	const version_parts = parseVersion(version);

	const template = try cwd.readFileAlloc(io, b.pathFromRoot("sqlite-vec.h.tmpl"), allocator, .limited(64 * 1024));
	defer allocator.free(template);

	const date = "1970-01-01T00:00:00Z+0000";
	const source = "unknown";

	const major = try std.fmt.allocPrint(allocator, "{d}", .{version_parts.major});
	const minor = try std.fmt.allocPrint(allocator, "{d}", .{version_parts.minor});
	const patch = try std.fmt.allocPrint(allocator, "{d}", .{version_parts.patch});
	defer allocator.free(major);
	defer allocator.free(minor);
	defer allocator.free(patch);

	var out = try replaceOwned(allocator, template, "${VERSION}", version);
	out = try replaceOwned(allocator, out, "${DATE}", date);
	out = try replaceOwned(allocator, out, "${SOURCE}", source);
	out = try replaceOwned(allocator, out, "${VERSION_MAJOR}", major);
	out = try replaceOwned(allocator, out, "${VERSION_MINOR}", minor);
	out = try replaceOwned(allocator, out, "${VERSION_PATCH}", patch);

	return out;
}

fn replaceOwned(
	allocator: std.mem.Allocator,
	input: []const u8,
	needle: []const u8,
	replacement: []const u8,
) ![]u8 {
	const output = try std.mem.replaceOwned(u8, allocator, input, needle, replacement);
	allocator.free(input);
	return output;
}

fn parseVersion(version: []const u8) VersionParts {
	var it = std.mem.splitScalar(u8, version, '.');
	const major_str = it.next() orelse "0";
	const minor_str = it.next() orelse "0";
	const patch_full = it.next() orelse "0";
	var patch_split = std.mem.splitScalar(u8, patch_full, '-');
	const patch_str = patch_split.next() orelse patch_full;

	return .{
		.major = parsePart(major_str),
		.minor = parsePart(minor_str),
		.patch = parsePart(patch_str),
	};
}

fn parsePart(value: []const u8) u32 {
	return std.fmt.parseInt(u32, value, 10) catch 0;
}
