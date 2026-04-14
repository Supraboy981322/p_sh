const std = @import("std");
const Term = @import("term.zig").Term;
const exec = @import("exec.zig");

const Cmd = exec.Cmd;

pub const Valid = enum {
    history,
    exit,
    cd,
    @":",
    eval,
    set,
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
        .history => history(term, argv.items),
        .@":" => no_op(term, argv.items),
        .eval => eval(term, argv.items),
        .set => set_opt(term, argv.items),

        // NOTE: this should never be touched, 'exit' is handled much earlier
        //  TODO: change this (for scripting)
        .exit => unreachable,

    }) catch |e| switch (e) {
        else => return e, // TODO: probably want to do something here
    };
}

pub fn cd(term:*Term, argv:[][]const u8) !void {
    if (argv.len < 2) {
        term.print_error("not enough args; need a directory", .{});
        return error.NotEnoughArgs;
    }
    const dir =
        if (std.mem.eql(u8, argv[1], "-")) b: {
            const current = try term.cwd_path(term.alloc);
            defer term.alloc.free(current);
            term.print("{s}\n", .{current});
            break :b try term.alloc.dupe(u8, term.previous_wd);
        } else
            @constCast(argv[1]);
    try term.cd(dir);
}

pub fn history(term:*Term, argv:[][]const u8) !void {
    if (argv.len > 1)
        term.TODO("history command args", .{});
    for (term.hist.arr[0..term.hist.len], 0..) |line, i|
        term.print("{d}: {s}\n", .{i, line});
}

pub fn no_op(term:*Term, argv:[][]const u8) !void {
     _ = .{ term, argv };
    return;
}

pub fn eval(term:*Term, argv:[][]const u8) anyerror!void {
    const joined = try std.mem.join(term.alloc, " ", @constCast(argv[1..]));
    defer term.alloc.free(joined);
    _ = try exec.parse_and_run(joined, term);
}

pub fn set_opt(term:*Term, argv:[][]const u8) !void {
    if (argv.len != 3)
        return if (argv.len < 3)
            error.NotEnoughArgs
        else
            error.TooManyArgs;
    term.config.set(term, @constCast(argv[1]), @constCast(argv[2]));
}
