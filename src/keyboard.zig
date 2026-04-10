const std = @import("std");
const globs = @import("globs.zig");
const hlp = @import("helpers.zig");
const Term = @import("term.zig").Term;

const peek = @import("parser.zig").peek_no_state;

const stdout = globs.stdout;

pub fn do(alloc:std.mem.Allocator, term:*Term, line:*std.ArrayList(u8), buf:[]u8, n:usize, pos:*usize) !struct { run:bool } {
    var i:usize = 0;
    inner: while (i < n) : (i += 1) switch (buf[i]) {

        //'ctrl'+'c'
        '\x03' => {
            line.clearAndFree(alloc);
            for (0..2) |_| _ = try stdout.write("\r\n");
        },

        //'ctrl'+'w'
        '\x17' => {
            var num_popped:usize = 0;
            deep: while (line.pop()) |b| {
                defer num_popped += 1;
                for (globs.separators) |check| if (check == b and num_popped > 0) {
                    try line.append(alloc, b);
                    num_popped = 0;
                    break :deep;
                };
            }
        },

        // TODO: keyboard shortcuts
        '\x1b' => {
            //if (buf[i + 1] != '[') {
            //    pos += 1;
            //    if (pos >= line.items.len)
            //        try line.append(alloc, buf[i])
            //    else
            //        line.items[pos] = buf[i];
            //    continue :inner;
            //}
            i += 2;
            while (i < n) : (i += 1) {
                switch (buf[i]) {
                     // TODO: history
                    'A' => {}, // up arrow
                    'B' => {}, // down arrow

                    //left arrow
                    'D' => {
                        if (pos.* > 0) pos.* -= 1;
                    },
                    //right arrow
                    'C' => {
                        if (pos.* < line.items.len) pos.* += 1;
                    },

                    //home
                    'H' => { pos.* = 0; },
                    //end
                    'F' => { pos.* = line.items.len; },
                    
                    '3' => {
                        //'delete' key
                        if (peek(buf, &i) == '~') if (line.items.len > pos.*) {
                            _ = try hlp.pop_idx(term, alloc, u8, line, pos.*);
                        } else { } else if (hlp.peek_or_todo(term.*, buf[0..n], i, ';', "in keyboard shortcuts")) {
                            i += 1;
                            switch (peek(buf, &i)) {
                                //'ctrl'+'del'
                                '5' => {
                                    var b:?u8 = 0;
                                    deep: while (b != null) {
                                        b = try hlp.pop_idx(term, alloc, u8, line, pos.*);
                                        if (hlp.contains(&globs.separators, b orelse 0)) break :deep;
                                    }
                                },
                                else => term.TODO(
                                    "handle keyboard shortcut: |{c}| ({x}) {{{x}}}\n",
                                    .{buf[i], buf[i], buf[0..n]}
                                ),
                            }
                        }
                    },
                    else => {},
                }
            }
        },

        '\n' => {
            if (line.items.len < 1) {
                for (0..2) |_| _ = try stdout.write("\r\n");
                continue :inner;
            }
            return .{ .run = true };
        },

        '\x08', '\x7f' => {
            defer { if (pos.* > 0) pos.* -= 1; }
            if (pos.* >= line.items.len)
                _ = line.pop()
            else
                _ = try hlp.pop_idx(term, alloc, u8, line, pos.*);
        },
        
        else => {
            defer pos.* += 1;
            if (pos.* >= line.items.len)
                try line.append(alloc, buf[i])
            else {
                const before = try term.alloc.dupe(u8, line.items[0..pos.*]);
                const after = try term.alloc.dupe(u8, line.items[pos.*..]);
                line.clearAndFree(alloc);
                try line.appendSlice(alloc, before);
                try line.append(alloc, buf[i]);
                try line.appendSlice(alloc, after);
            }
        },
    };
    return .{ .run = false };
}
