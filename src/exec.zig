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

pub const ExecOpts = struct {
    wait:bool,
    piped:bool,
    pipe_details:PipeDetails = .{},
};

pub const PipeDetails = struct {
    out:bool = false,
    in:bool = false,
    file:File = .{},

    pub const File = struct {
        do:bool = false,
        name:[]u8 = undefined,
        append:bool = false,
        tmp_file:?[]u8 = null,
        in_or_out:Direction = undefined,
        pub const Direction = enum {
            IN,
            OUT,
        };
    };
};

pub const Cmd = struct {
    raw:[]u8,
    args_info:[]ArgInfo,
    split:[*:null]const ?[*:0]const u8 = undefined,
    fd_set:[2]std.posix.fd_t,
    pid:std.posix.pid_t = undefined,
    opts:ExecOpts = .{ .wait = true, .piped = false },
    envp:[*:null]const ?[*:0]const u8 = undefined, // TODO: determine if I should free this
    is_builtin:bool = false,

    pub const ArgInfo = struct {
        raw:?[*:0]const u8,
        quote_type:u8 = 0,
    };
    
    pub fn free(self:*Cmd, alloc:std.mem.Allocator) void {
        alloc.free(self.raw);
        for (std.mem.span(self.split)) |arg|
            if (arg) |a|
                alloc.free(std.mem.span(a));
    }

    pub fn wants_file_direction(self:*Cmd, direction:PipeDetails.File.Direction) bool {
        for ([_]bool{
            self.opts.pipe_details.file.do,
            self.opts.pipe_details.file.in_or_out == direction,
        }) |check|
            if (!check) return false;
        return true;
    }
};

pub const ExecResult = struct {
    code:u8,
    quit:bool = false,
    err:?anyerror = null
};

pub fn populate_fd_sets(term:*Term, res:*std.ArrayList(Cmd)) !bool {
    var i:usize = 0;
    for (res.items) |*cmd| {
        defer i += 1;
        cmd.split = try parser.split_args(cmd.raw, term);

        const pipe_details = cmd.opts.pipe_details;
        if (pipe_details.file.do) {
            const pipein = pipe_details.file.in_or_out == .IN;
            if (pipein) cmd.opts.pipe_details.in = true;
            const in_fd =
                if (pipe_details.file.tmp_file) |content| b: {
                    const fd = try std.posix.memfd_create(
                        content, 0 //std.posix.FD_CLOEXEC
                    );
                    var file = std.fs.File{ .handle = fd };
                    _ = try file.write(content);
                    break :b file.handle;
                } else if (pipein)
                    (try term.cwd().openFile(pipe_details.file.name, .{})).handle
                else
                    term.stdin_file.handle;

            const out_fd =
                if (cmd.opts.pipe_details.file.in_or_out == .OUT)
                    (try term.cwd().createFile(pipe_details.file.name, .{
                        .truncate = !pipe_details.file.append,
                        .read = true,
                    })).handle
                else if (pipe_details.out) b: {
                    cmd.fd_set = try std.posix.pipe();
                    res.items[i+1].opts.pipe_details.in = true;
                    break :b cmd.fd_set[1];
                } else
                    term.stdout_file.handle;

            if (pipe_details.file.append)
                try (std.fs.File{ .handle = out_fd }).seekFromEnd(0);
            cmd.fd_set = [2]std.posix.fd_t{ in_fd, out_fd };
        } else if (pipe_details.out) if (res.items.len > i+1) {
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
    try term.replace_aliases(&res);

    var final:ExecResult = ExecResult{
        .quit = false,
        .code = 0,
        .err = null,
    };
    _ = &final;

    if (!try populate_fd_sets(term, &res))
        return .{ .code = 2, .quit = false };

    
    //start each command
    for (res.items, 0..) |*cmd, i| {
        // TODO: should I just move this out of the loop,
        //  will it ever change between spawning processes?
        cmd.envp = try std.process.createEnvironFromMap(alloc, &term.env, .{});

        _ = cmd.split[0] orelse {
            final.code = 2;
            return final;
        };

        const matched_builtin = std.meta.stringToEnum(
            Builtins, std.mem.span(cmd.split[0].?)
        ) orelse {
            cmd.pid = try std.posix.fork();
            if (cmd.pid == 0) {
                errdefer std.posix.abort;
                defer std.posix.abort();

                //stdin
                std.posix.dup2(
                    if (cmd.opts.pipe_details.in and !@constCast(cmd).wants_file_direction(.IN))
                        (&res.items[i - 1]).fd_set[0]
                    else
                        cmd.fd_set[0],
                    std.posix.STDIN_FILENO
                ) catch |e|
                    @panic(@errorName(e));

                //stdout
                std.posix.dup2(
                    cmd.fd_set[1],
                    std.posix.STDOUT_FILENO
                ) catch |e|
                    @panic(@errorName(e));

                for (res.items) |com| if (com.opts.pipe_details.out) {
                    std.posix.close(com.fd_set[0]);
                    std.posix.close(com.fd_set[1]);
                };

                const err = std.posix.execvpeZ(cmd.split[0].?, cmd.split, cmd.envp);
                // TODO: figure out how to make these changes reflect in the original process
                //  (fork communicating with the parent)
                final.err = switch (err) {
                    error.FileNotFound => error.CommandNotFound,
                    else => err,
                };
                final.code = hlp.determine_exit_code(final.err.?);

                term.print_error(
                    "failed to run command: {?s} ({t})",
                    .{ cmd.split[0], final.err orelse unreachable }
                );

                if (cmd.opts.pipe_details.in) for (res.items[0..i]) |*proc|
                    std.posix.kill(proc.pid, 9) catch |e|
                        term.print_error(
                            "failed stop chain: {?s} ({t})",
                            .{ cmd.split[0], e }
                        );

                std.posix.exit(1);
            }
            if (!cmd.opts.piped and cmd.opts.wait) {
                const result = std.posix.waitpid(cmd.pid, 0);
                if (result.status != 0) final.code = 1;
                cmd.opts.wait = false;
            }
            continue;
        };
        cmd.is_builtin = true;
        if (matched_builtin == .exit) {
            final.quit = true;
        } else
            builtins.do(term, matched_builtin, cmd.*) catch |e| {
                final.err = e;
                final.code = hlp.determine_exit_code(e);
            };
    }

    //close file descriptors (they're duped in forked processes)
     for (res.items) |*cmd| if (cmd.opts.pipe_details.out) {
         std.posix.close(cmd.fd_set[0]);
         std.posix.close(cmd.fd_set[1]);
     };

    //wait for each command to finish
    for (res.items) |cmd| if (!cmd.is_builtin and cmd.opts.wait) {
        const result = std.posix.waitpid(cmd.pid, 0);
        // TODO: figure out how to properly set this (all I get is 256 no matter the error and 0 for ok)
        if (result.status != 0) final.code = 1;
    };

    return final;
}

// TODO: return to this (stuff like $(...) and `...`)
pub fn run_and_collect(term:*Term, cmd:Cmd) ![]u8 {
    _ = .{ term, cmd };
    return "";
}
