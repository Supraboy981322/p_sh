const std = @import("std");
const hlp = @import("helpers.zig");
const exec = @import("exec.zig");
const globs = @import("globs.zig");

const Cmd = exec.Cmd;
const Term = @import("term.zig").Term;
const ExecOpts = exec.ExecOpts;
const PipeDetails = exec.PipeDetails;

pub const ArgSplitResult = struct {
    //elderly C-style (may add a more convenient one here too)
    archaic:[*:null]const ?[*:0]const u8,

    //information about each arg, in order
    info:[]exec.Cmd.ArgInfo,
};

pub fn split_args(in:[]u8, term:*Term) ![*:null]const ?[*:0]const u8 {
    const alloc = term.alloc;
    var res = try std.ArrayList(?[*:0]const u8).initCapacity(alloc, 0);
    var mem = try std.ArrayList(u8).initCapacity(alloc, 0);
    var mem2 = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer {
        _ = mem.deinit(alloc);
        _ = mem2.deinit(alloc);
        _ = res.deinit(alloc);
    }

    var i:usize,
        var str_type:u8,
        var esc,
        var start_of_thing = .{
            0,
            0,
            false,
            false
        };

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

        if (start_of_thing) {
            defer start_of_thing = false;
            switch (b) {
                '~' => {
                    try mem.appendSlice(
                        alloc,
                        term.env.get("HOME") orelse "~"
                    );
                    continue :loop;
                },
                else => {},
            }
        } else if (
            hlp.contains(globs.non_const_separators, b) and str_type == 0
        ) {
            start_of_thing = true;
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
                try mem.append(alloc, 0);
                const slice = try mem.toOwnedSlice(alloc);
                try res.append(alloc, slice[0 .. slice.len - 1 :0].ptr);
                mem.clearAndFree(alloc);
            } else {} else
                try mem.append(alloc, b),

            else => { try mem.append(alloc, b); },
        }
    }
    if (mem.items.len > 0) {
        try mem.append(alloc, 0);
        const slice = try mem.toOwnedSlice(alloc);
        try res.append(alloc, slice[0 .. slice.len - 1 :0].ptr);
    }
    try res.append(alloc, null);
    return @ptrCast((try res.toOwnedSlice(alloc)).ptr);
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
    for (0..n) |j|
        buf[j] = peek_no_state(in, @constCast(&(i + j)));
    return buf;
}

pub fn seek_thing_no_state(in:[]u8, pos:*usize, from:?u8) []u8 {
    var i = pos.*;
    defer pos.* = i;
    var start:?usize = null;
    loop: while (i < in.len) : (i += 1) {
        if ((std.ascii.isWhitespace(in[i]) or in[i] != from.?) and start == null) {
            i += 1;
            start = i;
        } else
            if (std.ascii.isWhitespace(in[i]) and in[i] != from.?)
                if (start != null)
                    break :loop;
    }
    return in[start orelse 0..i];
}

pub fn split_command(term:*Term, res:*std.ArrayList(Cmd), line:[]u8) !void {

    const alloc = term.alloc;
    var mem = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = mem.deinit(alloc);

    var string:u8 = 0;
    var i:usize = 0;
    var was_piped:bool = false;
    var file:?PipeDetails.File = null;
    loop: while (i < line.len) : (i += 1) {
        const b = line[i];
        if (string == 0 and std.mem.containsAtLeast(u8, &globs.cmd_separators, 1, &[_]u8{b})) {
            defer {
                file = null;
                was_piped = b == '|';
            }
            try res.append(alloc, .{
                .raw = try mem.toOwnedSlice(alloc),
                .args_info = undefined,
                .fd_set = .{
                    term.stdin_file.handle,
                    term.stdout_file.handle,
                },
                .opts = .{
                    .wait = true,
                    .piped = b == '|' or was_piped,
                    // TODO: probably a better way to do this
                    .pipe_details = switch (b) {
                        ';' => .{},
                        '|' => .{ .out = true, },
                        else => std.debug.panic("TODO: cmd separator |{c}|", .{b}), 
                    }
                },
            });
            res.items[res.items.len - 1].opts.pipe_details.file = file orelse .{};
            continue :loop;
        }

        if ((b == '>' or b == '<') and string == 0) {
            const old_pos = i;
            file = .{
                .do = true,
                .append = peek_no_state(line, &i) == b and b == '>',
                .tmp_file =
                    if (std.mem.eql(u8, &peekN_no_state(line, i, 2), "<<")) blk: {
                        i += 2;
                        const content = seek_thing_no_state(line, &i, b);
                        if (i-2 == old_pos)
                            return error.IncompletePipe;
                        break :blk content;
                    } else
                        null,
                .in_or_out = if (b == '<') .IN else .OUT,
            };
            if (file.?.tmp_file == null)
                file.?.name = seek_thing_no_state(line, &i, b);

            continue :loop;
        }

        if ((b == '"' or b == '\'') and string == 0)
            string = b
        else if (string == b)
            string = 0;

        try mem.append(alloc, b);
    }
    if (mem.items.len > 0) {
        try res.append(alloc, .{
            .raw = try mem.toOwnedSlice(alloc),
            .args_info = undefined,
            .fd_set = .{
                term.stdin_file.handle,
                term.stdout_file.handle
            },
            .opts = .{
                .wait = true,
                .piped = was_piped,
            },
        });
        res.items[res.items.len - 1].opts.pipe_details.file = file orelse .{};
    }
}

