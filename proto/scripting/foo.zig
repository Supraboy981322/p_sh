const std = @import("std");

const Token = struct {
    raw:[]u8 = undefined,
    type:TokenType,
    keyword:Keywords = undefined,

    pub const TokenType = enum {
        CMD,
        KEYWORD,
        BUILTIN,
    };

    pub const Keywords = enum {
        @"if",
        @"then",
        @"else",
        @"elif",
        @"fi",
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const src = @embedFile("test.sh");

    var mem = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = mem.deinit(alloc);
    var tokens = try std.ArrayList(Token).initCapacity(alloc, 0);
    defer {
        for (tokens.items) |token|
            alloc.free(token.raw);
        _ = tokens.deinit(alloc);
    }
    var i:usize = 0;
    var string:u8 = 0;
    var esc:bool = false;
    loop: while (i < src.len) : (i += 1) {
        const b = src[i];
        if (esc) {
            esc = false;
            try mem.append(alloc, b);
            continue :loop;
        }
        if (string != 0) {
            if (string == b)
                string = 0
            else
                try mem.append(alloc, b);
            continue :loop;
        }
        if (b == '\n' or b == ';') {
            const keyword = std.meta.stringToEnum(Token.Keywords, mem.items);
            try tokens.append(alloc, .{
                .raw = try alloc.dupe(u8, mem.items),
                .type = if (keyword) |_| .KEYWORD else .CMD,
                .keyword = keyword orelse undefined,
            });
        }

        switch (b) {
            '\\' => esc = true,
            '"', '\'' => string = b,
            '#' => while (i < src.len) : (i += 1) if (src[i] == '\n') break,
            else => try mem.append(alloc, b),
        }
    }
    for (tokens.items) |token|
        std.debug.print(
            \\raw|{s}|
            \\  type{{{s}}}
            \\  keyword{{{s}}}
            ++ "\n", .{
                token.raw,
                @tagName(token.type),
                if (token.type == .KEYWORD) @tagName(token.keyword) else "[undefined]",
            });
}
