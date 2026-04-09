const std = @import("std");
const parser = @import("parser.zig");

pub const Term = struct {
    og:std.os.linux.termios,
    raw:std.os.linux.termios,

    stdin_file:*std.fs.File,
    stdout_file:*std.fs.File,
    stderr_file:*std.fs.File,

    alloc:std.mem.Allocator,
    env:std.process.EnvMap,

    pub fn init(
        alloc:std.mem.Allocator,
        stdin:*std.fs.File,
        stderr:*std.fs.File,
        stdout:*std.fs.File,
        env:?std.process.EnvMap,
    ) !Term {
        const og = try std.posix.tcgetattr(stdin.handle);
        var raw = og;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
        var res:Term = .{
            .og = og,
            .raw = raw,
            .stdin_file = stdin,
            .stdout_file = stdout,
            .stderr_file = stderr,
            .alloc = alloc,
            .env = if (env) |e| e else try std.process.getEnvMap(alloc),
        };
        try res.cd(@constCast("."));
        return res;
    }

    pub fn cd(self:*Term, path:[]u8) !void {
        const dir = self.cwd().realpathAlloc(self.alloc, path) catch |e| {
            std.debug.print("{t}\n", .{e});
            return;
        };
        defer self.alloc.free(dir);
        @constCast(&(std.fs.openDirAbsolute(dir, .{}) catch |e| {
            std.debug.print("{t}\n", .{e});
            return;
        })).setAsCwd() catch |e| {
            std.debug.print("{t}\n", .{e});
            return;
        };
    }

    pub fn cwd(self:*Term) std.fs.Dir {
        _ = self;
        return std.fs.cwd();
    }

    pub fn deinit(self:*Term) void {
        _ = self.env.deinit();
    }

    pub fn revert(self:*Term) !void {
        try std.posix.tcsetattr(
            self.stdin_file.handle,
            .FLUSH,
            self.og
        );
    }
    pub fn mk_raw(self:*Term) !void {
        try std.posix.tcsetattr(
            self.stdin_file.handle,
            .FLUSH,
            self.raw
        );
    }

    pub fn colorize(self:*Term, in:[]u8) ![]u8 {
        const alloc = self.alloc;
        var res = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer _ = res.deinit(alloc);

        const peek = parser.peek_no_state;
        const peekN = parser.peekN_no_state;

        var i:isize = 0;
        var colorize_next:usize = 0;
        var string:u8 = 0;

        while (i < in.len) : (i += 1) {
            const b = in[@intCast(i)];

            var j:usize = @intCast(i);
            var next:usize = @intCast(i+1);

            switch (b) {

                '#' => if (string == 0) {
                    try res.appendSlice(alloc, "\x1b[0;3;38;2;115;115;150m");
                    for (in[j..]) |c| try res.append(alloc, c);
                    break;
                },

                '$' => {
                    const name = try parser.seek_var_name(alloc, in, &j);
                    defer alloc.free(name);
                    colorize_next = name.len + 1;
                },

                '"', '\'' => string =
                    if (string == 0)
                        b
                    else if (string != b)
                        string
                    else {
                        try res.appendSlice(alloc, "\x1b[33m\""); 
                        string = 0;
                        continue;
                    },

                // TODO: change this (currently breaks cursor position)
                '\t' => {
                    try res.append(alloc, ' ');
                    continue;
                },

                '\\' => {
                    try res.appendSlice(alloc, "\x1b[34m");
                    colorize_next = if (in.len > i+1) switch (in[@intCast(i+1)]) {

                        '0'...'3' => for ([_]bool{
                            peek(in, &j) >= '0',
                            peek(in, &j) <= '7',
                            peek(in, &next) >= '0',
                            peek(in, &next) <= '7',
                            peek(in, @constCast(&@as(usize, next+1))) >= '0',
                            peek(in, @constCast(&@as(usize, next+1))) <= '7',
                        }) |check| {
                            if (!check) break 1;
                        } else 4,

                        'x' => for (peekN(in, j+1, 3)) |c| {
                            break for ([_]bool{
                                c >= '0' and c <= '9',
                                c >= 'a' and c <= 'f',
                                c >= 'A' and c <= 'F',
                            }) |check| {
                                if (check) break @as(u8, 4);
                            } else @as(u8, 1);
                        } else @as(u8, 1),

                        '#' => {
                            try res.appendSlice(alloc, "\\#");
                            i += 1;
                            continue;
                        },

                        else => 1,
                    } else 1;
                },

                else => {},
            }

            try res.appendSlice(alloc, "\x1b[0m");

            if (string != 0)
                try res.appendSlice(alloc, "\x1b[33m");

            if (colorize_next > 0) {
                try res.appendSlice(alloc, "\x1b[34m");
                colorize_next -= 1;
            }

            try res.append(alloc, b);
            try res.appendSlice(alloc, "\x1b[0m");
        }
        return res.toOwnedSlice(alloc);
    }
};
