const std = @import("std");
const Term = @import("term.zig").Term;

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

    var buf:[1024]u8 = undefined;
    var reader = file.reader(&buf).interface;
    while (
        reader.takeDelimiterExclusive('\n') catch |e|
            if (e != error.EndOfStream)
                return e
            else
                null
    ) |line| {
        std.debug.print("{s}\n", .{line});
    }
}
