const std = @import("std");
const Term = @import("term.zig").Term;

pub const State = struct {
    file:std.fs.File,
    reader:*std.fs.File.Reader,
    term:*Term,
    reader_buf:[std.fs.max_path_bytes + 1024]u8 = undefined,
    ignore:bool = false,

    pub const Names = enum {
        PWD,
    };

    pub fn next(self:*State) !?struct { field:Names, value:[]u8 } {
        var buf = try std.ArrayList(u8).initCapacity(self.term.alloc, 0);
        defer buf.deinit(self.term.alloc);
        var name:?Names = undefined;
        _ = self.reader.interface.peekByte() catch |e|
            if (e == error.EndOfStream)
                return null;
        while (
            self.reader.interface.takeByte() catch |e|
                if (e != error.EndOfStream)
                    return e
                else
                    null
        ) |b| {
            switch (b) {

                '\n' => if (buf.items.len > 0 and name != null) {
                    return .{ .field = name.?, .value = try buf.toOwnedSlice(self.term.alloc) };
                } else if (name) |n| {
                    self.term.print_error(
                        \\state file field missing value ({s})
                        \\  HINT: key-value pairs must be on same line
                    , .{ @tagName(n) });
                    return error.MissingValue;
                },

                '=' => {
                    defer buf.clearAndFree(self.term.alloc);
                    name = std.meta.stringToEnum(Names, buf.items) orelse {
                        _ = try self.reader.interface.discardDelimiterInclusive('\n');
                        continue;
                    };
                },

                else => try buf.append(self.term.alloc, b),
            }
        }
        return if (name) |n| .{
            .field = n,
            .value = try buf.toOwnedSlice(self.term.alloc),
        } else
            null;
    }

    fn internal_init(term:*Term) !State {
        const home = term.env.get("HOME") orelse return error.NoHome;
        const path = try std.fs.path.join(term.alloc, &.{ home, ".cache", "p_sh_state" });
        defer term.alloc.free(path);
        var file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |e| b: {
            if (e == error.FileNotFound) {
                break :b try std.fs.createFileAbsolute(path, .{ .read = true });
            } else
                return e; //failed to open state file (~/.cache/p_sh_state)
        };

        var res:State = .{
            .term = term,
            .file = file,
            .reader = undefined,
        };
        var reader = file.reader(&res.reader_buf);
        res.reader = &reader;
        return res;
    }

    pub fn init(term:*Term) !State {
        var state = internal_init(term) catch |e|
            return if (e != error.NoHome)
                e
            else .{
                .file = undefined,
                .term = term,
                .ignore = true,
                .reader = undefined
            };

        defer state.file.close();

        if ((try state.file.stat()).size == 0) for ([_][]const u8{
            "PWD=", @constCast(try term.get_env_orerr("PWD")), "\n",
        }) |chunk| {
            _ = try state.file.write(chunk);
        };

        try state.file.seekTo(0);

        while (state.next() catch |e| return e) |pair| {
            defer term.alloc.free(pair.value);
            switch (pair.field) {
                .PWD => try term.env.put("OLDPWD", pair.value),
            }
        }

        return state;
    }

    pub fn update(self:*State) void {
        _ = self;
    }
};
