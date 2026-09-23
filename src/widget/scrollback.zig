//! Read-only viewport over caller-owned line data.

const input = @import("../input.zig");
const render = @import("../render.zig");
const scroll = @import("../scroll.zig");
const text = @import("../text.zig");
const theme = @import("../theme.zig");
const Update = @import("update.zig").Update;

pub fn Scrollback(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        viewport: *scroll.Viewport,
        bounds: render.Rect,
        role: theme.Role = .{},
        enabled: bool = true,
        focused: bool = false,
        width_profile: text.WidthProfile = .narrow,

        const Self = @This();

        pub fn handle(self: *Self, event: input.Event) Update {
            const count = self.provider.count();
            _ = self.viewport.update(count, self.bounds.height, 0);
            if (!self.enabled) return .ignored;

            const changed = switch (event) {
                .key => |key| key: {
                    if (key.action == .release or key.modifiers.hasNonLock()) return .ignored;
                    break :key switch (key.code) {
                        .up => self.viewport.scrollUp(1, count, self.bounds.height),
                        .down => self.viewport.scrollDown(1, count, self.bounds.height),
                        .page_up => self.viewport.pageUp(count, self.bounds.height),
                        .page_down => self.viewport.pageDown(count, self.bounds.height),
                        .home => self.viewport.home(count, self.bounds.height),
                        .end => self.viewport.end(count, self.bounds.height),
                        else => return .ignored,
                    };
                },
                .mouse => |mouse| mouse: {
                    if (mouse.modifiers.hasNonLock() or
                        !self.bounds.contains(.{ .x = mouse.x, .y = mouse.y })) return .ignored;
                    break :mouse switch (mouse.action) {
                        .scroll_up => self.viewport.scrollUp(1, count, self.bounds.height),
                        .scroll_down => self.viewport.scrollDown(1, count, self.bounds.height),
                        else => return .ignored,
                    };
                },
                else => return .ignored,
            };
            return if (changed) .redraw else .handled;
        }

        pub fn draw(self: *Self, surface: *render.Surface) !void {
            const size = surface.size();
            const count = self.provider.count();
            _ = self.viewport.update(count, size.height, 0);
            const visible = self.viewport.visibleRange(count, size.height);
            const style = self.role.resolve(theme.State.from(self.enabled, self.focused));
            var y: u16 = 0;
            while (y < size.height) : (y += 1) {
                const index = if (@as(usize, y) < visible.len()) visible.start + y else null;
                _ = try surface.putTextLine(
                    .{ .x = 0, .y = y },
                    if (index) |row| self.provider.row(row) else "",
                    size.width,
                    style,
                    self.width_profile,
                    .{},
                );
            }
        }
    };
}
