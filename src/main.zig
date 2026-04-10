const std = @import("std");
const exec = @import("exec.zig");
const globs = @import("globs.zig");
const hlp = @import("helpers.zig");
const keyboard = @import("keyboard.zig");

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
        const stuff = try keyboard.do(alloc, &term, &line, &buf, n, &pos);
        if (stuff.run) {
            defer {
                pos = 0;
            }
            defer line.clearAndFree(alloc);
            var quit:bool = false;
            try term.revert();
            defer term.mk_raw() catch |e| @panic(@errorName(e));
            defer _ = stdout.write("\r\n") catch {};
            _ = try stdout.write("\r\n");
            try stdout.flush();
            exit_code = b: {
                const info = exec.parse_and_run(line.items, &term) catch |e| {
                    std.debug.print("\n{t}\n", .{e});
                    break :b 1;
                };
                if (info.code == 0 and info.err != null) term.TODO(\\
                    \\  main shell loop recieved non-zero
                    \\    exit code, but no error provided
                    \\      TODO: fix this (recieved information below)
                    \\  error{{{?t}}} code{{{d}}} quit{{{}}}
                    , .{ info.err, info.code, info.quit }
                );
                quit = info.quit;
                break :b info.code;
            };
            if (quit) break :loop;
        }

        var old_len:usize = 0;
        defer old_len = line.items.len;
    }
}
