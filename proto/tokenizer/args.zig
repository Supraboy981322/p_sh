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
                        if (cmd.args.len > 1)
                            alloc.free(cmd.args);
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
            alloc.free(cmd.args);
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

    return try res.toOwnedSlice(alloc);
}

fn can_glob(thing:[]u8) bool {
    if (thing.len < 1) return false;
    if (thing[0] == '"' or thing[thing.len - 1] == '\'')
        return false;
    return true;
}

//for each Cmd in []Cmd, creates new []Token with globs expanded,
//  and replaces Cmd's .args field with new (expanded) []Token
pub fn glob(alloc:std.mem.Allocator, commands:*[]Cmd) !void {
    for (commands.*) |*cmd| {
        var res = try std.ArrayList(Token).initCapacity(alloc, 0);
        defer _ = res.deinit(alloc);
        for (cmd.args) |*arg| if (can_glob(arg.value.string.value)) {
            const pattern = arg.value.string.value;
            if (glob_lib.validate(pattern)) |_| {

                const matches = match(alloc, pattern) catch |e| switch (e) {
                    error.NoMatches => {
                        try res.append(alloc, arg.*);
                        continue;
                    },
                    else => return e,
                };
                defer alloc.free(matches);

                @constCast(arg).free(alloc);
                for (matches) |m|
                    try res.append(alloc, .{ .value = .{ .string = .{ .value = m } } });
            } else |err|
                std.debug.print("{t}\n", .{err});
        } else {
            try res.append(alloc, arg.*);
        };
        alloc.free(cmd.args);
        cmd.args = try res.toOwnedSlice(alloc);
    }
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
