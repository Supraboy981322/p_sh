const std = @import("std");

pub fn tokenize(alloc:std.mem.Allocator) !void {
    const src = @embedFile("rc");
    var i:usize = 0;

    var mem = std.ArrayList(u8).initCapacity(alloc, 0);
    defer mem.deinit();

    var aliases = std.StringHashMap([]u8).init(alloc);

    var string:u8 = 0;

    while (i < src.len) : (i += 1) {
        if (std.ascii.isWhitespace(src[i])) {
        }
    }
}
