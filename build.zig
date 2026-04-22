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


    for ([_][]const u8{
        "zeit",
        "glob",
    }) |dep|
        add_dep(b, bin, dep);

    b.installArtifact(bin);

    //for 'zig build run'
    const run_bin = b.addRunArtifact(bin);
    if (b.args) |args| {
        run_bin.addArgs(args);
    }
    const run_step = b.step("run", "run the program");
    run_step.dependOn(&run_bin.step);
}

fn add_dep(b:*std.Build, bin:*std.Build.Step.Compile, name:[]const u8) void {
    const dep = b.dependency(name, .{
        .target = b.graph.host,
    });
    const mod = dep.module(name);
    bin.root_module.addImport(name, mod);
}
