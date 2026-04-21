const std = @import("std");

pub fn build(b: *std.Build) void {
    //build settings
    const bin = b.addExecutable(.{
        .name = "p_sh",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host
        }),
    });


    const zeit_dep = b.dependency("zeit", .{
        .target = b.graph.host,
    });
    const zeit = zeit_dep.module("zeit");

    b.installArtifact(bin);
    bin.root_module.addImport("zeit", zeit);

    //for 'zig build run'
    const run_bin = b.addRunArtifact(bin);
    if (b.args) |args| {
        run_bin.addArgs(args);
    }
    const run_step = b.step("run", "run the program");
    run_step.dependOn(&run_bin.step);
}
