const std = @import("std");

pub const CompletionOptions = struct {
    wrap: bool = true,
};

/// Selection and acceptance state over application-owned completion candidates.
/// `Provider` supplies `count()` and `candidate(index)`.
pub fn Completion(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        options: CompletionOptions = .{},
        selected: ?usize = null,
        accepted: ?usize = null,

        const Self = @This();

        pub fn reset(self: *Self) void {
            self.selected = null;
            self.accepted = null;
        }

        pub fn normalize(self: *Self) bool {
            const old_selection = self.selected;
            const count = self.provider.count();
            if (count == 0) {
                self.selected = null;
            } else if (self.selected) |selected| {
                if (selected >= count) self.selected = count - 1;
            }
            return self.selected != old_selection;
        }

        pub fn next(self: *Self) bool {
            const count = self.provider.count();
            if (count == 0) return self.normalize();
            const old_selection = self.selected;
            self.selected = if (old_selection) |selected|
                if (selected + 1 < count) selected + 1 else if (self.options.wrap) 0 else selected
            else
                0;
            return self.selected != old_selection;
        }

        pub fn previous(self: *Self) bool {
            const count = self.provider.count();
            if (count == 0) return self.normalize();
            const previous_selection = self.selected;
            self.selected = if (previous_selection) |selected|
                if (selected != 0) selected - 1 else if (self.options.wrap) count - 1 else selected
            else
                count - 1;
            return self.selected != previous_selection;
        }

        pub fn candidate(self: *Self) ?[]const u8 {
            _ = self.normalize();
            const selected = self.selected orelse return null;
            return self.provider.candidate(selected);
        }

        pub fn accept(self: *Self) ?usize {
            _ = self.normalize();
            self.accepted = self.selected;
            return self.accepted;
        }

        pub fn takeAcceptance(self: *Self) ?usize {
            const accepted = self.accepted;
            self.accepted = null;
            return accepted;
        }
    };
}

pub const Match = struct {
    item: usize,
    start: usize,
    end: usize,
};

pub const SearchOptions = struct {
    wrap: bool = true,
};

/// Exact UTF-8 substring search over a provider supplying `count()` and `text(index)`.
pub fn Search(comptime Provider: type) type {
    return struct {
        provider: *Provider,
        options: SearchOptions = .{},
        query: []const u8 = "",
        current: ?Match = null,

        const Self = @This();

        pub fn setQuery(self: *Self, query: []const u8) error{InvalidUtf8}!bool {
            if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidUtf8;
            const changed = !std.mem.eql(u8, self.query, query);
            self.query = query;
            self.current = self.firstMatch();
            return changed;
        }

        pub fn refresh(self: *Self) bool {
            const previous_match = self.current;
            self.current = self.firstMatch();
            return !std.meta.eql(previous_match, self.current);
        }

        pub fn next(self: *Self) bool {
            if (self.query.len == 0) return self.clearCurrent();
            const previous_match = self.current;
            var first: ?Match = null;
            var following: ?Match = null;
            self.scan(struct {
                fn visit(context: *const @This(), match: Match) bool {
                    if (context.first.* == null) context.first.* = match;
                    if (isAfter(match, context.previous_match)) {
                        context.following.* = match;
                        return false;
                    }
                    return true;
                }

                first: *?Match,
                following: *?Match,
                previous_match: ?Match,
            }{ .first = &first, .following = &following, .previous_match = previous_match });
            self.current = following orelse if (self.options.wrap) first else previous_match;
            return !std.meta.eql(previous_match, self.current);
        }

        pub fn previous(self: *Self) bool {
            if (self.query.len == 0) return self.clearCurrent();
            const previous_match = self.current;
            var preceding: ?Match = null;
            var last: ?Match = null;
            self.scan(struct {
                fn visit(context: *const @This(), match: Match) bool {
                    context.last.* = match;
                    if (isBefore(match, context.previous_match)) {
                        context.preceding.* = match;
                        return true;
                    }
                    return context.preceding.* == null and context.wrap;
                }

                preceding: *?Match,
                last: *?Match,
                previous_match: ?Match,
                wrap: bool,
            }{ .preceding = &preceding, .last = &last, .previous_match = previous_match, .wrap = self.options.wrap });
            self.current = preceding orelse if (self.options.wrap) last else previous_match;
            return !std.meta.eql(previous_match, self.current);
        }

        fn firstMatch(self: *Self) ?Match {
            if (self.query.len == 0) return null;
            for (0..self.provider.count()) |item| {
                const value = self.provider.text(item);
                const start = std.mem.indexOf(u8, value, self.query) orelse continue;
                return .{ .item = item, .start = start, .end = start + self.query.len };
            }
            return null;
        }

        fn scan(self: *Self, context: anytype) void {
            for (0..self.provider.count()) |item| {
                const value = self.provider.text(item);
                var offset: usize = 0;
                while (offset <= value.len -| self.query.len) {
                    const relative = std.mem.indexOfPos(u8, value, offset, self.query) orelse break;
                    if (!context.visit(.{ .item = item, .start = relative, .end = relative + self.query.len })) return;
                    offset = relative + 1;
                }
            }
        }

        fn clearCurrent(self: *Self) bool {
            const changed = self.current != null;
            self.current = null;
            return changed;
        }
    };
}

