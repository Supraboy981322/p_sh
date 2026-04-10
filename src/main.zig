const std = @import("std");
const exec = @import("exec.zig");
const globs = @import("globs.zig");
const hlp = @import("helpers.zig");

const stdout = globs.stdout;
const stderr = globs.stderr;

const peek = @import("parser.zig").peek_no_state;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    var stdin_file = std.fs.File.stdin();
    var stdout_file =std.fs.File.stdout();
    var stderr_file =std.fs.File.stdout();

    if (!stdin_file.isTty())
        @panic("TODO: non-tty"); // TODO: non-tty
    
    var term = try @import("term.zig").Term.init(
        gpa.allocator(),
        &stdin_file,
        &stderr_file,
        &stdout_file,
        null
    ); 

    defer {
        term.revert() catch |e| @panic(@errorName(e));
        term.deinit();
    }

    const alloc = term.alloc;
    try term.mk_raw();

    var line = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = line.deinit(alloc);

    var pos:usize = 0;
    var exit_code:u8 = 0;
    loop: while (true) {
        defer {
            //a soft boundary is enough
            if (pos > line.items.len) pos = line.items.len;
        }

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer _ = arena.deinit();
        term.alloc = arena.allocator();

        const ps1_char:u8 = if (exit_code == 0) '?' else '!';
        const colorized_line =  try term.colorize(line.items);
        try stdout.print(
            "\x1b[0m\r\x1b[2K\x1b[3;36m[\x1b[35m{s}\x1b[3;36m](\x1b[3{d}m{c}\x1b[36m):\x1b[0m\x1b[s {s}\x1b[u\x1b[{d}C",
            .{
                try term.cwd().realpathAlloc(term.alloc, "."),
                @as(u8, if (ps1_char == '?') 2 else 1),
                ps1_char,
                colorized_line,
                pos + 1,
            }
        );
        try stdout.flush();
        term.alloc.free(colorized_line);

        stdout.flush() catch {};
        stderr.flush() catch {};

        var buf:[1024]u8 = undefined;
        const n = try std.posix.read(stdin_file.handle, &buf);

        //for (buf[0..n]) |k| std.debug.print("{d} ({x}) |{c}|\n", .{k, k, k});

        var old_len:usize = 0;
        defer old_len = line.items.len;
        var i:usize = 0;
        inner: while (i < n) : (i += 1) switch (buf[i]) {

            //'ctrl'+'c'
            '\x03' => {
                line.clearAndFree(alloc);
                for (0..2) |_| _ = try stdout.write("\r\n");
                continue :loop;
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
                            if (pos > 0) pos -= 1;
                        },
                        //right arrow
                        'C' => {
                            if (pos < line.items.len) pos += 1;
                        },

                        //home
                        'H' => { pos = 0; },
                        //end
                        'F' => { pos = line.items.len; },
                        
                        '3' => {
                            //'delete' key
                            if (peek(&buf, &i) == '~') if (line.items.len > pos+1) {
                                const before = try term.alloc.dupe(u8, line.items[0..pos+1]);
                                const after = try term.alloc.dupe(u8, line.items[pos+1..]);
                                line.clearAndFree(alloc);
                                try line.appendSlice(alloc, before);
                                _ = line.pop();
                                try line.appendSlice(alloc, after);
                            } else { _ = line.pop(); } else if (hlp.peek_or_todo(term, &buf, i, ';', "in keyboard shortcuts")) {
                                i += 1;
                                switch (peek(&buf, &i)) {
                                    //'ctrl'+'del'
                                    '5' => {
                                        var b:u8 = 0;
                                        while (!hlp.contains(&globs.separators, b) and b != 1 and line.items.len > pos) {
                                            const before = try term.alloc.dupe(u8, line.items[0..pos+1]);
                                            const after = try term.alloc.dupe(u8, line.items[pos+1..]);
                                            line.clearAndFree(alloc);
                                            try line.appendSlice(alloc, before);
                                            b = if (line.pop()) |popped| popped else 1;
                                            try line.appendSlice(alloc, after);
                                        }
                                    },
                                    else => term.TODO(
                                        "handle keyboard shortcut: |{c}| ({x}) [{s}] {{{x}}}\n",
                                        .{buf[i], buf[i], buf[0..n], buf[0..n]}
                                    ),
                                }
                            }
                        },

                        //ignore everything else
                        else => {
                            continue :loop;
                        },
                    }
                }
                continue :loop;
            },

            '\n' => {
                defer {
                    pos = 0;
                }
                if (line.items.len < 1) {
                    for (0..2) |_| _ = try stdout.write("\r\n");
                    continue :inner;
                }
                defer line.clearAndFree(alloc);
                var quit:bool = false;
                try term.revert();
                defer term.mk_raw() catch |e| @panic(@errorName(e));
                defer _ = stdout.write("\r\n") catch {};
                _ = try stdout.write("\r\n");
                try stdout.flush();
                exit_code = b: {
                    const info = exec.parse_and_run(line.items, &term) catch |e| break :b switch (e) {
                        error.FileNotFound => 127,
                        else => {
                            std.debug.print("{t}\n", .{e});
                            break :b 126;
                        }
                    };
                    quit = info.quit;
                    break :b info.code;
                };
                if (quit) break :loop;
            },

            '\x08', '\x7f' => {
                defer { if (pos > 0) pos -= 1; }
                if (pos >= line.items.len)
                    _ = line.pop()
                else {
                    const before = try term.alloc.dupe(u8, line.items[0..pos]);
                    const after = try term.alloc.dupe(u8, line.items[pos..]);
                    line.clearAndFree(alloc);
                    try line.appendSlice(alloc, before);
                    _ = line.pop();
                    try line.appendSlice(alloc, after);
                }
            },
            
            else => {
                defer pos += 1;
                if (pos >= line.items.len)
                    try line.append(alloc, buf[i])
                else {
                    const before = try term.alloc.dupe(u8, line.items[0..pos]);
                    const after = try term.alloc.dupe(u8, line.items[pos..]);
                    line.clearAndFree(alloc);
                    try line.appendSlice(alloc, before);
                    try line.append(alloc, buf[i]);
                    try line.appendSlice(alloc, after);
                }
            },
        };
    }
}
