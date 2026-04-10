const std = @import("std");
const globs = @import("globs.zig");
const parser = @import("parser.zig");
const builtins = @import("builtins.zig");
const hlp = @import("helpers.zig");

const Term = @import("term.zig").Term;
const peek = parser.peek_no_state;

pub const Builtins = builtins.Valid;

const IoOpt = struct {
    file:?*std.fs.File = null,
    is_file:bool = false,
    is_pipe:bool = false,
};

const ExecOpts = struct {
    stdout:IoOpt = .{},
    stderr:IoOpt = .{},
    stdin:IoOpt = .{},
    wait:bool,
    pipe_details:struct {
        out:bool = false,
        in:bool = false,
    } = .{},
};

pub const Cmd = struct {
    raw:[]u8,
    split:[*:null]const ?[*:0]const u8 = undefined,
    fd_set:[2]std.posix.fd_t,
    pid:std.posix.pid_t = undefined,
    opts:ExecOpts = .{ .wait = true },
    envp:[*:null]const ?[*:0]const u8 = undefined,
    is_builtin:bool = false,

    pub fn print(self:*Cmd) void {
        std.debug.print(
            \\Cmd = .{{
            \\  .raw = {s},
            \\  .opts = .{{
            \\     .wait = {},
            \\     .stdout = .{{
            \\        .file = {?d},
            \\        .is_file = {},
            \\        .is_pipe = {},
            \\      }},
            \\     .stdin = .{{
            \\        .file = {?d},
            \\        .is_file = {},
            \\        .is_pipe = {},
            \\      }},
            \\     .stderr = .{{
            \\        .file = {?d},
            \\        .is_file = {},
            \\        .is_pipe = {},
            \\      }},
            \\   }},
            \\}};
            ++ "\n", .{
                self.raw,
                self.opts.wait,
                if (self.opts.stdout.file) |file| file.handle else null,  self.opts.stdout.is_file, self.opts.stdout.is_pipe,
                if (self.opts.stdin.file)  |file| file.handle else null,  self.opts.stdin.is_file,  self.opts.stdin.is_pipe,
                if (self.opts.stderr.file) |file| file.handle else null,  self.opts.stderr.is_file, self.opts.stderr.is_pipe,
            }
        );
    }
};

pub const ExecResult = struct {
    code:u8,
    quit:bool = false,
    err:?anyerror = null
};

pub fn do(
    cmd:[]u8,
    term:*Term,
    opts:?ExecOpts,
) !ExecResult {
    var arena = std.heap.ArenaAllocator.init(term.alloc);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const argv_raw = std.mem.span(try parser.split_args(cmd, term));
    defer for (argv_raw) |arg| if (arg) |a| alloc.free(std.mem.span(a));
    var argv = b: {
        var arr = try std.ArrayList([]const u8).initCapacity(alloc, argv_raw.len);
        defer _ = arr.deinit(alloc);
        for (argv_raw) |arg| if (arg) |a|
            try arr.append(alloc, std.mem.span(a));
        break :b try arr.toOwnedSlice(alloc);
    };
    defer for (argv) |a| alloc.free(a);

    if (argv.len < 1) return .{ .code = 1, .quit = false };

    if (term.vars.aliases) |*const_aliases| {
        var aliases = @constCast(const_aliases);
        var itr = aliases.iterator();
        while (itr.next()) |alias| if (std.mem.eql(u8, alias.key_ptr.*, argv[0])) {
            var arr = try std.ArrayList([]const u8).initCapacity(alloc, argv.len);
            defer _ = arr.deinit(alloc);
            const new = std.mem.span(try parser.split_args(@constCast(alias.value_ptr.*), term));
            for (new) |arg| if (arg) |a|
                try arr.append(alloc, std.mem.span(a));
            argv = try arr.toOwnedSlice(alloc);
            break;
        };
    }

    const argv0 = std.meta.stringToEnum(Builtins, argv[0]) orelse {
        const code = system_command(argv, alloc, term, opts) catch |e| {
            switch (e) {

                error.FileNotFound => term.print_error("command not found: {s}", .{argv[0]}),

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
                term.print_error("not enough args; need a directory", .{});
                return .{ .code = 2 };
            }
            try term.cd(@constCast(argv[1]));
        }
    }
    return .{ .code = 0 };
}

