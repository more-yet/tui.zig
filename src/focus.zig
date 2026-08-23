const std = @import("std");
const input = @import("input.zig");
const render = @import("render.zig");
const widget = @import("widget.zig");

pub const Id = u32;
const no_parent = std.math.maxInt(u16);

pub const Target = struct {
    id: Id,
    parent: ?Id = null,
    rect: render.Rect,
    focusable: bool = true,
    enabled: bool = true,
};

pub const Node = struct {
    id: Id,
    rect: render.Rect,
    parent_index: u16,
    focusable: bool,
    enabled: bool,
};

pub const Registry = struct {
    storage: []Node,
    len: u16 = 0,

    pub fn init(storage: []Node) error{CapacityTooLarge}!Registry {
        if (storage.len > no_parent) return error.CapacityTooLarge;
        return .{ .storage = storage };
    }

    pub inline fn reset(self: *Registry) void {
        self.len = 0;
    }

    pub fn add(self: *Registry, target: Target) error{
        CapacityExceeded,
        DuplicateId,
        MissingParent,
    }!void {
        if (self.len == self.storage.len) return error.CapacityExceeded;
        var parent_index: u16 = no_parent;
        for (self.storage[0..self.len], 0..) |node, index| {
            if (node.id == target.id) return error.DuplicateId;
            if (target.parent != null and node.id == target.parent.?) parent_index = @intCast(index);
        }
        if (target.parent != null and parent_index == no_parent) return error.MissingParent;
        self.storage[self.len] = .{
            .id = target.id,
            .rect = target.rect,
            .parent_index = parent_index,
            .focusable = target.focusable,
            .enabled = target.enabled,
        };
        self.len += 1;
    }

    pub inline fn count(self: *const Registry) usize {
        return self.len;
    }

    pub fn path(
        self: *const Registry,
        id: Id,
        output: []Id,
    ) error{ UnknownId, OutputTooSmall }![]Id {
        return self.pathIndex(self.indexOf(id) orelse return error.UnknownId, output);
    }

    fn pathIndex(self: *const Registry, target_index: u16, output: []Id) error{OutputTooSmall}![]Id {
        var index = target_index;
        var depth: usize = 1;
        while (self.storage[index].parent_index != no_parent) : (depth += 1) {
            index = self.storage[index].parent_index;
        }
        if (output.len < depth) return error.OutputTooSmall;

        index = target_index;
        var position = depth;
        while (true) {
            position -= 1;
            const node = self.storage[index];
            output[position] = node.id;
            if (node.parent_index == no_parent) break;
            index = node.parent_index;
        }
        return output[0..depth];
    }

    pub fn hit(self: *const Registry, point: render.Point) ?Id {
        var index: usize = self.len;
        while (index != 0) {
            index -= 1;
            const node = self.storage[index];
            if (eligible(node) and node.rect.contains(point)) return node.id;
        }
        return null;
    }

    fn indexOf(self: *const Registry, id: Id) ?u16 {
        for (self.storage[0..self.len], 0..) |node, index| {
            if (node.id == id) return @intCast(index);
        }
        return null;
    }
};

pub const Direction = enum {
    next,
    previous,
    left,
    right,
    up,
    down,
};

