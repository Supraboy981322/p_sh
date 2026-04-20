const std = @import("std");
const Term = @import("term.zig").Term;

pub const Itr = struct {
    reader:*std.Io.Reader,

    pub fn init(file:std.fs.File) !Itr {
        var buf:[1024]u8 = undefined;
        var reader = file.reader(&buf).interface;
        return .{
            .reader = &reader,
        };
    }

    pub fn next(self:*Itr) !?struct { name:[]const u8, value:[]const u8 } {
        const line =
            self.reader.takeDelimiterExclusive('\n') catch |e|
                return if (e != error.EndOfStream)
                    e
                else
                    null;
        var split = std.mem.splitAny(u8, line, "=");
        return .{
            .name = split.first(),
            .value = split.next() orelse return error.MissingValue,
        };
    }
};

pub fn init(term:*Term) !void {
    const home = term.env.get("HOME") orelse return;
    const path = try std.fs.path.join(term.alloc, &.{ home, ".cache", "p_sh_state" });
    defer term.alloc.free(path);
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |e| b: {
        if (e == error.FileNotFound) {
            break :b try std.fs.createFileAbsolute(path, .{ .read = true });
        } else
            return e; //failed to open state file (~/.cache/p_sh_state)
    };
    defer file.close();

    if ((try file.stat()).size == 0) for ([_][]const u8{
        "SHLVL=", @constCast(try term.get_env_orerr("SHLVL")), "\n",
        "PWD=", @constCast(try term.get_env_orerr("PWD")), "\n",
    }) |chunk| {
        _ = try file.write(chunk);
    };
    var itr:Itr = try .init(file);
    while (try itr.next()) |pair| {
        const name = pair.name;
        const value = pair.value;
        std.debug.print("{s}={s}\n", .{name, value});
    }
}
