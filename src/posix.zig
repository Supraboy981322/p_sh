

// NOTE:
//  it is deeply moronic to remove these; why remove it?
//    why not leave these basic helpers for lower-level system specific
//      calls with the slightest abstraction (for error handling)?
//        (yes, a lot of these are lifted straight from Zig 0.15.2 std.posix)


const std = @import("std");
const builtin = @import("builtin");
const Term = @import("term.zig").Term;

//this is literally copy-pasted from 0.15.2 std.posix.abort()
//  why not just do this? (create a const that points to it)
pub const abort = std.process.abort;
pub const exit = std.process.exit;

pub const native_os = builtin.os.tag;
comptime {
    switch (native_os) {
        .linux => {},
        .windows => @compileError("windows"), //don't plan on using Windows anytime soon
        .macos, .ios, .watchos, .tvos, .visionos => @compileError("what the hell are you doing compiling for these?"),
        else => @compileError("good luck getting this to compile"),
    }
}

pub fn waitpid_exit_code(pid:std.posix.pid_t) u8 {
    var status:u32 = undefined;
    const code:usize = std.posix.system.waitpid(pid, &status, 0);
    const errno:u32 = inner: while (true) {
        switch (std.posix.errno(code)) {
            .SUCCESS => {
                _ = @as(std.posix.pid_t, @intCast(code)); // NOTE: pid
                break :inner @as(u32, @bitCast(status));
            },
            .INTR => continue :inner,
            .CHILD => break :inner 126, // The process specified does not exist. It would be a race condition to handle this error.
            .INVAL => unreachable, // Invalid flags.
            else => unreachable,
        }
    } else
        unreachable;
    return 
        if (std.posix.W.IFEXITED(errno))
            std.posix.W.EXITSTATUS(errno)
        else if (std.posix.W.IFSIGNALED(errno))
            @intCast(128 + @as(u32, @intFromEnum(std.posix.W.TERMSIG(errno))))
        else
            0;
}

pub fn new_pipe() ![2]std.posix.fd_t {
    var set:[2]std.posix.fd_t = undefined;
    const code = std.posix.system.pipe(&set);
    const errno = std.posix.errno(code);
    switch (errno) {
        .SUCCESS => return set,
        .INVAL => unreachable, // Invalid parameters to pipe()
        .FAULT => unreachable, // Invalid fds pointer
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn fork() !std.posix.pid_t {
    const code = std.posix.system.fork();
    return switch (std.posix.errno(code)) {
        .SUCCESS => @intCast(code),
        .AGAIN, .NOMEM => error.SystemResources,
        else => |e| std.posix.unexpectedErrno(e),
    };
}

pub fn close(fd:std.posix.fd_t) void {
    const code = std.posix.system.close(fd);
    switch (std.posix.errno(code)) {
        .BADF => unreachable, //race condition
        else => return,
    }
}

pub const ExecvpeError = error {
    SystemResources,
    ProcessFdQuotaExceeded,
    NameTooLong,
    SystemFdQuotaExceeded,
    AccessDenied,
    PermissionDenied,
    InvalidExe,
    FileSystem,
    IsDir,
    FileNotFound,
    NotDir,
    FileBusy,
    Unexpected,
    Canceled,
    BadPathName,
    OperationUnsupported,
    OutOfMemory,
};

pub fn execvpeZ(
    term:*Term,
    file: [*:0]const u8,
    child_argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecvpeError {
    const file_slice = std.mem.sliceTo(file, 0);
    if (std.mem.indexOfScalar(u8, file_slice, '/') != null)
        return execve(file, child_argv, envp);

    const PATH = term.env.get("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, PATH, ':');
    var seen_eacces = false;
    var err:std.process.ReplaceError = error.FileNotFound;

    while (it.next()) |search_path| {
        const path_len = search_path.len + file_slice.len + 1;
        if (path_buf.len < path_len + 1)
            return error.NameTooLong;
        @memcpy(path_buf[0..search_path.len], search_path);
        path_buf[search_path.len] = '/';
        @memcpy(path_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0].ptr;
        err = execve(full_path, child_argv, envp);
        switch (err) {
            error.AccessDenied => seen_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        }
    }
    if (seen_eacces)
        return error.AccessDenied;
    return err;
}

pub fn execve(
    path: [*:0]const u8,
    child_argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecvpeError {
    const code = std.posix.system.execve(path, child_argv, envp);
    switch (std.posix.errno(code)) {
        .SUCCESS => unreachable,
        .FAULT => unreachable,
        .@"2BIG" => return error.SystemResources,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .INVAL => return error.InvalidExe,
        .NOEXEC => return error.InvalidExe,
        .IO => return error.FileSystem,
        .LOOP => return error.FileSystem,
        .ISDIR => return error.IsDir,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .TXTBSY => return error.FileBusy,
        else => |err| switch (native_os) {
            .linux => switch (err) {
                .LIBBAD => return error.InvalidExe,
                else => return std.posix.unexpectedErrno(err),
            },
            else => return std.posix.unexpectedErrno(err),
        },
    }
}

pub fn write(fd: std.posix.fd_t, bytes: []const u8) !usize {
    if (bytes.len == 0) return 0;

    if (native_os == .wasi and !builtin.link_libc) {
        const ciovs = [_]std.posix.iovec_const{std.posix.iovec_const{
            .base = bytes.ptr,
            .len = bytes.len,
        }};
        var nwritten: usize = undefined;
        switch (std.os.wasi.fd_write(fd, &ciovs, ciovs.len, &nwritten)) {
            .SUCCESS => return nwritten,
            .INTR => unreachable,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => unreachable,
            .BADF => return error.NotOpenForWriting, // can be a race condition.
            .DESTADDRREQ => unreachable, // `connect` was never called.
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .NOTCAPABLE => return error.AccessDenied,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    while (true) {
        const rc = std.posix.system.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .FAULT => unreachable,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting, // can be a race condition.
            .DESTADDRREQ => unreachable, // `connect` was never called.
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            .NXIO => return error.NoDevice,
            .MSGSIZE => return error.MessageTooBig,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}