fn isAfter(candidate: Match, reference: ?Match) bool {
    const value = reference orelse return true;
    return candidate.item > value.item or candidate.item == value.item and candidate.start > value.start;
}

fn isBefore(candidate: Match, reference: ?Match) bool {
    const value = reference orelse return true;
    return candidate.item < value.item or candidate.item == value.item and candidate.start < value.start;
}

test "completion normalizes dynamic providers and exposes acceptance" {
    const Provider = struct {
        values: []const []const u8,

        pub fn count(self: *@This()) usize {
            return self.values.len;
        }

        pub fn candidate(self: *@This(), index: usize) []const u8 {
            return self.values[index];
        }
    };
    const values = [_][]const u8{ "alpha", "beta" };
    var provider = Provider{ .values = &values };
    var completion = Completion(Provider){ .provider = &provider };
    try std.testing.expect(completion.next());
    try std.testing.expectEqualStrings("alpha", completion.candidate().?);
    try std.testing.expect(completion.previous());
    try std.testing.expectEqual(@as(?usize, 1), completion.accept());
    try std.testing.expectEqual(@as(?usize, 1), completion.takeAcceptance());
    try std.testing.expectEqual(@as(?usize, null), completion.takeAcceptance());
}

test "search traverses exact matches across provider items" {
    const Provider = struct {
        values: []const []const u8,

        pub fn count(self: *@This()) usize {
            return self.values.len;
        }

        pub fn text(self: *@This(), index: usize) []const u8 {
            return self.values[index];
        }
    };
    const values = [_][]const u8{ "alpha alpha", "beta alpha" };
    var provider = Provider{ .values = &values };
    var search = Search(Provider){ .provider = &provider };
    try std.testing.expect(try search.setQuery("alpha"));
    try std.testing.expectEqual(Match{ .item = 0, .start = 0, .end = 5 }, search.current.?);
    try std.testing.expect(search.next());
    try std.testing.expectEqual(Match{ .item = 0, .start = 6, .end = 11 }, search.current.?);
    try std.testing.expect(search.previous());
    try std.testing.expectEqual(Match{ .item = 0, .start = 0, .end = 5 }, search.current.?);
    try std.testing.expect(search.previous());
    try std.testing.expectEqual(Match{ .item = 1, .start = 5, .end = 10 }, search.current.?);
}

test "search stops provider traversal after the requested ordered match" {
    const Provider = struct {
        calls: usize = 0,

        pub fn count(_: *@This()) usize {
            return 4;
        }

        pub fn text(self: *@This(), index: usize) []const u8 {
            self.calls += 1;
            return if (index == 0) "match first" else "no result";
        }
    };
    var provider: Provider = .{};
    var search = Search(Provider){ .provider = &provider };
    _ = try search.setQuery("match");
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqual(Match{ .item = 0, .start = 0, .end = 5 }, search.current.?);
}
