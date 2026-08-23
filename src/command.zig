const std = @import("std");
const input = @import("input.zig");

pub const Id = u32;
pub const Context = u32;
pub const global_context: Context = 0;
pub const max_chord_len = 4;

pub const Stroke = struct {
    code: input.KeyCode,
    modifiers: input.Modifiers = .{},
    action: input.KeyAction = .press,

    pub fn press(code: input.KeyCode, modifiers: input.Modifiers) Stroke {
        return .{ .code = code, .modifiers = normalizeModifiers(modifiers) };
    }

    pub fn fromKey(event_key: input.Key) Stroke {
        return .{
            .code = event_key.code,
            .modifiers = normalizeModifiers(event_key.modifiers),
            .action = event_key.action,
        };
    }

    pub fn eql(self: Stroke, other: Stroke) bool {
        return std.meta.eql(self.code, other.code) and
            @as(u8, @bitCast(self.modifiers)) == @as(u8, @bitCast(other.modifiers)) and
            self.action == other.action;
    }

    inline fn key(self: Stroke) u64 {
        const tag = std.meta.activeTag(self.code);
        const payload: u32 = switch (self.code) {
            .codepoint => |value| value,
            .functional => |value| value,
            .function => |value| value,
            else => 0,
        };
        return payload |
            (@as(u64, @intFromEnum(tag)) << 21) |
            (@as(u64, @as(u8, @bitCast(self.modifiers))) << 32) |
            (@as(u64, @intFromEnum(self.action)) << 40);
    }
};

pub const Binding = struct {
    context: Context,
    command: Id,
    stroke_start: u16,
    stroke_count: u8,
    first_stroke_key: u64,
};

pub const Registry = struct {
    bindings_storage: []Binding,
    strokes_storage: []Stroke,
    binding_len: u16 = 0,
    stroke_len: u16 = 0,
    revision: u64 = 0,

    pub fn init(bindings: []Binding, stroke_storage: []Stroke) error{CapacityTooLarge}!Registry {
        if (bindings.len > std.math.maxInt(u16) or stroke_storage.len > std.math.maxInt(u16)) {
            return error.CapacityTooLarge;
        }
        return .{ .bindings_storage = bindings, .strokes_storage = stroke_storage };
    }

    pub inline fn reset(self: *Registry) void {
        self.binding_len = 0;
        self.stroke_len = 0;
        self.revision +%= 1;
    }

    pub fn add(
        self: *Registry,
        context: Context,
        command: Id,
        chord: []const Stroke,
    ) error{
        InvalidChord,
        BindingCapacityExceeded,
        StrokeCapacityExceeded,
        DuplicateBinding,
        AmbiguousBinding,
    }!void {
        if (chord.len == 0 or chord.len > max_chord_len) return error.InvalidChord;
        for (self.bindings_storage[0..self.binding_len]) |binding| {
            if (!contextsOverlap(context, binding.context)) continue;
            const existing = self.strokes(binding);
            const common = @min(existing.len, chord.len);
            var equal_prefix = true;
            for (existing[0..common], chord[0..common]) |registered, candidate| {
                if (!registered.eql(normalizeStroke(candidate))) {
                    equal_prefix = false;
                    break;
                }
            }
            if (!equal_prefix) continue;
            if (existing.len == chord.len) {
                if (binding.context == context) return error.DuplicateBinding;
                continue;
            }
            return error.AmbiguousBinding;
        }
        if (self.binding_len == self.bindings_storage.len) return error.BindingCapacityExceeded;
        if (@as(usize, self.stroke_len) + chord.len > self.strokes_storage.len) {
            return error.StrokeCapacityExceeded;
        }

        const start = self.stroke_len;
        for (chord, self.strokes_storage[start .. start + chord.len]) |stroke, *destination| {
            destination.* = normalizeStroke(stroke);
        }
        const binding: Binding = .{
            .context = context,
            .command = command,
            .stroke_start = start,
            .stroke_count = @intCast(chord.len),
            .first_stroke_key = normalizeStroke(chord[0]).key(),
        };
        var insertion = self.binding_len;
        while (insertion != 0 and self.bindings_storage[insertion - 1].first_stroke_key > binding.first_stroke_key) {
            self.bindings_storage[insertion] = self.bindings_storage[insertion - 1];
            insertion -= 1;
        }
        self.bindings_storage[insertion] = binding;
        self.binding_len += 1;
        self.stroke_len += @intCast(chord.len);
        self.revision +%= 1;
    }

    pub inline fn count(self: *const Registry) usize {
        return self.binding_len;
    }

    fn lookup(self: *const Registry, context: Context, prefix: []const Stroke) Lookup {
        const first_key = prefix[0].key();
        var lower: usize = 0;
        var upper: usize = self.binding_len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            if (self.bindings_storage[middle].first_stroke_key < first_key)
                lower = middle + 1
            else
                upper = middle;
        }
        var range_end = lower;
        while (range_end < self.binding_len and self.bindings_storage[range_end].first_stroke_key == first_key) {
            range_end += 1;
        }
        return self.lookupRange(context, prefix, @intCast(lower), @intCast(range_end));
    }

    fn lookupRange(
        self: *const Registry,
        context: Context,
        prefix: []const Stroke,
        range_start: u16,
        range_end: u16,
    ) Lookup {
        var global: Lookup = .{ .range_start = range_start, .range_end = range_end };
        var local: Lookup = .{ .range_start = range_start, .range_end = range_end };
        for (self.bindings_storage[range_start..range_end]) |binding| {
            if (binding.context != context and binding.context != global_context) continue;
            const chord = self.strokes(binding);
            if (prefix.len > chord.len or
                prefix.len > 1 and !strokeSlicesEql(prefix[1..], chord[1..prefix.len])) continue;
            const destination = if (binding.context == context) &local else &global;
            if (prefix.len == chord.len) destination.command = binding.command else destination.pending = true;
        }
        if (local.command != null or local.pending) return local;
        return global;
    }

    inline fn strokes(self: *const Registry, binding: Binding) []const Stroke {
        return self.strokes_storage[binding.stroke_start .. binding.stroke_start + binding.stroke_count];
    }
};