pub const Manager = struct {
    current_id: ?Id = null,

    pub inline fn current(self: *const Manager) ?Id {
        return self.current_id;
    }

    pub inline fn clear(self: *Manager) bool {
        const changed = self.current_id != null;
        self.current_id = null;
        return changed;
    }

    pub fn set(self: *Manager, registry: *const Registry, id: Id) error{
        UnknownId,
        NotFocusable,
    }!bool {
        const index = registry.indexOf(id) orelse return error.UnknownId;
        if (!eligible(registry.storage[index])) return error.NotFocusable;
        const changed = self.current_id == null or self.current_id.? != id;
        self.current_id = id;
        return changed;
    }

    pub fn move(self: *Manager, registry: *const Registry, direction: Direction) ?Id {
        return switch (direction) {
            .next, .previous => self.moveSequential(registry, direction),
            .left, .right, .up, .down => self.moveDirectional(registry, direction),
        };
    }

    fn moveSequential(self: *Manager, registry: *const Registry, direction: Direction) ?Id {
        const count = registry.count();
        if (count == 0) return null;
        const current_index = if (self.current_id) |id| registry.indexOf(id) else null;
        var index: usize = if (current_index) |active_index|
            active_index
        else if (direction == .next)
            count - 1
        else
            0;
        var visited: usize = 0;
        while (visited < count) : (visited += 1) {
            index = if (direction == .next)
                (index + 1) % count
            else if (index == 0)
                count - 1
            else
                index - 1;
            const node = registry.storage[index];
            if (!eligible(node)) continue;
            self.current_id = node.id;
            return node.id;
        }
        self.current_id = null;
        return null;
    }

    fn moveDirectional(self: *Manager, registry: *const Registry, direction: Direction) ?Id {
        const current_index = if (self.current_id) |id| registry.indexOf(id) else null;
        if (current_index == null or !eligible(registry.storage[current_index.?])) {
            for (registry.storage[0..registry.len]) |node| {
                if (!eligible(node)) continue;
                self.current_id = node.id;
                return node.id;
            }
            self.current_id = null;
            return null;
        }

        const active = registry.storage[current_index.?];
        const current_x = centerX2(active.rect);
        const current_y = centerY2(active.rect);
        var best_index: ?usize = null;
        var best_primary: u32 = std.math.maxInt(u32);
        var best_secondary: u32 = std.math.maxInt(u32);
        for (registry.storage[0..registry.len], 0..) |candidate, index| {
            if (index == current_index.? or !eligible(candidate)) continue;
            const candidate_x = centerX2(candidate.rect);
            const candidate_y = centerY2(candidate.rect);
            const primary: u32, const secondary: u32 = switch (direction) {
                .left => if (candidate_x < current_x)
                    .{ current_x - candidate_x, absDiff(candidate_y, current_y) }
                else
                    continue,
                .right => if (candidate_x > current_x)
                    .{ candidate_x - current_x, absDiff(candidate_y, current_y) }
                else
                    continue,
                .up => if (candidate_y < current_y)
                    .{ current_y - candidate_y, absDiff(candidate_x, current_x) }
                else
                    continue,
                .down => if (candidate_y > current_y)
                    .{ candidate_y - current_y, absDiff(candidate_x, current_x) }
                else
                    continue,
                else => unreachable,
            };
            if (primary > best_primary or primary == best_primary and secondary >= best_secondary) continue;
            best_index = index;
            best_primary = primary;
            best_secondary = secondary;
        }
        const index = best_index orelse return null;
        self.current_id = registry.storage[index].id;
        return self.current_id;
    }
};

pub const RouteResult = struct {
    update: widget.Update = .ignored,
    stop: bool = false,

    pub inline fn continueWith(update: widget.Update) RouteResult {
        return .{ .update = update };
    }

    pub inline fn stopWith(update: widget.Update) RouteResult {
        return .{ .update = update, .stop = true };
    }

    pub inline fn merge(self: RouteResult, other: RouteResult) RouteResult {
        return .{ .update = self.update.merge(other.update), .stop = self.stop or other.stop };
    }
};

/// Routes one borrowed event through a root-to-target path without storing it.
pub inline fn route(router: anytype, path: []const Id, event: input.Event) RouteResult {
    if (path.len == 0) return .{};
    const Router = switch (@typeInfo(@TypeOf(router))) {
        .pointer => |pointer| pointer.child,
        else => @compileError("focus.route expects a pointer to caller-owned router state"),
    };
    var result: RouteResult = .{};
    if (@hasDecl(Router, "capture")) {
        for (path[0 .. path.len - 1]) |id| {
            result = result.merge(router.capture(id, event));
            if (result.stop) return result;
        }
    }
    result = result.merge(router.target(path[path.len - 1], event));
    if (result.stop) return result;
    if (@hasDecl(Router, "bubble")) {
        var index = path.len - 1;
        while (index != 0) {
            index -= 1;
            result = result.merge(router.bubble(path[index], event));
            if (result.stop) return result;
        }
    }
    return result;
}

inline fn eligible(node: Node) bool {
    return node.focusable and node.enabled and !node.rect.isEmpty();
}

