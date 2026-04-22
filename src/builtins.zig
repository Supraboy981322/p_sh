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

pub const Errors = error {
    NotEnoughArgs,
    TooManyArgs,
    FileNotFound,
    InvalidArgument,
    AccessDenied,
    FileBusy,
    FileSystem,
    InvalidExe,
    IsDir,
    NameTooLong,
    NotDir,
    OutOfMemory,
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
    CommandNotFound,
    WriteFailed,
    InputOutput,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    WouldBlock,
    ProcessNotFound,
    LockViolation,
    SharingViolation,
    PathAlreadyExists,
    PipeBusy,
    NoDevice,
    InvalidWtf8,
    BadPathName,
    NetworkNotFound,
    AntivirusInterference,
    SymLinkLoop,
    FileTooBig,
    NoSpaceLeft,
    DeviceBusy,
    NotSupported,
    UnrecognizedVolume,
    DiskQuota,
    NotOpenForWriting,
    MessageTooBig,
    InvalidUtf8,
    FileLocksNotSupported,
};

pub fn do(term:*Term, name:Valid, cmd:Cmd) Errors {
    const alloc = term.alloc;
    var argv = try std.ArrayList([]const u8).initCapacity(alloc, 0);

    defer {
        for (argv.items) |a| alloc.free(a);
        _ = argv.deinit(alloc);
    }

    for (std.mem.span(cmd.split)) |arg| if (arg) |a| {
        try argv.append(alloc, std.mem.span(a));
    };

    const coms = std.fs.File{ .handle = cmd.coms[1] };

    const func:*const fn (*Term, [][]const u8, std.fs.File) Errors!void = switch (name) {
        .cd => cd,
        .history => history,
        .@":" => no_op,
        .eval => eval,
        .set => set_opt,
        .alias => alias,
        .reload => reload_config,
        .dump => dump,

        // NOTE: this should never be touched, 'exit' is handled much earlier
        //  TODO: change this (for scripting)
        .exit => exit,

    };
    func(term, argv.items, coms) catch |e| {
        try print(.err, "{t}", .{e});
        return e;
    };
    std.process.exit(0);
}

pub fn cd(term:*Term, argv:[][]const u8, coms:std.fs.File) !void {
    const target =
        if (argv.len < 2)
            term.env.get("HOME") orelse {
                try print(.err, "not enough args; need a directory", .{});
                return error.NotEnoughArgs;
            }
        else
            argv[1];
    const dir =
        if (std.mem.eql(u8, target, "-")) b: {
            const current = try term.cwd_path(term.alloc);
            defer term.alloc.free(current);
            try print(.out, "{s}\n", .{current});
            break :b try term.alloc.dupe(u8, term.env.get("OLDPWD").?);
        } else
            try term.alloc.dupe(u8, target);
    defer term.alloc.free(dir);
    _ = try coms.write("chdir:");
    _ = try coms.write(dir);
}

pub fn history(term:*Term, argv:[][]const u8, _:std.fs.File) !void {
    if (argv.len > 1)
        term.TODO("history command args", .{});
    for (term.hist.arr[0..term.hist.len], 0..) |line, i|
        try print(.out, "{d}: {s}\n", .{i, line});
}

pub fn no_op(_:*Term, _:[][]const u8, _:std.fs.File) !void {}

pub fn eval(term:*Term, argv:[][]const u8, _:std.fs.File) !void {
    const joined = try std.mem.join(term.alloc, " ", @constCast(argv[1..]));
    defer term.alloc.free(joined);
    _ = exec.parse_and_run(joined, term) catch |e| {
        try print(.err, "failed to eval: {t}", .{e});
    };
}

pub fn set_opt(_:*Term, argv:[][]const u8, coms:std.fs.File) !void {
    if (argv.len != 3)
        return if (argv.len < 3)
            error.NotEnoughArgs
        else
            error.TooManyArgs;
    for ([_][]const u8{
        "config:", argv[1], "|", argv[2]
    }) |chunk|
        _ = try coms.write(chunk);
}

pub fn alias(_:*Term, argv:[][]const u8, coms:std.fs.File) !void {
    if (argv.len < 3)
        return error.NotEnoughArgs;
    for ([_][]const u8 {
        "alias:", argv[1], "|", argv[2]
    }) |chunk|
        _ = try coms.write(chunk);
}

pub fn reload_config(_:*Term, argv:[][]const u8, coms:std.fs.File) !void {
    _ = argv;
    _ = try coms.write("reload:config");
}

pub fn dump(term:*Term, argv:[][]const u8, _:std.fs.File) !void {
    const ValidArgs = enum {
        env,
        aliases,
        help, @"-h", @"--help",
    };

    const thing = std.meta.stringToEnum(
        ValidArgs, if (argv.len < 2) "help" else argv[1]
    ) orelse {
        try print(.err, "I do not know how to dump {s}, see help", .{argv[1]});
        return error.InvalidArgument;
    };

    switch (thing) {
        .env => {
            var itr = term.env.iterator();
            while (itr.next()) |pair| {
                try print(.out, "{s}={s}\n", .{pair.key_ptr.*, pair.value_ptr.*});
            }
        },
        .aliases => {
            if (term.vars.aliases == null) {
                try print(.out, "you have no aliases\n", .{});
                return;
            }
            var itr = term.vars.aliases.?.iterator();
            while (itr.next()) |pair| {
                try print(.out, "{s}={{\n    {s}\n}}\n\n", .{pair.key_ptr.*, pair.value_ptr.*});
            }
        },
        .help, .@"-h", .@"--help" => {
            try print(.out,
                \\{s} (builtin) -- prints values stored by the shell
                \\  I know how to dump (valid args):
            ++ "\n", .{argv[0]});
            for (std.meta.tags(ValidArgs)) |tag|
                try print(.out, "    {t}\n", .{tag});
        },
    }
}

pub fn exit(_:*Term, _:[][]const u8, coms:std.fs.File) !void {
    _ = try coms.write("EXIT:0");
}

pub fn print(comptime where:enum { err, out }, comptime msg:[]const u8, args:anytype) !void {
    var file = switch (where) {
        .err => std.fs.File.stderr(),
        .out => std.fs.File.stdout(),
    };
    const writer = &@constCast(&file.writer(&.{})).interface;
    try writer.print(msg, args);
}
