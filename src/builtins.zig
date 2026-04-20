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
    alias,
    reload,
    dump,
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
        .alias => alias(term, argv.items),
        .reload => reload_config(term, argv.items),
        .dump => dump(term, argv.items),

        // NOTE: this should never be touched, 'exit' is handled much earlier
        //  TODO: change this (for scripting)
        .exit => unreachable,

    }) catch |e| switch (e) {
        else => return e, // TODO: probably want to do something here
    };
}

pub fn cd(term:*Term, argv:[][]const u8) !void {
    const target =
        if (argv.len < 2)
            term.env.get("HOME") orelse {
                term.print_error("not enough args; need a directory", .{});
                return error.NotEnoughArgs;
            }
        else
            argv[1];
    const dir =
        if (std.mem.eql(u8, target, "-")) b: {
            const current = try term.cwd_path(term.alloc);
            defer term.alloc.free(current);
            term.print("{s}\n", .{current});
            std.debug.print("BUILTIN: {?s}\n", .{term.env.get("OLDPWD")});
            break :b try term.alloc.dupe(u8, term.env.get("OLDPWD").?);
        } else
            try term.alloc.dupe(u8, target);
    defer term.alloc.free(dir);
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

pub fn alias(term:*Term, argv:[][]const u8) !void {
    if (argv.len < 3)
        return error.NotEnoughArgs;
    const alloc = term.permanent_alloc;
    const name = try alloc.dupe(u8, argv[1]);
    const value = try alloc.dupe(u8, argv[2]);
    if (term.vars.aliases == null) 
        term.vars.aliases = std.StringHashMap([]u8).init(alloc);
    try term.vars.aliases.?.put(name, value);
}

pub fn reload_config(term:*Term, argv:[][]const u8) !void {
    _ = argv;
    term.read_config() catch |e|
        if (e == error.FileNotFound)
            term.print_error(
                "no config file found ({s}/.p_shrc); using default settings",
                .{ term.env.get("HOME") orelse "$HOME" }
            )
        else
            term.print_error("failed to read config: {t}", .{e});
}

pub fn dump(term:*Term, argv:[][]const u8) !void {
    const ValidArgs = enum {
        env,
        aliases,
        help, @"-h", @"--help",
    };

    const thing = std.meta.stringToEnum(
        ValidArgs, if (argv.len < 2) "help" else argv[1]
    ) orelse {
        term.print_error("I do not know how to dump {s}, see help", .{argv[1]});
        return error.InvalidArgument;
    };

    switch (thing) {
        .env => {
            var itr = term.env.iterator();
            while (itr.next()) |pair| {
                term.print("{s}={s}\n", .{pair.key_ptr.*, pair.value_ptr.*});
            }
        },
        .aliases => {
            if (term.vars.aliases == null) {
                term.print("you have no aliases\n", .{});
                return;
            }
            var itr = term.vars.aliases.?.iterator();
            while (itr.next()) |pair| {
                term.print("{s}={{\n    {s}\n}}\n\n", .{pair.key_ptr.*, pair.value_ptr.*});
            }
        },
        .help, .@"-h", .@"--help" => {
            term.print(
                \\{s} (builtin) -- prints values stored by the shell
                \\  I know how to dump (valid args):
            ++ "\n", .{argv[0]});
            for (std.meta.tags(ValidArgs)) |tag|
                term.print("    {t}\n", .{tag});
        },
    }
}
