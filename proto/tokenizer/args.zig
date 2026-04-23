const std = @import("std");
const glob_lib = @import("glob");
const types = @import("types.zig");

const Cmd = types.Cmd;
const Token = types.Token;

//just splits a command by spaces and creates a slice of Cmd structs
//  to be populated later
pub fn split(alloc:std.mem.Allocator, src:[]u8) ![]Cmd {
    var res = try std.ArrayList(Cmd).initCapacity(alloc, 0);

    var mem = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = mem.deinit(alloc);

    var string_type:u8,
    var i:?usize,
        var b:u8 = .{
            0,
            null,
            0
        };
    while (if (i) |idx| idx < src.len else true) : ({
        i = if (i) |idx| idx + 1 else 0;
        if (i.? >= src.len) break;
        b = src[i.?];
    }) {
        switch (b) {
            '"' => {
                if (string_type == b)
                    string_type = 0
                else if (string_type == 0)
                    string_type = b;
            },

            ' ' =>
                if (string_type == 0) {
                    const new_arg:Token = .{
                        .value = .{
                            .string = .{
                                .value = try mem.toOwnedSlice(alloc)
                            },
                        },
                    };
                    if (res.pop()) |*cmd| {
                        var new = try alloc.alloc(Token, cmd.args.len + 1);
                        for (cmd.args, 0..) |arg, j|
                            new[j] = arg;
                        new[cmd.args.len] = new_arg; 
                        @constCast(cmd).args = new;
                        try res.append(alloc, cmd.*);
                    } else {
                        try res.append(alloc, .{
                            .name = try alloc.dupe(u8, new_arg.value.string.value),
                            .args = @constCast(&[_]Token{
                                new_arg,
                            }),
                        });
                    }
                },

            else => {},
        }
        if (!std.ascii.isWhitespace(b) or string_type != 0)
            try mem.append(alloc, b);
    }

    if (mem.items.len > 0) {
        const new_arg:Token = .{
            .value = .{
                .string = .{
                    .value = try mem.toOwnedSlice(alloc)
                },
            },
        };
        if (res.pop()) |*cmd| {
            var new = try alloc.alloc(Token, cmd.args.len + 1);
            for (cmd.args, 0..) |arg, j|
                new[j] = arg;
            new[cmd.args.len] = new_arg;
            @constCast(cmd).args = new;
            try res.append(alloc, cmd.*);
        } else {
            try res.append(alloc, .{
                .name = try alloc.dupe(u8, new_arg.value.string.value),
                .args = @constCast(&[_]Token{
                    new_arg,
                }),
            });
        }
    }

    return res.toOwnedSlice(alloc);
}

fn can_glob(thing:[]u8) bool {
    if (thing.len < 1) return false;
    if (thing[0] == '"' or thing[thing.len - 1] == '\'')
        return false;
    return true;
}

//in-place globbing (no new []Cmd, just modifies the arg slices)
pub fn glob(alloc:std.mem.Allocator, commands:*[]Cmd) !void {
    for (commands.*) |*cmd| for (cmd.args, 0..) |*arg, i| if (can_glob(arg.value.string.value)) {
        const pattern = arg.value.string.value;
        if (glob_lib.validate(pattern)) |_| {
            var arr = try alloc.alloc(Token, cmd.args[0..i].len);
            if (arr.len < 1) {
                alloc.free(arr);
                continue;
            }

            for (cmd.args[0..i], 0..) |a, j|
                arr[j] = a;

            const maybe_matches = match(alloc, pattern) catch |e| switch (e) {
                error.NoMatches => null,
                else => return e,
            };
            if (maybe_matches) |matches| {
                defer alloc.free(matches);
                @constCast(arg).free(alloc);

                var new = try alloc.alloc(Token, arr.len + matches.len - 1);
                for (arr, 0..) |a, j|
                    new[j] = a;
                for (matches, arr.len - 1..) |m, j|
                    new[j] = .{ .value = .{ .string = .{ .value = m } } };

                alloc.free(arr);
                arr = new;
            } else
                arr[arr.len-1] = arg.*;

            if (cmd.args[i..].len > 1) {
                var new = try alloc.alloc(Token, arr.len + cmd.args[i..].len);
                for (arr, 1..) |a, j|
                    new[j] = a;
                for (cmd.args[i..], arr.len-1..) |a, j|
                    new[j] = a;
                arr = new[0..new.len-1];
            }

            @constCast(cmd).args = arr;
        } else |err| {
            std.debug.print("{t}\n", .{err});
        }
    };
}

pub fn match(alloc:std.mem.Allocator, pattern:[]u8) ![][]u8 {
    var cwd = try std.fs.cwd().openDir(".", .{ .iterate = true });

    var res = try std.ArrayList([]u8).initCapacity(alloc, 1);
    defer res.deinit(alloc);

    var itr = cwd.iterate();
    while (try itr.next()) |entry| if (glob_lib.match(pattern, entry.name)) {
        try res.append(alloc, try alloc.dupe(u8, entry.name));
    };

    if (res.items.len < 1)
        return error.NoMatches;

    return try res.toOwnedSlice(alloc);
}
