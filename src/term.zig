const std = @import("std");
const parser = @import("parser.zig");
const exec = @import("exec.zig");
const globs = @import("globs.zig");
const hlp = @import("helpers.zig");

pub const Term = struct {
    og:std.os.linux.termios,
    raw:std.os.linux.termios,

    stdin_file:*std.fs.File,
    stdout_file:*std.fs.File,
    stderr_file:*std.fs.File,

    alloc:std.mem.Allocator,
    env:std.process.EnvMap,

    permanent_alloc:std.mem.Allocator,

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

    pub fn read_config(term:*Term) !void {
        const Category = enum{ aliases };

        const home_dir = term.env.get("HOME") orelse return;
        const config_path = b: {
            var buf:[std.fs.max_path_bytes]u8 = undefined;
            var wr = std.Io.Writer.fixed(&buf);
            var formatter = std.fs.path.fmtJoin(&.{ home_dir, ".p_shrc"}); 
            try formatter.format(&wr);
            break :b buf[0..wr.end];
        };

        var config_file = try term.cwd().openFile(config_path, .{});
        var buf:[1024]u8 = undefined;
        var reader = &@constCast(&config_file.reader(&buf)).interface;
        defer config_file.close();

        const alloc = term.permanent_alloc;

        var value = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer value.deinit(alloc);
        
        var key = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer key.deinit(alloc);

        var aliases = std.StringHashMap([]u8).init(alloc);

        var string:u8 = 0;
        var esc:bool = false;
        var key_or_value:enum{ KEY, VALUE } = .KEY;
        var category:?Category = null;

        loop: while (reader.takeByte() catch null) |b| {
            if (std.ascii.isWhitespace(b) and string == 0 and !esc) {
                if (value.items.len > 0) {
                    try aliases.put(
                        try key.toOwnedSlice(alloc),
                        try value.toOwnedSlice(alloc)
                    );
                    key.clearAndFree(alloc);
                    value.clearAndFree(alloc);
                    key_or_value = .KEY;
                }
                continue :loop;
            }

            if (string != 0) {
                switch (b) {
                    '\\' => {
                        esc = true;
                        continue :loop;
                    },
                    '"', '\'' => {
                        if (string == b) {
                            string = 0;
                            continue :loop;
                        }
                        if (key_or_value == .VALUE)
                            try value.append(alloc, b)
                        else
                            try key.append(alloc, b);
                    },
                    else => {
                        if (key_or_value == .VALUE)
                            try value.append(alloc, b)
                        else
                            try key.append(alloc, b);
                    },
                }
            } else if (!esc) switch (b) {
                '\\' => esc = true,
                '"' => {
                    if (string == b or string == 0) {
                        string = if (string == 0) b else 0;
                        continue :loop;
                    }
                    if (key_or_value == .VALUE)
                        try value.append(alloc, b)
                    else
                        try key.append(alloc, b);
                },
                '(' => {
                    const key_name = try key.toOwnedSlice(alloc);
                    category = std.meta.stringToEnum(Category, key_name) orelse {
                        std.debug.panic("invalid category: {s}\n", .{key_name});
                        unreachable;
                    };
                    alloc.free(key_name);
                    value.clearAndFree(alloc);
                    continue :loop;
                },
                ')' => {
                    if (category == null) 
                        std.debug.panic("unexpected closing brace", .{});
                    category = null;
                    continue :loop;
                },
                '=' => {
                    if (category) |_| key_or_value = .VALUE;
                    continue :loop;
                },
                else => {
                    if (key_or_value == .VALUE)
                        try value.append(alloc, b)
                    else
                        try key.append(alloc, b);
                },
            };
        }
        term.vars.aliases = aliases;
    }
};
