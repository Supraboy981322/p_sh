const std = @import("std");
const exec = @import("exec.zig");
const globs = @import("globs.zig");
const hlp = @import("helpers.zig");
const keyboard = @import("keyboard.zig");
const parser = @import("parser.zig");

const stdout = globs.stdout;
const stderr = globs.stderr;

const peek = @import("parser.zig").peek_no_state;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var perm_alloc = gpa.allocator();
    
    var stdin_file = std.fs.File.stdin();
    var stdout_file =std.fs.File.stdout();
    var stderr_file =std.fs.File.stdout();

    if (!stdin_file.isTty())
        @panic("TODO: non-tty"); // TODO: non-tty

    var hist = try globs.Hist.init(&perm_alloc, 100);
    defer hist.deinit();

    var term = try @import("term.zig").Term.init(
        perm_alloc,
        &stdin_file,
        &stderr_file,
        &stdout_file,
        null,
        &hist,
    ); 

    defer {
        term.revert() catch |e| @panic(@errorName(e));
        term.deinit();
    }

    const alloc = term.alloc;
    try term.mk_raw();

    var line = try std.ArrayList(u8).initCapacity(alloc, 0);
    var line_mem:[]u8 = try perm_alloc.alloc(u8, 0);
    defer {
        _ = line.deinit(alloc);
        perm_alloc.free(line_mem);
    }

    var pos:usize = 0;
    var exit_code:u8 = 0;
    var hist_pos:usize = hist.len;
    var quit:bool = false;
    loop: while (!quit) {
        defer {
            //a soft boundary is enough
            if (pos > line.items.len) pos = line.items.len;
        }

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer _ = arena.deinit();
        term.alloc = arena.allocator();

        const colorized = try parser.colorize(&term, line.items);
        const ps1_char:u8 = if (exit_code == 0 and colorized.cmd_ok) '?' else '!';
        const pretty_path = try term.pretty_path();
        try stdout.print(
            "\x1b[0m\r\x1b[2K\x1b[3;36m[\x1b[35m{s}\x1b[3;36m]"
                ++ "(\x1b[3{d}m{c}\x1b[36m):\x1b[0m\x1b[s {s}\x1b[u\x1b[{d}C",
            .{
                pretty_path,
                @as(u8, if (ps1_char == '?') 2 else 1),
                ps1_char,
                colorized.line,
                pos + 1,
            }
        );
        exit_code = 0;
        try stdout.flush();
        term.alloc.free(colorized.line);
        term.alloc.free(pretty_path);

        stdout.flush() catch {};
        stderr.flush() catch {};

        var buf:[1024]u8 = undefined;
        const n = try std.posix.read(stdin_file.handle, &buf);

        //for (buf[0..n]) |k| std.debug.print("{d} ({x}) |{c}|\n", .{k, k, k});
        var stuff = try keyboard.do(alloc, &term, &line, &buf, n, &pos);

        if (stuff.hist_change != 0) {
            defer pos = line.items.len;
            var did_change:bool = false;
            if (stuff.hist_change > 0 and hist_pos < hist.len) {
                while (stuff.hist_change > 0) : (stuff.hist_change -= 1) {
                    if (hist_pos < hist.len)
                        hist_pos += 1
                    else
                        break;
                }
                did_change = true;
            }
            if (stuff.hist_change < 0 and hist_pos > 0) {
                while (stuff.hist_change < 0) : (stuff.hist_change += 1) {
                    if (hist_pos > 0)
                        hist_pos -= 1
                    else
                        break;
                }
                did_change = true;
            }
            if (hist_pos == hist.len and did_change) {
                const old_line = try alloc.dupe(u8, line_mem);
                defer alloc.free(old_line);

                perm_alloc.free(line_mem);

                line_mem = try perm_alloc.alloc(u8, 0);

                line.clearAndFree(alloc);

                try line.appendSlice(alloc, old_line);
            } else if (did_change) {
                if (line_mem.len == 0) {
                    perm_alloc.free(line_mem);
                    line_mem = try perm_alloc.dupe(u8, line.items);
                }
                line.clearAndFree(alloc);
                try line.appendSlice(alloc, hist.arr[hist_pos]);
            }
        }

        if (stuff.run) {
            perm_alloc.free(line_mem);
            line_mem = try perm_alloc.dupe(u8, line.items);
            try term.revert();
            try hist.append(line.items);
            hist_pos = hist.len;
            defer {
                pos = 0;
                line.clearAndFree(alloc);
                term.mk_raw() catch |e| @panic(@errorName(e));
                _ = stdout.write("\r\n") catch {};
            }
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
