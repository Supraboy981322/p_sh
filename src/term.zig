const std = @import("std");
const parser = @import("parser.zig");
const exec = @import("exec.zig");
const globs = @import("globs.zig");
const hlp = @import("helpers.zig");
const State = @import("state.zig").State;

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

    config:Config,
    state:State,

    pub const Config = struct {
        //level of colorizing in interactive
        //  0 = none (at all)
        //  1 = only invalid command names
        //  2 = 1 + command args
        colorizing_level:u2 = 2,
        start_in_OLDPWD:bool = false,

        const ValidOpts = enum {
            @"colorizing_level",
            @"start_in_previous_dir",
        };

        pub fn set(self:*Config, term:*Term, key:[]u8, value:[]u8) void {
            const name = std.meta.stringToEnum(ValidOpts, key) orelse {
                term.print_error("invalid config option: {s}", .{key});
                return;
            };
            switch (name) {
                .colorizing_level => {
                    const is_valid =
                        if (value.len == 1)
                            value[0] >= '0' and value[0] <= '2'
                        else
                            false;
                    if (!is_valid) {
                        term.print_error(
                            "invalid config value (\"{s}\"): |{s}|, "
                                ++ "expected a number from 0-2",
                        .{key, value});
                        return;
                    }
                    self.colorizing_level = @intCast(value[0] - '0');
                },
                .start_in_previous_dir => {
                    self.start_in_OLDPWD = hlp.parse_bool(value) catch {
                        term.print_error(
                            \\invalid config falue ("{s}") for {s}
                            \\  HINT: expected a boolean ('true' or 'false')
                        , .{ value, key });
                        return;
                    };
                }
            }
        }
    };

    pub fn print_error(
        self:*Term,
        comptime msg:[]const u8,
        stuff:anytype
    ) void {
        var stderr = @constCast(&self.stderr_file.writer(&.{})).interface;
        stderr.print("\n" ++ msg ++ "\n", stuff) catch {};
        stderr.flush() catch {};
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
            .config = .{},
            .state = undefined,
        };

        res.init_env();

        try res.cd(@constCast("."));

        res.read_config() catch |e|
            if (e == error.FileNotFound)
                res.print_error(
                    "no config file found ({s}/.p_shrc); using default settings",
                    .{res.env.get("HOME") orelse "$HOME"}
                )
            else
                res.print_error("failed to read config: {t}", .{e});

        res.state = State.init(&res) catch |e| {
            for ([_][]const u8{
                "failed to init state file: ", @errorName(e), "\n\n"
            }) |chunk| {
                _ = stderr.write(chunk) catch {};
            }
            return res;
        };

        if (res.config.start_in_OLDPWD) {
            if (res.env.get("OLDPWD")) |old| {
                const dir = try res.alloc.dupe(u8, old);
                defer res.alloc.free(dir);
                try res.cd(dir);
            } else res.print_error(
                "failed to start in OLDPWD: $OLDPWD not set" , .{}
            );
        }

        return res;
    }

    pub fn cd(self:*Term, path:[]u8) !void {
        const old = try self.cwd_path(self.alloc);
        defer self.alloc.free(old);
        try self.env.put("OLDPWD", old);
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
        try self.env.put("PWD", dir);
    }

    pub fn cwd(self:*Term) std.fs.Dir {
        _ = self;
        return std.fs.cwd();
    }

    pub fn cwd_path(self:*Term, alloc:std.mem.Allocator) ![]u8 {
        return try self.cwd().realpathAlloc(alloc, ".");
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
            defer term.alloc.free(std.mem.span(split));
            var argv = try hlp.to_regular_map(split, term.alloc);
            defer term.alloc.free(argv);
            _ = &argv;
            if (aliases.get(argv[0])) |alias| {
                term.alloc.free(argv[0]);
                @constCast(argv)[0] = alias;
                cmd.raw = try std.mem.join(term.alloc, " ", argv);
            } else {
                for (argv) |arg|
                    term.alloc.free(arg);
            }
        }
    }

    pub fn is_alias(term:*Term, name:[]u8) bool {
        return if (term.vars.aliases) |aliases|
            aliases.get(name) != null
        else
            false;
    }

    pub fn init_env(term:*Term) void {
        {
            const shlvl = term.env.get("SHLVL");
            if (shlvl) |lvl| {
                var v:usize = 0;
                for (lvl) |b| {
                    if (b >= '0' and b <= '9') {
                        v *= 10;
                        v += b - '0';
                    } else
                        unreachable; //$SHLVL invalid bytes
                }
                var buf:[1024]u8 = undefined; // TODO: will this ever be too small?
                const n = std.fmt.printInt(&buf, v+1, 10, .lower, .{});
                term.env.put("SHLVL", buf[0..n]) catch unreachable;
            } else
                term.env.put("SHLVL", "1") catch unreachable;
        }
    }

    pub fn get_env_orerr(self:*Term, name:[]const u8) ![]const u8 {
        return self.env.get(name) orelse error.EnvMissingValue;
    }
};
