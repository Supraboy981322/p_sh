const std = @import("std");

pub const Actions = enum {
    reload,
    chdir,
    config,
    alias,
    code, //exit code
    EXIT,
};

// NOTE: format (examples)
//  reload:config
//  chdir:some/dir/name

pub const Action = struct {
    action:Actions,
    stuff:[]u8
};

pub fn parse(line:[]u8) !Action {
    var action:Actions = undefined;
    var i:usize = 0;
    var start:usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            ':' => if (start == 0) {
                action = std.meta.stringToEnum(
                    Actions, line[0..i]
                ) orelse
                    std.debug.panic("UNKNOWN ACTION: {s}", .{line[0..start]});
                start = i+1;
                break;
            },
            else => {},
        }
    }
    return .{
        .action = action,
        .stuff = line[start..],
    };
}
