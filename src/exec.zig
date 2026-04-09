const std = @import("std");
const globs = @import("globs.zig");
const parser = @import("parser.zig");

const Term = @import("term.zig").Term;

const Builtins = enum {
    exit,
    cd,
};

pub fn do(
    cmd:[]u8,
    term:*Term
) !struct { code:u8, quit:bool = false } {
    var arena = std.heap.ArenaAllocator.init(term.alloc);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const argv = try parser.split_args(cmd, term);
    defer for (argv) |a| alloc.free(a);
    if (argv.len < 1) return .{ .code = 1, .quit = false };

    const argv0 = std.meta.stringToEnum(Builtins, argv[0]) orelse {
        const code = system_command(argv, alloc, term) catch |e| {
            switch (e) {

                error.FileNotFound => {
                    for ([_][]const u8{
                        "command not found: ", argv[0], "\n"
                    }) |thing|
                        _ = try term.stderr_file.write(thing);
                },

                else => _ = try term.stderr_file.write(@errorName(e)),
            }
            return e;
        };
        return .{ .code = code, .quit = false };
    };

    switch (argv0) {
        .exit, => return .{ .code = 0, .quit = true },
        .cd => {
            if (argv.len < 2) {
                _ = try term.stderr_file.write("not enough args; need a directory");
                return .{ .code = 2 };
            }
            try term.cd(@constCast(argv[1]));
        }
    }
    return .{ .code = 0 };
}

pub fn system_command(argv:[]const []const u8, alloc:std.mem.Allocator, term:*Term) !u8 {
    var child = std.process.Child{
        .allocator = alloc,
        .argv = argv,
        .stdout_behavior = .Inherit,
        .stderr_behavior = .Inherit,
        .stdin_behavior = .Inherit,
        .stdin = term.stdin_file.*,
        .stdout = term.stdout_file.*,
        .stderr = term.stderr_file.*,

        // TODO: this stuff
        .id = undefined,
        .thread_handle = undefined,
        .err_pipe = null,
        .term = null,
        .env_map = @constCast(&term.env),
        .uid = null,
        .cwd = null,
        .cwd_dir = term.cwd(),
        .gid = null,
        .pgid = null,
        .expand_arg0 = .no_expand,
    };
    try child.spawn(); 
    // TODO: term code
    _ = try child.wait();
    return 0;
}
