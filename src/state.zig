const std = @import("std");
const Term = @import("term.zig").Term;

pub const State = struct {
    file:std.Io.File,
    file_buf:std.ArrayList(u8) = .empty,
    term:*Term,
    reader_buf:[std.fs.max_path_bytes + 1024]u8 = undefined,
    writer_buf:[std.fs.max_path_bytes + 1024]u8 = undefined,
    ignore:bool = false,
    alloc:std.mem.Allocator,

    pub const Names = enum {
        PWD,
    };

    pub fn next(self:*State) !?struct { field:Names, value:[]u8 } {
        if (self.ignore) return null;

        var buf = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        defer buf.deinit(self.alloc);
        var name:?Names = undefined;
        var i:usize = self.file_buf.items.len;
        while (self.file_buf.pop()) |b| : ({ i = self.file_buf.items.len; }) {
            switch (b) {

                '\n' => if (buf.items.len > 0 and name != null) {
                    return .{ .field = name.?, .value = try buf.toOwnedSlice(self.alloc) };
                } else if (name) |n| {
                    self.term.print_error(
                        \\state file field missing value ({s})
                        \\  HINT: key-value pairs must be on same line
                    , .{ @tagName(n) });
                    return error.MissingValue;
                },

                '=' => {
                    defer buf.clearAndFree(self.alloc);
                    name = std.meta.stringToEnum(Names, buf.items) orelse {
                        while (self.file_buf.pop()) |c| if (c == '\n') break;
                        continue;
                    };
                },

                else => try buf.append(self.alloc, b),
            }
        }
        if (buf.items.len < 1) return null;
        return if (name) |n| .{
            .field = n,
            .value = try buf.toOwnedSlice(self.alloc),
        } else
            null;
    }

    fn internal_init(term:*Term, alloc:std.mem.Allocator) !State {
        var res:State = .{
            .term = term,
            .file = undefined,
            .alloc = alloc,
        };

        const home = term.env.get("HOME") orelse return error.NoHome;
        const path = try std.fs.path.join(res.alloc, &.{ home, ".cache", "p_sh_state" });
        defer alloc.free(path);

        var file = std.Io.Dir.openFileAbsolute(term.io, path, .{ .mode = .read_write }) catch |e| b: {
            if (e == error.FileNotFound) {
                break :b try std.Io.Dir.createFileAbsolute(term.io, path, .{ .read = true });
            } else
                return e; //failed to open state file (~/.cache/p_sh_state)
        };
        res.file = file;

        const content:[]u8 = try @constCast(&file.reader(term.io, &res.reader_buf).interface).allocRemaining(res.alloc, .unlimited);
        defer alloc.free(content);
        std.mem.reverse(u8, content);
        res.file_buf = .empty;
        try res.file_buf.appendSlice(res.alloc, content);

        return res;
    }

    pub fn init(term:*Term) !State {
        var state = internal_init(term, term.alloc) catch |e|
            return if (e != error.NoHome)
                e
            else .{
                .file = undefined,
                .term = term,
                .ignore = true,
                .alloc = undefined,
            };

        defer state.file.close(term.io);

        var file_writer = state.file.writer(term.io, &state.writer_buf);
        var writer = file_writer.interface;

        if ((try state.file.stat(term.io)).size == 0) for ([_][]const u8{
            "PWD=", @constCast(try term.get_env_orerr("PWD")), "\n",
        }) |chunk| {
            _ = try writer.writeAll(chunk);
        };

        try file_writer.seekTo(0);

        while (state.next() catch |e| return e) |pair| {
            defer state.alloc.free(pair.value);
            switch (pair.field) {
                .PWD => try term.env.put("OLDPWD", pair.value),
            }
        }

        state.file_buf.deinit(state.alloc);

        return state;
    }

    pub fn update(self:*State, term:*Term) !void {
        if (self.ignore) return;

        self.term = term;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        self.alloc = arena.allocator();

        const path = b: {
            const home = self.term.env.get("HOME") orelse return error.NoHome;
            break :b try std.fs.path.joinZ(self.alloc, &.{ home, ".cache", "p_sh_state" });
        };
        defer self.alloc.free(path);

        const old_name = try std.fs.path.joinZ(self.alloc, &.{
            std.fs.path.dirname(path).?, "p_sh_state.old"
        });
        defer self.alloc.free(old_name);

        const code = std.posix.system.rename(path.ptr, old_name.ptr);
        const errno = std.posix.errno(code);
        switch (errno) {
            .SUCCESS => {},
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .BUSY => return error.FileBusy,
            .DQUOT => return error.DiskQuota,
            .FAULT => unreachable,
            .INVAL => unreachable,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MLINK => return error.LinkQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .EXIST => return error.PathAlreadyExists,
            .NOTEMPTY => return error.PathAlreadyExists,
            .ROFS => return error.ReadOnlyFileSystem,
            .XDEV => return error.RenameAcrossMountPoints,
            else => |err| return std.posix.unexpectedErrno(err),
        }

        var new_file = try std.Io.Dir.createFileAbsolute(term.io, path, .{});
        self.file = try std.Io.Dir.openFileAbsolute(term.io, old_name, .{ .mode = .read_only });

        const content:[]u8 = try @constCast(&self.file.reader(term.io, &self.reader_buf).interface).allocRemaining(self.alloc, .unlimited);
        std.mem.reverse(u8, content);
        self.file_buf = .empty;
        try self.file_buf.appendSlice(self.alloc, content);
        var writer = &@constCast(&new_file.writer(term.io, &self.writer_buf)).interface;

        while (try self.next()) |pair| {
            defer self.alloc.free(pair.value);
            for ([_][]const u8{
                @tagName(pair.field),
                "=",
                switch (pair.field) {
                    .PWD => self.term.env.get("PWD").?,
                    //else => pair.value,
                },
                "\n",
            }) |chunk|
                _ = try writer.writeAll(chunk);
        }
        try std.Io.Dir.deleteFileAbsolute(term.io, old_name);
    }
};
