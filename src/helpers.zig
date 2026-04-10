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
            "handle " ++ (if (done) |_| "|{c}| ({x}) " else "") ++ "[{s}] {{{x}}} " ++ context,
            if (done) |_| .{ buf[i+1], buf[i+1], buf, buf } else .{ buf, buf }
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
