const std = @import("std");
const Builder = std.build.Builder;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
    const mode = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "svd2zig",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = mode,
    });
    b.default_step.dependOn(&exe.step);
}
