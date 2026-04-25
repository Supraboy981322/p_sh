const std = @import("std");
const glob = @import("glob");
const Term = @import("term.zig").Term;

pub fn match(term:*Term, pattern:[]u8) ![][]u8 {
    var cwd = try term.cwd();

    var res = try std.ArrayList([]u8).initCapacity(term.alloc, 1);
    defer res.deinit(term.alloc);

    var itr = cwd.iterate();
    while (try itr.next(term.io)) |entry| if (glob.match(pattern, entry.name)) {
        try res.append(term.alloc, try term.alloc.dupe(u8, entry.name));
    };

    if (res.items.len < 1)
        return error.NoMatches;

    return try res.toOwnedSlice(term.alloc);
}
