const std = @import("std");
const Term = @import("term.zig").Term;

pub fn contains(list:[]u8, thing:u8) bool {
    return for (list) |itm| {
        if (thing == itm) break true;
    } else
        false;
}

pub fn peek_or_todo(term:Term, buf:[]u8, i:usize, comptime done:?u8, comptime context:[]const u8) bool {
    if (buf.len <= i+1) return false;
    if (buf[i+1] == done)
        return true
    else
        @constCast(&term).TODO(
            "\n\thandle " ++ (if (done) |_| "|{c}| ({x}) " else "") ++ "{{{x}}} " ++ context,
            if (done) |_| .{ buf[i+1], buf[i+1], buf } else .{ buf }
        );
    return false;
}

pub fn pop_idx(term:*Term, alloc:std.mem.Allocator, comptime T:type, list:*std.ArrayList(T), pos:usize) !?T {
    if (list.items.len <= pos) return null;
    const before = try term.alloc.dupe(u8, list.items[0..pos+1]);
    const after = try term.alloc.dupe(u8, list.items[pos+1..]);
    list.clearAndFree(alloc);
    try list.appendSlice(alloc, before);
    const thing = list.pop();
    try list.appendSlice(alloc, after);
    return thing;
}

pub fn determine_exit_code(e:anyerror) u8 {
    return switch (e) {
        error.NotEnoughArgs,
            => 2,

        error.CommandNotFound,
            => 127,

        error.AccessDenied,
        error.PermissionDenied,
            => 126,

        error.FileNotFound,
            => 1, // TODO: probably a better code for this one

        else => 1,
    };
}

pub fn to_regular_map(
    in:[*:null]const ?[*:0]const u8,
    alloc:std.mem.Allocator
) ![]const []const u8 {
    var out = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer _ = out.deinit(alloc);
    for (std.mem.span(in)) |thing| if (thing) |t|
        try out.append(alloc, std.mem.span(t));
    return try out.toOwnedSlice(alloc);
}

pub fn lower_in_place(str:*[]u8) void {
    for (str.*, 0..) |b, i|
        str.*[i] = std.ascii.toLower(b);
}

pub fn parse_bool(str:[]u8) !bool {
    lower_in_place(@constCast(&str));
    const matched = std.meta.stringToEnum(
        enum{ @"true", @"false", @"1", @"0" }, str
    ) orelse {
        return error.InvalidBool;
    };
    return switch(matched) {
        .@"true", .@"1" => true,
        else => false,
    };
}

pub fn file_from_fd(fd:std.posix.fd_t) std.Io.File {
    return .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
}
