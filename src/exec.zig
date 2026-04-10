const std = @import("std");
const globs = @import("globs.zig");
const parser = @import("parser.zig");

const Term = @import("term.zig").Term;

const Builtins = enum {
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
    try child.spawn(); 
    // TODO: term code
    _ = try child.wait();
    return 0;
}
