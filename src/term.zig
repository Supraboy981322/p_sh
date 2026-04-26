const std = @import("std");
const zeit = @import("zeit");
const parser = @import("parser.zig");
const exec = @import("exec.zig");
const globs = @import("globals.zig");
const hlp = @import("helpers.zig");
const posix = @import("posix.zig");
const State = @import("state.zig").State;

const Hist = globs.Hist;
const Cmd = exec.Cmd;

pub const Term = struct {
    og:std.os.linux.termios,
    raw:std.os.linux.termios,

    stdin_file:*std.Io.File,
    stdout_file:*std.Io.File,
    stderr_file:*std.Io.File,
    io:std.Io,

    stderr:*std.Io.Writer,
    stdout:*std.Io.Writer,

    coms:[2]std.posix.fd_t,

    alloc:std.mem.Allocator,
    env:std.process.Environ.Map,

    permanent_alloc:std.mem.Allocator,
    hist:*Hist,

    vars:struct {
        aliases:?std.StringHashMap([]u8) = null,
    } = .{},

    config:Config,
    state:State,

    start_ok:bool = false,

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
        var stderr = @constCast(&self.stderr_file.writer(self.io, &.{})).interface;
        const altered = "\n" ++ msg ++ "\n";
        stderr.print(altered, stuff) catch
            std.debug.print(altered, stuff);
        stderr.flush() catch
            std.debug.print(altered, stuff);
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
        stdin:*std.Io.File,
        stderr:*std.Io.File,
        stdout:*std.Io.File,
        //env:?std.process.Environ.Map,
        stuff:std.process.Init,
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
            .stderr = &@constCast(&stderr.writer(stuff.io, &.{})).interface,
            .stdout = &@constCast(&stdout.writer(stuff.io, &.{})).interface,
            .io = stuff.io,
            .alloc = alloc,
            .env = undefined,//if (env) |e| e else try std.process.getEnvMap(alloc),
            .permanent_alloc = alloc,
            .hist = hist,
            .config = .{},
            .state = undefined,
            .coms = try posix.new_pipe(),
        };

        res.env = try stuff.environ_map.clone(res.alloc);
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

        var buf:[1024]u8 = undefined;
        var writer = &@constCast(&stderr.writer(res.io, &buf)).interface;

        res.state = State.init(&res) catch |e| {
            try writer.print("failed to init state file: {t}\n\n", .{e});
            return res;
        };

        res.start_ok = true;

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
        const dir = (try self.cwd()).realPathFileAlloc(self.io, path, self.alloc) catch |e| {
            self.print_error("{t}", .{e});
            return e;
        };
        defer self.alloc.free(dir);
        const opened = std.Io.Dir.openDirAbsolute(self.io, dir, .{ .iterate = true }) catch |e| {
            self.print_error("{t}", .{e});
            return e;
        };
        std.process.setCurrentDir(self.io, opened) catch |e| {
            self.print_error("{t}", .{e});
            return e;
        };
        try self.env.put("PWD", dir);
        if (self.start_ok)
            self.state.update(self) catch |e|
                self.print_error("failed to update state file: {t}", .{e}
            );
    }

    pub fn cwd(self:*Term) !std.Io.Dir {
        return try std.Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true });
    }

    pub fn cwd_path(self:*Term, alloc:std.mem.Allocator) ![]u8 {
        const elderly = try (try self.cwd()).realPathFileAlloc(self.io, ".", alloc);
        const reasonable = try alloc.dupe(u8, std.mem.absorbSentinel(elderly)[0..elderly.len]);
        alloc.free(elderly);
        return reasonable;
    }

    pub fn deinit(self:*Term) void {
        self.env.deinit();
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
            _ = (try self.cwd()).realPathFile(self.io, joined, &buf) catch |e| switch (e) {
                error.FileNotFound => continue :loop,
                else => return false,
            };
            return true;
        }
        return false;
    }
    
    pub fn pretty_path(self:*Term) ![]u8 {
        const raw = try (try self.cwd()).realPathFileAlloc(self.io, ".", self.alloc);
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
            if (argv.len < 1) continue;
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
        blk: {
            var buf:[std.posix.HOST_NAME_MAX]u8 = undefined;
            const hostname = std.posix.gethostname(&buf) catch |e| {
                term.print_error("failed to get hostname: {t}", .{e});
                break :blk;
            };
            term.env.put("HOSTNAME", hostname) catch unreachable;
        }
    }

    pub fn get_env_orerr(self:*Term, name:[]const u8) ![]const u8 {
        return self.env.get(name) orelse error.EnvMissingValue;
    }

    pub fn action(self:*Term, stuff:@import("coms.zig").Action) !void {
        switch (stuff.action) {
            .chdir => self.cd(stuff.stuff) catch |e| {
                self.print_error("cannot change directory:\n\t{t}", .{
                    switch (e) {
                        error.FileNotFound => error.@"no such file or directory",
                        else => e,
                    }
                });
                return e;
            },
            .reload => {
                self.read_config() catch |e|
                    if (e == error.FileNotFound)
                        self.print_error(
                            "no config file found ({s}/.p_shrc); using default settings",
                            .{ self.env.get("HOME") orelse "$HOME" }
                        )
                    else
                        self.print_error("failed to read config: {t}", .{e});
            },

            .config => {
                var itr = std.mem.splitAny(u8, stuff.stuff, "|");
                self.config.set(self, @constCast(itr.first()), @constCast(itr.next().?));
            },

            .alias => {
                var itr = std.mem.splitAny(u8, stuff.stuff, "|");
                const alloc = self.permanent_alloc;
                const name = try alloc.dupe(u8, itr.first());
                const value = try alloc.dupe(u8, itr.next().?);
                if (self.vars.aliases == null)
                    self.vars.aliases = std.StringHashMap([]u8).init(alloc);
                try self.vars.aliases.?.put(name, value);
            },

            .EXIT, .code => unreachable,

            .msg => self.print_error("{s}", .{stuff.stuff}),
        }
    }

    pub fn build_ps1(self:*Term, ps1_char:u8) ![]u8 {
        const ps1_char_colorized = try std.fmt.allocPrint(
            self.alloc, "\x1b[3{d}m{c}\x1b[0m",
            .{
                @as(u2, if (ps1_char == '!') 1 else 2),
                ps1_char,
            }
        );

        const raw = self.env.get("PS1") orelse
            "\x1b[0m\r\x1b[2K\x1b[3;36m[\x1b[35m{cwd}\x1b[3;36m]"
                ++ "(\x1b[0m{char}\x1b[3;36m):\x1b[0m";

        const resolved = try parser.resolve_string(self.alloc, @constCast(raw), self);

        var res = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        defer res.deinit(self.alloc);

        var i:usize = 0;
        var esc:bool = false;
        while (i < resolved.len) : (i += 1) {
            if (esc) {
                esc = false;
                try res.append(self.alloc, resolved[i]);
                continue;
            }
            switch (resolved[i]) {
                '}' => {
                    if (resolved[i+1] == '}' and !esc) esc = true;
                    continue;
                },
                '{' => if (resolved[i+1] != '{' and !esc) {
                    i += 1;
                    const start:usize = i;
                    while (resolved[i] != '}') : (i += 1) {}
                    const Valid = enum {
                       @"_", char, cwd, time, hostname, host,
                    };
                    const foo = std.meta.stringToEnum(Valid, resolved[start..i]) orelse .@"_";
                    switch (foo) {
                        .@"_" => {},
                        .cwd => {
                            try res.appendSlice(self.alloc, try self.pretty_path());
                        },
                        .char => try res.appendSlice(self.alloc, ps1_char_colorized),
                        .time => {
                            const now = try zeit.instant(self.io, .{});
                            const zeit_conf = zeit.EnvConfig{
                                .tz = self.env.get("TZ"),
                                .tzdir = self.env.get("TZDIR"),
                            };
                            const local = try zeit.local(self.alloc, self.io, zeit_conf);
                            const now_local = now.in(&local);
                            const dt = now_local.time();
                            var buf:[7]u8 = undefined;
                            var wr = std.Io.Writer.fixed(&buf);
                            try dt.gofmt(&wr, "03:04pm");
                            try res.appendSlice(self.alloc, &buf);
                        },
                        .hostname, .host => {
                            const hostname = self.env.get("HOSTNAME") orelse unreachable;
                            try res.appendSlice(self.alloc, hostname);
                        },
                    }
                    continue;
                } else { esc = true; continue; },
                else => {},
            }
            try res.append(self.alloc, resolved[i]);
        }
        try res.appendSlice(self.alloc, "\x1b[0m");
        return try res.toOwnedSlice(self.alloc);
    }
};
