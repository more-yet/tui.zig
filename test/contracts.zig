test "load contract suites" {
    _ = @import("model/render.zig");
    _ = @import("model/editor.zig");
    _ = @import("model/input.zig");
    _ = @import("model/widgets.zig");
    _ = @import("model/graphics.zig");
    _ = @import("model/graphics_demo.zig");
    _ = @import("conformance/grapheme.zig");
}
