pub fn contains(list:[]u8, thing:u8) bool {
    return for (list) |itm| {
        if (thing == itm) break true;
    } else
        false;
}
