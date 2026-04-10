const std = @import("std");
const globs = @import("globs.zig");
const parser = @import("parser.zig");

const Term = @import("term.zig").Term;
const peek = parser.peek_no_state;

pub const Builtins = enum {
    exit,
    cd,
};

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
    pipe_details:?struct {
        out:bool = false,
    } = null,
};

pub const Cmd = struct {
    raw:[]u8,
    opts:ExecOpts = .{ .wait = true },
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
    quit:bool = false
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

pub fn parse_and_run(
    line:[]u8,
    term:*Term
) !ExecResult {
    const alloc = term.alloc;
    var mem = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = mem.deinit(alloc);

    var res = try std.ArrayList(Cmd).initCapacity(alloc, 0);
    defer _ = res.deinit(alloc);

    var i:usize = 0;
    var string:u8 = 0;
    loop: while (i < line.len) : (i += 1) {
        const b = line[i];
        if (!std.ascii.isWhitespace(b) and string == 0) for (globs.cmd_separators) |separator| if (b == separator) {
            try res.append(alloc, .{
                .raw = try mem.toOwnedSlice(alloc),
                .opts = .{
                    .stdout = .{ .file = term.stdout_file },
                    .stderr = .{ .file = term.stderr_file },
                    .stdin =  .{ .file = term.stdin_file  },
                    .wait = true,
                    .pipe_details = switch (separator) {
                        ';' => null,
                        '|' => .{
                            .out = true,
                        },
                        else => std.debug.panic("TODO: cmd separator |{c}|", .{separator}), 
                    }
                },
            });
            continue :loop;
        };

        if ((b == '"' or b == '\'') and string == 0)
            string = b
        else if (string == b)
            string = 0;

        try mem.append(alloc, b);
    }
    if (mem.items.len > 0) {
        try res.append(alloc, .{
            .raw = try mem.toOwnedSlice(alloc),
            .opts = .{
                .stdin = .{ .file = term.stdin_file, },
                .stdout = .{ .file = term.stdout_file, },
                .stderr = .{ .file = term.stderr_file },
                .wait = true,
            },
        });
    }

    var final:ExecResult = .{
        .quit = false,
        .code = 0,
    };
    _ = &final;
    i = 0;
    loop: while (i < res.items.len) : (i += 1) {
        const cmd = res.items[i];
        if (cmd.opts.pipe_details) |pipe| {
            if (pipe.out) if (res.items.len > i+1) {
                defer i += 1;

                const cmd_1_split = try parser.split_args(cmd.raw, term);
                if (std.mem.span(cmd_1_split).len < 1) continue :loop;
                const fd_set = try std.posix.pipe();
                const envp: [*:null]const ?[*:0]const u8 = try std.process.createEnvironFromMap(alloc, &term.env, .{});

                const cmd_next = res.items[i+1]; 
                const cmd_2_split = try parser.split_args(cmd_next.raw, term);

                const pid_1 = try std.posix.fork();
                if (pid_1 == 0) {
                    std.posix.close(fd_set[0]);
                    _ = try std.posix.dup2(fd_set[1], std.posix.STDOUT_FILENO);
                    std.posix.close(fd_set[1]);
                    const err = std.posix.execvpeZ(cmd_1_split[0].?, cmd_1_split, envp);

                    term.print_error("failed to run command: {?s} ({})", .{cmd_1_split[0], err});
                    std.posix.exit(1);
                }

                const  pid_2 = try std.posix.fork();
                if (pid_2 == 0) {
                    std.posix.close(fd_set[1]);
                    _ = try std.posix.dup2(fd_set[0], std.posix.STDIN_FILENO);
                    std.posix.close(fd_set[0]);
                    const err = std.posix.execvpeZ(cmd_2_split[0].?, cmd_2_split, envp);

                    term.print_error("failed to run command: {?s} ({})", .{cmd_2_split[0], err});
                    std.posix.exit(1);
                }

                for (fd_set) |fd| std.posix.close(fd);
                _ = std.posix.waitpid(pid_1, 0);
                _ = std.posix.waitpid(pid_2, 0);
            } else {
                term.print_error("invalid pipe: missing right-hand side", .{}); 
                return .{ .code = 1, .quit = true }; // TODO: correct exit code 
            };
        } else {
            final = try do(cmd.raw, term , cmd.opts);
        }
        if (final.quit or final.code != 0) break;
    }

    return final;
}