pub fn colorize(term:*Term, in:[]u8) !struct { line:[]u8, cmd_ok:bool } {
    const alloc = term.alloc;
    var res = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer _ = res.deinit(alloc);

    const peek = peek_no_state;
    const peekN = peekN_no_state;

    var i:isize = 0;
    var colorize_next:usize = 0;
    var string:u8 = 0;
    var name_end:usize = 0; 

    while (i < in.len) : (i += 1) {
        const b = in[@intCast(i)];
        if (hlp.contains(&globs.separators, b) and name_end == 0)
            name_end = @intCast(i);

        var j:usize = @intCast(i);
        var next:usize = @intCast(i+1);

        switch (b) {

            '#' => if (string == 0) {
                if (term.config.colorizing_level >= 2)
                    try res.appendSlice(alloc, "\x1b[0;3;38;2;115;115;150m");
                for (in[j..]) |c| try res.append(alloc, c);
                break;
            },

            '$' => {
                const name = try seek_var_name(alloc, in, &j);
                defer alloc.free(name);
                colorize_next = name.len + 1;
            },

            '"', '\'' => string =
                if (string == 0)
                    b
                else if (string != b)
                    string
                else {
                    if (term.config.colorizing_level >= 2)
                        try res.appendSlice(alloc, "\x1b[33m"); 
                    try res.append(alloc, b);
                    string = 0;
                    continue;
                },

            // TODO: change this (currently breaks cursor position)
            '\t' => {
                try res.append(alloc, ' ');
                continue;
            },

            '\\' => {
                if (term.config.colorizing_level >= 2) {
                    try res.appendSlice(alloc, "\x1b[34m");
                    colorize_next = if (in.len > i+1) switch (in[@intCast(i+1)]) {

                        '0'...'3' => for ([_]bool{
                            peek(in, &j) >= '0',
                            peek(in, &j) <= '7',
                            peek(in, &next) >= '0',
                            peek(in, &next) <= '7',
                            peek(in, @constCast(&@as(usize, next+1))) >= '0',
                            peek(in, @constCast(&@as(usize, next+1))) <= '7',
                        }) |check| {
                            if (!check) break 1;
                        } else 4,

                        'x' => for (peekN(in, j+1, 3)) |c| {
                            break for ([_]bool{
                                c >= '0' and c <= '9',
                                c >= 'a' and c <= 'f',
                                c >= 'A' and c <= 'F',
                            }) |check| {
                                if (check) break @as(u8, 4);
                            } else @as(u8, 1);
                        } else @as(u8, 1),

                        '#' => {
                            try res.appendSlice(alloc, "\\#");
                            i += 1;
                            continue;
                        },

                        else => 1,
                    } else 1;
                }
            },
            else => {},
        }

        if (term.config.colorizing_level >= 2) {
            try res.appendSlice(
                alloc,
                if (hlp.contains(&globs.symbols, b))
                    "\x1b[36m"
                else
                    "\x1b[00m"
            );

            if (string != 0)
                try res.appendSlice(alloc, "\x1b[33m")
            else if (std.ascii.isDigit(b))
                try res.appendSlice(alloc, "\x1b[34m")
            else if (colorize_next > 0) {
                try res.appendSlice(alloc, "\x1b[34m");
                colorize_next -= 1;
            }
        } else if (term.config.colorizing_level >= 1) {
            try res.appendSlice(alloc, "\x1b[00m");
        }

        try res.append(alloc, b);
        if (term.config.colorizing_level >= 1) {
            try res.appendSlice(alloc, "\x1b[0m");
        }
    }

    const name = in[0 .. if (name_end > 0) name_end else in.len ];
    
    const valid =
        if (name.len > 0)
            try term.is_in_path(name) or term.is_alias(name)
        else
            true;
    if (!valid and term.config.colorizing_level >= 1) loop: for (res.items, 0..) |*c, k| {
        if (c.* == '\x1b') {
            res.items[k+2] = '3';
            res.items[k+3] = '1';
        } else
            if (hlp.contains(&globs.separators, c.*))
                break :loop;
    };

    return .{
        .line = try res.toOwnedSlice(alloc),
        .cmd_ok = valid,
    };
}

pub fn resolve_string(alloc:std.mem.Allocator, in:[]u8, term:*Term) ![]u8 {
    var res = try std.ArrayList(u8).initCapacity(term.alloc, 0);
    defer res.deinit(term.alloc);

    var i:usize = 0;
    var esc:bool = false;
    while (i < in.len) : (i += 1) {
        const b = in[i];
        if (esc) {
            try res.append(term.alloc, b);
            esc = false;
            continue;
        }
        switch (b) {
            '\\' => esc = true,
            '$' => {
                const name = try seek_var_name(term.alloc, in, &i);
                defer term.alloc.free(name);
                try res.appendSlice(term.alloc, term.env.get(name) orelse " ");
            },
            else => try res.appendSlice(term.alloc, b),
        }
    }
    return try res.toOwnedSlice(alloc);
}
