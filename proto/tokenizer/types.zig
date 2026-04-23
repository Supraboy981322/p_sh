const std = @import("std");

pub const Cmd = struct {
    name:[]u8,
    args:[]Token,

    pub fn free(self:*Cmd, alloc:std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.args) |*arg|
            @constCast(arg).free(alloc);
        alloc.free(self.args);
    }
};

pub const String = struct {
    value:[]u8,
};

pub const Token = struct {
    value:union(enum) {
        void:void,
        string:String,
        num:isize,
    },
    pub fn free(self:*Token, alloc:std.mem.Allocator) void {
        if (self.value == .string)
            alloc.free(self.value.string.value)
        else
            std.debug.print("not string", .{});
    }
};

