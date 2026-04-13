const std = @import("std");
const parser = @import("parser.zig");
const exec = @import("exec.zig");
const globs = @import("globs.zig");
const hlp = @import("helpers.zig");

const Hist = globs.Hist;
const Cmd = exec.Cmd;

pub const Term = struct {
    og:std.os.linux.termios,
    raw:std.os.linux.termios,

    stdin_file:*std.fs.File,
    stdout_file:*std.fs.File,
    stderr_file:*std.fs.File,

    alloc:std.mem.Allocator,
    env:std.process.EnvMap,

    permanent_alloc:std.mem.Allocator,
    hist:*Hist,

    vars:struct {
        aliases:?std.StringHashMap([]u8) = null,
    } = .{},


    pub fn print_error(
        self:*Term,
        comptime msg:[]const u8,
        stuff:anytype
    ) void {
        var stderr = @constCast(&self.stderr_file.writer(&.{})).interface;
        stderr.print("\n" ++ msg ++ "\n", stuff) catch {
            std.debug.panic("\n" ++ msg ++ "\n", stuff); //print...catch { ... }
        };
        stderr.flush() catch {
            std.debug.panic("\n" ++ msg ++ "\n", stuff); //flush...catch { ... }
        };
    }

    pub fn message(
        self:*Term,
        comptime msg:[]const u8,
        stuff:anytype
    ) void {
        self.print("\np_sh: " ++ msg ++ "\n", stuff);
    }

    pub fn print(
        self:*Term,
        comptime msg:[]const u8,
        stuff:anytype
    ) void {
        var stdout = @constCast(&self.stdout_file.writer(&.{})).interface;
        stdout.print(msg, stuff) catch {};
        stdout.flush() catch {};
    }

    pub fn TODO(
        self:*Term,
        comptime msg:[]const u8,
        stuff:anytype,
    ) void {
        self.print_error( "TODO: " ++ msg ++ "\n", stuff);
    }
    
    pub fn init(
        alloc:std.mem.Allocator,
        stdin:*std.fs.File,
        stderr:*std.fs.File,
        stdout:*std.fs.File,
        env:?std.process.EnvMap,
        hist:*Hist,
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
            .permanent_alloc = alloc,
            .hist = hist,
        };
        try res.cd(@constCast("."));
        res.read_config() catch |e|
            if (e == error.FileNotFound)
                res.print_error(
                    "no config file found ({s}/.p_shrc); using default settings",
                    .{res.env.get("HOME") orelse "$HOME"}
                )
            else
                res.print_error("failed to read config: {t}", .{e});
        return res;
    }

    pub fn cd(self:*Term, path:[]u8) !void {
        const dir = self.cwd().realpathAlloc(self.alloc, path) catch |e| {
            self.print_error("{t}", .{e});
            return;
        };
        defer self.alloc.free(dir);
        @constCast(&(std.fs.openDirAbsolute(dir, .{}) catch |e| {
            self.print_error("{t}", .{e});
            return;
        })).setAsCwd() catch |e| {
            self.print_error("{t}", .{e});
            return;
        };
    }

    pub fn cwd(self:*Term) std.fs.Dir {
        _ = self;
        return std.fs.cwd();
    }

    pub fn deinit(self:*Term) void {
        _ = self.env.deinit();
        if (self.vars.aliases) |*const_aliases| {
            var aliases = @constCast(const_aliases);
            var itr = aliases.iterator();
            while (itr.next()) |alias| {
                self.permanent_alloc.free(alias.key_ptr.*);
                self.permanent_alloc.free(alias.value_ptr.*);
            }
            aliases.deinit();
        }
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

    pub fn is_in_path(self:*Term, name:[]u8) !bool {
        if (std.meta.stringToEnum(exec.Builtins, name) orelse null) |_| return true;
        if (std.fs.path.isAbsolute(name)) return true;
        const path = self.env.get("PATH") orelse "/bin:/usr/bin";
        var itr = std.mem.tokenizeScalar(u8, path, ':');
        loop: while (itr.next()) |dir| {
            const joined = try std.fs.path.join(self.alloc, &.{ dir, name }); 
            defer self.alloc.free(joined);
            var buf:[std.fs.max_path_bytes]u8 = undefined;
            _ = std.fs.realpath(joined, &buf) catch |e| switch (e) {
                error.FileNotFound => continue :loop,
                else => return false,
            };
            return true;
        }
        return false;
    }
    
    pub fn pretty_path(self:*Term) ![]u8 {
        const raw = try self.cwd().realpathAlloc(self.alloc, ".");
        const home = self.env.get("HOME") orelse return raw;
        if (std.mem.startsWith(u8, raw, home)) {
            defer self.alloc.free(raw);
            return try std.mem.replaceOwned(u8, self.alloc, raw, home, "~");
        } else
            return raw;
    }

    pub fn read_config(term:*Term) !void {
        try @import("config.zig").read(term);
    }

    pub fn replace_aliases(term:*Term, res:*std.ArrayList(Cmd)) !void {
        const aliases = term.vars.aliases orelse return;
        for (res.items) |*cmd| {
            const split = try parser.split_args(cmd.raw, term);
            const argv = try hlp.to_regular_map(split, term.alloc);
            if (aliases.get(argv[0])) |alias| {
                cmd.raw = try std.mem.concat(term.alloc, u8, &[_][]u8{
                    alias,
                    @constCast(" "),
                    try std.mem.concat(term.alloc, u8, argv[1..]),
                });
            }
        }
    }
};