inline fn centerX2(rect: render.Rect) u32 {
    return @as(u32, rect.x) * 2 + rect.width;
}

inline fn centerY2(rect: render.Rect) u32 {
    return @as(u32, rect.y) * 2 + rect.height;
}

inline fn absDiff(lhs: u32, rhs: u32) u32 {
    return if (lhs >= rhs) lhs - rhs else rhs - lhs;
}

test "focus registry is bounded and builds stable paths" {
    var storage: [4]Node = undefined;
    var registry = try Registry.init(&storage);
    try registry.add(.{ .id = 1, .rect = .{ .x = 0, .y = 0, .width = 20, .height = 10 }, .focusable = false });
    try registry.add(.{ .id = 2, .parent = 1, .rect = .{ .x = 1, .y = 1, .width = 4, .height = 2 } });
    try registry.add(.{ .id = 3, .parent = 2, .rect = .{ .x = 2, .y = 1, .width = 2, .height = 1 } });
    try std.testing.expectError(
        error.DuplicateId,
        registry.add(.{ .id = 3, .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 } }),
    );
    try std.testing.expectError(
        error.MissingParent,
        registry.add(.{ .id = 4, .parent = 99, .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 } }),
    );

    var path_buffer: [3]Id = undefined;
    const target_path = try registry.path(3, &path_buffer);
    try std.testing.expectEqualSlices(Id, &.{ 1, 2, 3 }, target_path);
    try std.testing.expectEqual(@as(?Id, 3), registry.hit(.{ .x = 2, .y = 1 }));
}

test "focus navigation is deterministic and geometric" {
    var storage: [5]Node = undefined;
    var registry = try Registry.init(&storage);
    try registry.add(.{ .id = 1, .rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 } });
    try registry.add(.{ .id = 2, .rect = .{ .x = 10, .y = 0, .width = 2, .height = 1 } });
    try registry.add(.{ .id = 3, .rect = .{ .x = 0, .y = 5, .width = 2, .height = 1 } });
    try registry.add(.{ .id = 4, .rect = .{ .x = 10, .y = 5, .width = 2, .height = 1 }, .enabled = false });

    var manager: Manager = .{};
    try std.testing.expectEqual(@as(?Id, 1), manager.move(&registry, .next));
    try std.testing.expectEqual(@as(?Id, 2), manager.move(&registry, .right));
    try std.testing.expectEqual(@as(?Id, 1), manager.move(&registry, .left));
    try std.testing.expectEqual(@as(?Id, 3), manager.move(&registry, .down));
    try std.testing.expectEqual(@as(?Id, 2), manager.move(&registry, .previous));
    try std.testing.expectError(error.NotFocusable, manager.set(&registry, 4));
    for (registry.storage[0..registry.len]) |*node| node.enabled = false;
    try std.testing.expectEqual(@as(?Id, null), manager.move(&registry, .next));
    try std.testing.expectEqual(@as(?Id, null), manager.current());
}

test "event routing captures targets bubbles and stops" {
    const Router = struct {
        log: [8]u32 = @splat(0),
        len: usize = 0,
        stop_capture: bool = false,

        fn append(self: *@This(), value: u32) void {
            self.log[self.len] = value;
            self.len += 1;
        }

        fn capture(self: *@This(), id: Id, _: input.Event) RouteResult {
            self.append(id);
            if (self.stop_capture and id == 2) return .stopWith(.handled);
            return .continueWith(.ignored);
        }

        fn target(self: *@This(), id: Id, _: input.Event) RouteResult {
            self.append(100 + id);
            return .continueWith(.redraw);
        }

        fn bubble(self: *@This(), id: Id, _: input.Event) RouteResult {
            self.append(200 + id);
            return .continueWith(.handled);
        }
    };

    const path = [_]Id{ 1, 2, 3 };
    var router: Router = .{};
    const result = route(&router, &path, .focus_in);
    try std.testing.expectEqual(widget.Update.redraw, result.update);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 103, 202, 201 }, router.log[0..router.len]);

    router = .{ .stop_capture = true };
    const stopped = route(&router, &path, .focus_out);
    try std.testing.expect(stopped.stop);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, router.log[0..router.len]);
}
