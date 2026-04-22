const std = @import("std");
const Term = @import("term.zig").Term;

const Categories = enum{ aliases, general, env };

pub fn read(term:*Term) !void {

    const home_dir = term.env.get("HOME") orelse return;
    const config_path = b: {
        var buf:[std.fs.max_path_bytes]u8 = undefined;
        var wr = std.Io.Writer.fixed(&buf);
        var formatter = std.fs.path.fmtJoin(&.{ home_dir, ".p_shrc"}); 
        try formatter.format(&wr);
        break :b buf[0..wr.end];
    };

    var config_file = try (try term.cwd()).openFile(config_path, .{});
    var buf:[1024]u8 = undefined;
    var reader = &@constCast(&config_file.reader(&buf)).interface;
    defer config_file.close();

    const alloc = term.permanent_alloc;

    var value = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer value.deinit(alloc);
    
    var key = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer key.deinit(alloc);

    var aliases = std.StringHashMap([]u8).init(alloc);

    var string:u8 = 0;
    var esc:bool = false;
    var key_or_value:enum{ KEY, VALUE } = .KEY;
    var category:?Categories = null;

    loop: while (reader.takeByte() catch null) |b| {
        if (std.ascii.isWhitespace(b) and string == 0 and !esc) {
            if (value.items.len > 0) if (category) |cat| {
                switch (cat) {
                    .aliases => try aliases.put(
                        try key.toOwnedSlice(alloc),
                        try value.toOwnedSlice(alloc)
                    ),

                    .general => term.config.set(
                        term, key.items, value.items
                    ),

                    .env => {
                        try term.env.put(
                            key.items, value.items
                        );
                    },
                }
                key.clearAndFree(alloc);
                value.clearAndFree(alloc);
                key_or_value = .KEY;
            } else
                term.print_error("unexpected bytes in config: {s}", .{value.items});
            continue :loop;
        }

        if (esc) {
            esc = false;
            switch (b) {
                'n', 'r', 'v', 'f' => {
                    try value.appendSlice(alloc, &.{ '\\', b });
                },
                else => try value.append(alloc, b),
            }
        } else if (string != 0) {
            switch (b) {
                '\\' => {
                    esc = true;
                    continue :loop;
                },
                '"', '\'' => {
                    if (string == b) {
                        string = 0;
                        continue :loop;
                    }
                    if (key_or_value == .VALUE)
                        try value.append(alloc, b)
                    else
                        try key.append(alloc, b);
                },
                else => {
                    if (key_or_value == .VALUE)
                        try value.append(alloc, b)
                    else
                        try key.append(alloc, b);
                },
            }
        } else if (!esc) switch (b) {
            '\\' => esc = true,
            '"' => {
                if (string == b or string == 0) {
                    string = if (string == 0) b else 0;
                    continue :loop;
                }
                if (key_or_value == .VALUE)
                    try value.append(alloc, b)
                else
                    try key.append(alloc, b);
            },
            '[' => {
                const key_name = try key.toOwnedSlice(alloc);
                category = std.meta.stringToEnum(Categories, key_name) orelse blk: {
                    term.print_error("invalid category: {s}\n", .{key_name});
                    while (reader.takeByte() catch null) |c| if (c == ']') break;
                    break :blk null;
                };
                alloc.free(key_name);
                value.clearAndFree(alloc);
                continue :loop;
            },
            ']' => {
                if (category == null)
                    std.debug.panic("unexpected closing bracket", .{});
                category = null;
                continue :loop;
            },
            '=' => {
                if (category) |_| key_or_value = .VALUE;
                continue :loop;
            },
            else => {
                if (key_or_value == .VALUE)
                    try value.append(alloc, b)
                else
                    try key.append(alloc, b);
            },
        };
    }
    term.vars.aliases = aliases;
}