pub fn system_command(
    argv:[]const
    []const u8,
    alloc:std.mem.Allocator,
    term:*Term,
    opts:?ExecOpts,
) !u8 {

    var child = std.process.Child{
        .allocator = alloc,
        .argv = argv,

        .stdout_behavior = .Inherit,
        .stdin_behavior = .Inherit,
        .stderr_behavior = .Inherit,

        .stdin =
            if (opts) |o|
                if (o.stdin.file) |file|
                    file.*
                else
                    null
            else
                term.stdin_file.*,
        .stdout =
            if (opts) |o|
                if (o.stdout.file) |file|
                    file.*
                else
                    null
            else
                term.stdout_file.*,
        .stderr =
            if (opts) |o|
                if (o.stderr.file) |file|
                    file.*
                else
                    null
            else
                term.stderr_file.*,

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

    if (opts) |o| {
        if (o.stdout.is_pipe)
            child.stdout_behavior = .Pipe;
        if (o.stderr.is_pipe)
            child.stderr_behavior = .Pipe;
        if (o.stdin.is_pipe)
            child.stdin_behavior = .Pipe;
    }

    try child.spawn(); 
    _ = try child.wait();
    return 0;
}

pub fn populate_fd_sets(term:*Term, res:*std.ArrayList(Cmd)) !bool {
    var i:usize = 0;
    for (res.items) |*cmd| {
        defer i += 1;
        cmd.split = try parser.split_args(cmd.raw, term);

        if (cmd.opts.pipe_details.out) if (res.items.len > i+1) {
            cmd.fd_set = try std.posix.pipe();
            res.items[i+1].opts.pipe_details.in = true;
        } else {
            term.print_error("invalid pipe: missing right-hand side", .{}); 
            return false; // TODO: correct exit code 
        };
    }
    return true;
}

pub fn parse_and_run(
    line:[]u8,
    term:*Term
) !ExecResult {
    const alloc = term.alloc;
    var res = try std.ArrayList(Cmd).initCapacity(alloc, 0);
    defer {
        for (res.items) |*cmd| cmd.free(alloc);
        _ = res.deinit(alloc);
    }

    try parser.split_command(term, &res, line);

    var final:*ExecResult = @constCast(&ExecResult{
        .quit = false,
        .code = 0,
        .err = null,
    });
    _ = &final;

    if (!try populate_fd_sets(term, &res))
        return .{ .code = 2, .quit = false };

    var i:usize = 0;
    for (res.items) |*cmd| {
        defer i += 1;
        cmd.envp = try std.process.createEnvironFromMap(alloc, &term.env, .{});

        const name = cmd.split[0] orelse {
            final.code = 2;
            return final.*;
        };

        const matched_builtin = std.meta.stringToEnum(Builtins, std.mem.span(name)) orelse {
            cmd.pid = try std.posix.fork();
            if (cmd.pid == 0) {
                if (cmd.opts.pipe_details.in) {
                    const previous = &res.items[i - 1];
                    _ = try std.posix.dup2(previous.fd_set[0], std.posix.STDIN_FILENO);
                } else {
                    _ = try std.posix.dup2(cmd.fd_set[0], std.posix.STDIN_FILENO);
                }
                try std.posix.dup2(cmd.fd_set[1], std.posix.STDOUT_FILENO);

                for (res.items) |com| if (com.opts.pipe_details.out) {
                    std.posix.close(com.fd_set[0]);
                    std.posix.close(com.fd_set[1]);
                };

                const err = std.posix.execvpeZ(cmd.split[0].?, cmd.split, cmd.envp);
                // TODO: figure out how to make these changes reflect in the original process
                //  (fork communicating with the parent)
                final.*.err = switch (err) {
                    error.FileNotFound => error.CommandNotFound,
                    else => err,
                };
                final.*.code = hlp.determine_exit_code(final.*.err.?);

                term.print_error("failed to run command: {?s} (error: {?})", .{ cmd.split[0], final.err });
                std.posix.exit(1);
            }
            continue;
        };
        cmd.is_builtin = true;
        if (matched_builtin == .exit) {
            final.quit = true;
        } else
            builtins.do(term, matched_builtin, cmd.*) catch |e| {
                final.*.err = e;
                final.code = hlp.determine_exit_code(e);
            };
    }

    for (res.items) |*cmd| if (cmd.opts.pipe_details.out) {
        std.posix.close(cmd.fd_set[0]);
        std.posix.close(cmd.fd_set[1]);
    };

    for (res.items) |cmd| if (!cmd.is_builtin) {
        const result = std.posix.waitpid(cmd.pid, 0);
        // TODO: figure out how to properly set this (all I get is 256 no matter the error and 0 for ok)
        if (result.status != 0) final.*.code = 1;
    };

    return final.*;
}
