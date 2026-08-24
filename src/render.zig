pub const Color = @import("render/style.zig").Color;
pub const Rgb = @import("render/style.zig").Rgb;
pub const Style = @import("render/style.zig").Style;
pub const Attributes = @import("render/style.zig").Attributes;
pub const Cursor = @import("render/cursor.zig").Cursor;
pub const CursorShape = @import("render/cursor.zig").Shape;
pub const Renderer = @import("render/renderer.zig").Renderer;
pub const Frame = @import("render/renderer.zig").Frame;
pub const Surface = @import("render/renderer.zig").Surface;
pub const FrameStats = @import("render/renderer.zig").FrameStats;
pub const StyledSpan = @import("render/renderer.zig").StyledSpan;
pub const AsciiFill = @import("render/renderer.zig").AsciiFill;
pub const ImageOptions = @import("render/renderer.zig").ImageOptions;
pub const ImageError = @import("render/renderer.zig").ImageError;
pub const Limits = @import("render/renderer.zig").Limits;
pub const Cell = @import("render/cell.zig").Cell;
pub const CellView = @import("render/renderer.zig").CellView;
pub const CellWidth = @import("render/cell.zig").Width;
pub const Size = @import("core/geometry.zig").Size;
pub const Point = @import("core/geometry.zig").Point;
pub const Rect = @import("core/geometry.zig").Rect;
pub const BrailleCanvas = @import("render/braille.zig").BrailleCanvas;
pub const BraillePixelPoint = @import("render/braille.zig").PixelPoint;
pub const BrailleError = @import("render/braille.zig").Error;

test {
    _ = @import("core/geometry.zig");
    _ = @import("render/cell.zig");
    _ = @import("render/cursor.zig");
    _ = @import("render/damage.zig");
    _ = @import("render/glyph_store.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/style.zig");
    _ = @import("render/braille.zig");
}
