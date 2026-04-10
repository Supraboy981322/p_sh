const std = @import("std");
const Term = @import("term.zig").Term;
const exec = @import("exec.zig");

const Cmd = exec.Cmd;

pub const Valid = enum {
    exit,
    cd,
};

pub fn do(term:*Term, name:Valid, cmd:Cmd) !void {
    const alloc = term.alloc;
    var argv = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer {
        for (argv.items) |a| alloc.free(a);
        _ = argv.deinit(alloc);
    }

    for (std.mem.span(cmd.split)) |arg| if (arg) |a| {
        try argv.append(alloc, std.mem.span(a));
    };

    (switch (name) {
        .cd => cd(term, argv.items),
        .exit => {},// TODO: handle this
    }) catch |e| switch (e) {
        else => return e, // TODO: probably want to do something here
    };
}

pub fn cd(term:*Term, argv:[][]const u8) !void {
    if (argv.len < 2) {
        term.print_error("not enough args; need a directory", .{});
        return error.NotEnoughArgs;
    }
    try term.cd(@constCast(argv[1]));
}