pub const Match = union(enum) {
    none,
    pending,
    command: Id,
};

pub const Matcher = struct {
    prefix: [max_chord_len]Stroke = undefined,
    prefix_len: u8 = 0,
    context: Context = global_context,
    range_start: u16 = 0,
    range_end: u16 = 0,
    cached_registry: ?*const Registry = null,
    cached_revision: u64 = 0,
    cached_first_key: u64 = 0,

    pub inline fn pending(self: *const Matcher) bool {
        return self.prefix_len != 0;
    }

    pub inline fn cancel(self: *Matcher) bool {
        const changed = self.prefix_len != 0;
        self.prefix_len = 0;
        return changed;
    }

    pub fn feed(
        self: *Matcher,
        registry: *const Registry,
        context: Context,
        key: input.Key,
    ) Match {
        const stroke = Stroke.fromKey(key);
        if (self.prefix_len != 0 and (self.context != context or self.cached_registry != registry or
            self.cached_revision != registry.revision)) self.prefix_len = 0;
        const retry = self.prefix_len != 0;
        if (self.tryStroke(registry, context, stroke)) |matched| return matched;
        if (!retry) return .none;
        self.prefix_len = 0;
        return self.tryStroke(registry, context, stroke) orelse .none;
    }

    fn tryStroke(
        self: *Matcher,
        registry: *const Registry,
        context: Context,
        stroke: Stroke,
    ) ?Match {
        if (self.prefix_len == max_chord_len) return null;
        self.context = context;
        self.prefix[self.prefix_len] = stroke;
        self.prefix_len += 1;
        const found = if (self.prefix_len == 1) found: {
            const first_key = stroke.key();
            if (self.cached_registry == registry and self.cached_revision == registry.revision and
                self.cached_first_key == first_key)
            {
                break :found registry.lookupRange(context, self.prefix[0..1], self.range_start, self.range_end);
            }
            const lookup = registry.lookup(context, self.prefix[0..1]);
            self.cached_registry = registry;
            self.cached_revision = registry.revision;
            self.cached_first_key = first_key;
            self.range_start = lookup.range_start;
            self.range_end = lookup.range_end;
            break :found lookup;
        } else registry.lookupRange(
            context,
            self.prefix[0..self.prefix_len],
            self.range_start,
            self.range_end,
        );
        if (found.command) |command| {
            self.prefix_len = 0;
            return .{ .command = command };
        }
        if (found.pending) return .pending;
        self.prefix_len = 0;
        return null;
    }
};

const Lookup = struct {
    command: ?Id = null,
    pending: bool = false,
    range_start: u16 = 0,
    range_end: u16 = 0,
};

inline fn normalizeModifiers(modifiers: input.Modifiers) input.Modifiers {
    var result = modifiers;
    result.caps_lock = false;
    result.num_lock = false;
    return result;
}

inline fn normalizeStroke(stroke: Stroke) Stroke {
    return .{
        .code = stroke.code,
        .modifiers = normalizeModifiers(stroke.modifiers),
        .action = stroke.action,
    };
}

inline fn contextsOverlap(lhs: Context, rhs: Context) bool {
    return lhs == rhs or lhs == global_context or rhs == global_context;
}

fn strokeSlicesEql(lhs: []const Stroke, rhs: []const Stroke) bool {
    for (lhs, rhs) |left, right| {
        if (!left.eql(right)) return false;
    }
    return true;
}

test "command registry rejects conflicts and permits contextual overrides" {
    var bindings: [6]Binding = undefined;
    var strokes: [16]Stroke = undefined;
    var registry = try Registry.init(&bindings, &strokes);
    const control_x = Stroke.press(.{ .codepoint = 'x' }, .{ .control = true });
    const control_k = Stroke.press(.{ .codepoint = 'k' }, .{ .control = true });
    const control_c = Stroke.press(.{ .codepoint = 'c' }, .{ .control = true });

    try registry.add(global_context, 1, &.{control_x});
    try registry.add(7, 2, &.{control_x});
    try std.testing.expectError(error.DuplicateBinding, registry.add(7, 3, &.{control_x}));
    try registry.add(7, 4, &.{ control_k, control_c });
    try std.testing.expectError(error.AmbiguousBinding, registry.add(global_context, 5, &.{control_k}));
    try std.testing.expectEqual(@as(usize, 3), registry.count());
}

