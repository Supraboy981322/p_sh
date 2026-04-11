const std = @import("std");

var stdout_buf:[1024]u8 = undefined;
pub const stdout_file = std.fs.File.stdout();
pub const stdout = &@constCast(&stdout_file.writer(&stdout_buf)).interface;

var stderr_buf:[1024]u8 = undefined;
pub const stderr_file = std.fs.File.stderr();
pub const stderr = &@constCast(&stderr_file.writer(&stderr_buf)).interface;

pub var separators = [_]u8{
    '/',  //forward slash
    '\'', //single quote
    '"',  //double quote
    '.',  //dot
} ++ thing_separators;

//I hate that I have to do this
pub var non_const_separators:[]u8 = @constCast(&thing_separators);

pub const thing_separators = [_]u8 {
} ++  std.ascii.whitespace
  ++ cmd_separators;

pub const cmd_separators = [_]u8{
    ';',  //semi-colon
    '|',  //pipe
};

pub const Hist = struct {
    arr:[][]u8,
    max:usize,
    len:usize,
    alloc:*std.mem.Allocator,

    pub fn init(alloc:*std.mem.Allocator, size:usize) !Hist {
        var foo = Hist{
            .alloc = alloc,
            .arr = undefined,
            .len = 0,
            .max = size,
        };
        foo.arr = try foo.alloc.alloc([]u8, foo.max);
        return foo;
    }

    pub fn deinit(self:*Hist) void {
        for (self.arr[0..self.len]) |line|
            self.alloc.free(line);
        self.alloc.free(self.arr);
    }

    pub fn append(self:*Hist, line:[]u8) !void {
        defer self.len += 1;
        if (self.len > self.max-1) {
            const new = try self.alloc.alloc([]u8, self.max);
            self.alloc.free(self.arr[0]);
            for (self.arr[1..], 0..) |l, i| {
                new[i] = try self.alloc.dupe(u8, l);
                self.alloc.free(l);
            }
            self.alloc.free(self.arr);
            self.arr = new;
            self.len -= 1;
        }
        self.arr[self.len] = try self.alloc.dupe(u8, line);
    }

    pub fn last(self:*Hist) ?[]u8 {
        if (self.len == 0) return null;
        return self.arr[self.len-1];
    }
};
