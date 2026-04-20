const std = @import("std");
const Term = @import("term.zig").Term;

pub const Names = enum {
    PWD,
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
        "PWD=", @constCast(try term.get_env_orerr("PWD")), "\n",
    }) |chunk| {
        _ = try file.write(chunk);
    };

    try file.seekTo(0);
    var reader_buf:[std.fs.max_path_bytes + 1024]u8 = undefined;
    var reader = file.reader(&reader_buf);
    var buf = try std.ArrayList(u8).initCapacity(term.alloc, 0);
    defer buf.deinit(term.alloc);
    var name:Names = undefined;
    while (
        reader.interface.takeByte() catch |e|
            if (e != error.EndOfStream)
                return e
            else
                null
    ) |b| {
        switch (b) {
            '\n' => if (buf.items.len > 0) {
                std.debug.print("{s}={s}\n", .{@tagName(name), buf.items});
                switch (name) {
                    .PWD => {
                        try term.env.put("OLDPWD", buf.items);
                    }
                }
                buf.clearAndFree(term.alloc);
            },
            '=' => {
                name = std.meta.stringToEnum(Names, buf.items) orelse {
                    _ = try reader.interface.discardDelimiterInclusive('\n');
                    continue;
                };
                buf.clearAndFree(term.alloc);
            },
            else => try buf.append(term.alloc, b),
        }
    }
}
