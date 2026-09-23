const glyph_store = @import("glyph_store.zig");
const style = @import("style.zig");

pub const Width = enum(u8) {
    continuation = 0,
    narrow = 1,
    wide = 2,
};

pub const Cell = struct {
    glyph: glyph_store.Glyph = ' ',
    style: style.Id = 0,
    width: Width = .narrow,
    _reserved: u8 = 0,

    pub fn eql(lhs: Cell, rhs: Cell) bool {
        return lhs.glyph == rhs.glyph and lhs.style == rhs.style and lhs.width == rhs.width;
    }
};