test "command matcher handles chords contexts retry and lock modifiers" {
    var bindings: [6]Binding = undefined;
    var strokes: [16]Stroke = undefined;
    var registry = try Registry.init(&bindings, &strokes);
    const g = Stroke.press(.{ .codepoint = 'g' }, .{});
    const x = Stroke.press(.{ .codepoint = 'x' }, .{ .control = true });
    try registry.add(global_context, 1, &.{ g, g });
    try registry.add(global_context, 2, &.{x});
    try registry.add(9, 3, &.{x});

    var matcher: Matcher = .{};
    try std.testing.expectEqual(Match.pending, matcher.feed(&registry, global_context, .{ .code = .{ .codepoint = 'g' } }));
    try std.testing.expectEqual(
        Match{ .command = 1 },
        matcher.feed(&registry, global_context, .{ .code = .{ .codepoint = 'g' } }),
    );
    try std.testing.expectEqual(Match.pending, matcher.feed(&registry, global_context, .{ .code = .{ .codepoint = 'g' } }));
    try std.testing.expectEqual(
        Match{ .command = 2 },
        matcher.feed(&registry, global_context, .{
            .code = .{ .codepoint = 'x' },
            .modifiers = .{ .control = true },
        }),
    );
    try std.testing.expectEqual(
        Match{ .command = 3 },
        matcher.feed(&registry, 9, .{
            .code = .{ .codepoint = 'x' },
            .modifiers = .{ .control = true, .caps_lock = true },
        }),
    );
    try std.testing.expect(!matcher.pending());
    try std.testing.expect(!matcher.cancel());
}

test "command registry capacities are explicit" {
    var bindings: [1]Binding = undefined;
    var strokes: [1]Stroke = undefined;
    var registry = try Registry.init(&bindings, &strokes);
    const a = Stroke.press(.{ .codepoint = 'a' }, .{});
    const b = Stroke.press(.{ .codepoint = 'b' }, .{});
    try std.testing.expectError(error.StrokeCapacityExceeded, registry.add(global_context, 1, &.{ a, b }));
    try registry.add(global_context, 2, &.{a});
    try std.testing.expectError(error.BindingCapacityExceeded, registry.add(1, 3, &.{b}));
}

test "command matcher invalidates cached ranges after registry mutation" {
    var bindings: [3]Binding = undefined;
    var strokes: [3]Stroke = undefined;
    var registry = try Registry.init(&bindings, &strokes);
    const zero = Stroke.press(.{ .codepoint = '0' }, .{});
    const a = Stroke.press(.{ .codepoint = 'a' }, .{});
    try registry.add(global_context, 1, &.{a});

    var matcher: Matcher = .{};
    try std.testing.expectEqual(
        Match{ .command = 1 },
        matcher.feed(&registry, global_context, .{ .code = .{ .codepoint = 'a' } }),
    );

    try registry.add(global_context, 2, &.{zero});
    try std.testing.expectEqual(
        Match{ .command = 1 },
        matcher.feed(&registry, global_context, .{ .code = .{ .codepoint = 'a' } }),
    );

    registry.reset();
    try registry.add(global_context, 3, &.{a});
    try std.testing.expectEqual(
        Match{ .command = 3 },
        matcher.feed(&registry, global_context, .{ .code = .{ .codepoint = 'a' } }),
    );
}

test "command matcher cancels pending chords when registry identity or revision changes" {
    var first_bindings: [3]Binding = undefined;
    var first_strokes: [6]Stroke = undefined;
    var first = try Registry.init(&first_bindings, &first_strokes);
    const g = Stroke.press(.{ .codepoint = 'g' }, .{});
    try first.add(global_context, 1, &.{ g, g });

    var matcher: Matcher = .{};
    try std.testing.expectEqual(Match.pending, matcher.feed(&first, global_context, .{ .code = .{ .codepoint = 'g' } }));
    first.reset();
    try first.add(global_context, 2, &.{ g, g });
    try std.testing.expectEqual(Match.pending, matcher.feed(&first, global_context, .{ .code = .{ .codepoint = 'g' } }));
    try std.testing.expectEqual(
        Match{ .command = 2 },
        matcher.feed(&first, global_context, .{ .code = .{ .codepoint = 'g' } }),
    );

    var second_bindings: [1]Binding = undefined;
    var second_strokes: [1]Stroke = undefined;
    var second = try Registry.init(&second_bindings, &second_strokes);
    try second.add(global_context, 3, &.{g});
    try std.testing.expectEqual(Match.pending, matcher.feed(&first, global_context, .{ .code = .{ .codepoint = 'g' } }));
    try std.testing.expectEqual(
        Match{ .command = 3 },
        matcher.feed(&second, global_context, .{ .code = .{ .codepoint = 'g' } }),
    );
}
