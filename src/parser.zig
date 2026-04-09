const std = @import("std");

const Term = @import("term.zig").Term;

pub fn split_args(in:[]u8, term:*Term) ![]const []const u8 {
    const alloc = term.alloc;
    var res = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    var mem = try std.ArrayList(u8).initCapacity(alloc, 0);
    var mem2 = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer {
        _ = mem.deinit(alloc);
        _ = mem2.deinit(alloc);
        _ = res.deinit(alloc);
    }
    var str_type:u8, var esc:bool = .{ 0, false };
    var i:usize = 0;
    loop: while (i < in.len) : (i += 1) {
        const b = in[i];
        if (esc) {
            if (!std.ascii.isWhitespace(b)) switch (b) {
                '"', '\'', '$', '#' => {},
                else => try mem.append(alloc, '\\'),
            };
            try mem.append(alloc, b);
            esc = false;
            continue :loop;
        }
        switch (b) {

            '"', '\'' => {
                if (str_type == b or str_type == 0)
                    str_type = if (str_type == 0) b else 0
                else
                    try mem.append(alloc, b);
            },

            '#' =>
                if (str_type == 0)
                    break :loop
                else
                    try mem.append(alloc, b),

            '\\' => { esc = true; },

            '$' => {
                const var_name = try seek_var_name(alloc, in, &i);
                const value = term.env.get(var_name);
                if (value) |v| try mem.appendSlice(alloc, v);
            },

            ' ', '\n', '\r', '\t' => if (str_type == 0) if (mem.items.len > 0) {
                try res.append(alloc, try mem.toOwnedSlice(alloc));
                mem.clearAndFree(alloc);
            } else {} else
                try mem.append(alloc, b),

            else => { try mem.append(alloc, b); },
        }
    }
    if (mem.items.len > 0)
        try res.append(alloc, try mem.toOwnedSlice(alloc));
    return try res.toOwnedSlice(alloc);
}

pub fn seek_var_name(alloc:std.mem.Allocator, in:[]u8, i:*usize) ![]u8 {
    var mem = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = mem.deinit(alloc);

    i.* += 1;
    loop: while (i.* < in.len) : (i.* += 1) {
        if (std.ascii.isAlphabetic(in[i.*]) or std.ascii.isDigit(in[i.*]))
            try mem.append(alloc, in[i.*])
        else
            break :loop;
    }

    return mem.toOwnedSlice(alloc);
}

pub fn peek_no_state(in:[]u8, i:*usize) u8 {
    if (in.len <= i.* + 1) return 0;
    return in[i.* + 1];
}

pub fn peekN_no_state(in:[]u8, i:usize, comptime n:usize) [n]u8 {
    var buf:[n]u8 = undefined;
    for (0..n) |j| buf[j] = peek_no_state(in, @constCast(&(i + j)));
    return buf;
}
