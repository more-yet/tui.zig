pub fn slicesOverlap(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len == 0 or rhs.len == 0) return false;

    const lhs_start = @intFromPtr(lhs.ptr);
    const rhs_start = @intFromPtr(rhs.ptr);
    if (lhs_start <= rhs_start) return rhs_start - lhs_start < lhs.len;
    return lhs_start - rhs_start < rhs.len;
}
