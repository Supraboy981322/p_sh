const std = @import("std");

var stdout_buf:[1024]u8 = undefined;
pub const stdout_file = std.fs.File.stdout();
pub const stdout = &@constCast(&stdout_file.writer(&stdout_buf)).interface;

var stderr_buf:[1024]u8 = undefined;
pub const stderr_file = std.fs.File.stderr();
pub const stderr = &@constCast(&stderr_file.writer(&stderr_buf)).interface;
