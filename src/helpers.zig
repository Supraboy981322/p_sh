const Term = @import("term.zig").Term;

pub fn contains(list:[]u8, thing:u8) bool {
    return for (list) |itm| {
        if (thing == itm) break true;
    } else
        false;
}

pub fn peek_or_todo(term:Term, buf:[]u8, i:usize, comptime done:?u8, comptime context:[]const u8) bool {
    if (buf.len <= i+1) return false;
    if (buf[i+1] == done)
        return true
    else
        @constCast(&term).TODO(
            "handle " ++ (if (done) |_| "|{c}| ({x}) " else "") ++ "[{s}] {{{x}}} " ++ context,
            if (done) |_| .{ buf[i+1], buf[i+1], buf, buf } else .{ buf, buf }
        );
    return false;
}
