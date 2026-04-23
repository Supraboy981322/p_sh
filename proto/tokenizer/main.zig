const std = @import("std");
const args = @import("args.zig");
const types = @import("types.zig");
const glob = @import("glob");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const code =
        \\echo foo    "foo bar" z* flake*;echo "bar"
    ;

    var split = try args.split(alloc, @constCast(code));
    defer {
        for (split) |*cmd|
            @constCast(cmd).free(alloc);
        alloc.free(split);
    }

    std.debug.print("\n==== split ====\n", .{});
    for (split) |cmd| {
        std.debug.print("|{s}|\n", .{cmd.name});
        for (cmd.args) |arg| {
            if (arg.value == .string)
                std.debug.print("\t|{s}|\n", .{arg.value.string.value})
            else
                std.debug.print("\tnot string: {any}\n", .{arg.value});
        }
    }


    try args.glob(alloc, &split);
    std.debug.print("\n==== globbing ====\n", .{});
    for (split) |cmd| {
        std.debug.print("|{s}|\n", .{cmd.name});
        for (cmd.args) |arg| {
            if (arg.value == .string)
                std.debug.print("\t|{s}|\n", .{arg.value.string.value})
            else
                std.debug.print("\tnot string: {any}\n", .{arg.value});
        }
    }
}
