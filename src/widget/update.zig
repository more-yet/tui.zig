pub const Update = enum(u2) {
    ignored,
    handled,
    redraw,
    relayout,

    pub inline fn merge(self: Update, other: Update) Update {
        return @enumFromInt(@max(@intFromEnum(self), @intFromEnum(other)));
    }

    pub inline fn isHandled(self: Update) bool {
        return self != .ignored;
    }

    pub inline fn needsRedraw(self: Update) bool {
        return @intFromEnum(self) >= @intFromEnum(Update.redraw);
    }

    pub inline fn needsLayout(self: Update) bool {
        return self == .relayout;
    }
};
