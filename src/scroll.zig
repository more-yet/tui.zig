const std = @import("std");
const text_line = @import("text/line.zig");

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

/// Caller-owned row viewport with explicit tail-follow policy.
pub const Viewport = struct {
    top: usize = 0,
    follow: bool = true,

    /// Reconciles append, head eviction, data shrink, and viewport resize.
    pub fn update(self: *Viewport, total_rows: usize, visible_rows: u16, dropped_head_rows: usize) bool {
        const previous = self.*;
        if (total_rows == 0) {
            self.top = 0;
        } else if (self.follow) {
            self.top = maxTop(total_rows, visible_rows);
        } else {
            self.top -|= dropped_head_rows;
            self.top = @min(self.top, maxTop(total_rows, visible_rows));
        }
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn setFollow(self: *Viewport, enabled: bool, total_rows: usize, visible_rows: u16) bool {
        const previous = self.*;
        self.follow = enabled;
        _ = self.update(total_rows, visible_rows, 0);
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn scrollUp(self: *Viewport, rows: usize, total_rows: usize, visible_rows: u16) bool {
        const previous = self.*;
        _ = self.update(total_rows, visible_rows, 0);
        if (rows != 0) {
            self.follow = false;
            self.top -|= rows;
        }
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn scrollDown(self: *Viewport, rows: usize, total_rows: usize, visible_rows: u16) bool {
        const previous = self.*;
        _ = self.update(total_rows, visible_rows, 0);
        if (rows != 0 and !self.follow) {
            self.top = @min(self.top +| rows, maxTop(total_rows, visible_rows));
        }
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn pageUp(self: *Viewport, total_rows: usize, visible_rows: u16) bool {
        return self.scrollUp(pageRows(visible_rows), total_rows, visible_rows);
    }

    pub fn pageDown(self: *Viewport, total_rows: usize, visible_rows: u16) bool {
        return self.scrollDown(pageRows(visible_rows), total_rows, visible_rows);
    }

    pub fn home(self: *Viewport, total_rows: usize, visible_rows: u16) bool {
        const previous = self.*;
        _ = self.update(total_rows, visible_rows, 0);
        self.follow = false;
        self.top = 0;
        return self.top != previous.top or self.follow != previous.follow;
    }

    pub fn end(self: *Viewport, total_rows: usize, visible_rows: u16) bool {
        return self.setFollow(true, total_rows, visible_rows);
    }

    pub fn visibleRange(self: *const Viewport, total_rows: usize, visible_rows: u16) Range {
        if (total_rows == 0) return .{ .start = 0, .end = 0 };
        const start = if (self.follow)
            maxTop(total_rows, visible_rows)
        else
            @min(self.top, maxTop(total_rows, visible_rows));
        return .{ .start = start, .end = start + @min(total_rows - start, visible_rows) };
    }
};

pub const AppendResult = struct {
    dropped_rows: usize,
};

pub const AppendError = error{
    NoCapacity,
    LineTooLong,
    InvalidLine,
};

pub const DecodeResult = struct {
    appended_rows: usize = 0,
    dropped_rows: usize = 0,
    invalid_rows: usize = 0,
    overlong_rows: usize = 0,
    unavailable_rows: usize = 0,

    pub fn rejectedRows(self: DecodeResult) usize {
        return (self.invalid_rows +| self.overlong_rows) +| self.unavailable_rows;
    }

    pub fn merge(self: *DecodeResult, other: DecodeResult) void {
        self.appended_rows +|= other.appended_rows;
        self.dropped_rows +|= other.dropped_rows;
        self.invalid_rows +|= other.invalid_rows;
        self.overlong_rows +|= other.overlong_rows;
        self.unavailable_rows +|= other.unavailable_rows;
    }
};

/// Bounded FIFO of complete renderable lines. Borrowed rows expire when their slot is overwritten.
pub fn LineRing(comptime max_line_bytes_value: usize) type {
    return struct {
        pub const max_line_bytes = max_line_bytes_value;

        pub const Slot = struct {
            len: usize = 0,
            bytes: [max_line_bytes]u8 = undefined,
        };

        const Self = @This();

        storage: []Slot,
        head: usize = 0,
        line_count: usize = 0,

        pub fn init(storage: []Slot) Self {
            return .{ .storage = storage };
        }

        pub fn capacity(self: *const Self) usize {
            return self.storage.len;
        }

        pub fn count(self: *const Self) usize {
            return self.line_count;
        }

        pub fn clear(self: *Self) usize {
            const dropped_rows = self.line_count;
            self.head = 0;
            self.line_count = 0;
            return dropped_rows;
        }

        pub fn append(self: *Self, line: []const u8) AppendError!AppendResult {
            if (self.storage.len == 0) return error.NoCapacity;
            if (line.len > max_line_bytes) return error.LineTooLong;
            _ = text_line.measure(line, .narrow) catch return error.InvalidLine;

            return self.appendValid(line);
        }

        inline fn appendValid(self: *Self, line: []const u8) AppendError!AppendResult {
            if (self.storage.len == 0) return error.NoCapacity;
            if (line.len > max_line_bytes) return error.LineTooLong;
            const full = self.line_count == self.storage.len;
            const index = if (full) self.head else self.indexOf(self.line_count);
            copyLine(self.storage[index].bytes[0..line.len], line);
            self.storage[index].len = line.len;
            if (full) {
                self.head = nextIndex(self.head, self.storage.len);
            } else {
                self.line_count += 1;
            }
            return .{ .dropped_rows = @intFromBool(full) };
        }

        pub fn get(self: *const Self, index: usize) ?[]const u8 {
            if (index >= self.line_count) return null;
            const slot = &self.storage[self.indexOf(index)];
            return slot.bytes[0..slot.len];
        }

        /// Provider-compatible accessor. `index` must be less than `count()`.
        pub fn row(self: *const Self, index: usize) []const u8 {
            return self.get(index) orelse unreachable;
        }

        fn indexOf(self: *const Self, offset: usize) usize {
            const tail_space = self.storage.len - self.head;
            return if (offset < tail_space) self.head + offset else offset - tail_space;
        }
    };
}

/// Incrementally frames untrusted byte chunks into complete renderable lines.
pub fn LineDecoder(comptime max_line_bytes_value: usize) type {
    return struct {
        pub const max_line_bytes = max_line_bytes_value;
        pub const Ring = LineRing(max_line_bytes);

        const Self = @This();
        const Rejection = enum { invalid, overlong };

        bytes: [max_line_bytes]u8 = undefined,
        len: usize = 0,
        pending_cr: bool = false,
        discarding: ?Rejection = null,

        pub fn feed(self: *Self, ring: *Ring, input: []const u8) DecodeResult {
            if (self.len == 0 and !self.pending_cr and self.discarding == null and
                std.mem.indexOfScalar(u8, input, '\r') == null)
            {
                return self.feedLf(ring, input);
            }

            var result: DecodeResult = .{};
            for (input) |byte| {
                if (self.discarding) |reason| {
                    if (byte == '\n') {
                        recordRejection(&result, reason);
                        self.reset();
                    }
                    continue;
                }
                if (self.pending_cr) {
                    self.pending_cr = false;
                    if (byte == '\n') {
                        self.appendLine(ring, &result);
                    } else {
                        self.discarding = .invalid;
                    }
                    continue;
                }
                switch (byte) {
                    '\r' => self.pending_cr = true,
                    '\n' => self.appendLine(ring, &result),
                    else => {
                        if (comptime max_line_bytes == 0) {
                            self.discarding = .overlong;
                        } else if (self.len == self.bytes.len) {
                            self.discarding = .overlong;
                        } else {
                            self.bytes[self.len] = byte;
                            self.len += 1;
                        }
                    },
                }
            }
            return result;
        }

        fn feedLf(self: *Self, ring: *Ring, input: []const u8) DecodeResult {
            var result: DecodeResult = .{};
            var start: usize = 0;
            for (input, 0..) |byte, end| {
                if (byte != '\n') continue;
                const line = input[start..end];
                if (line.len > max_line_bytes) {
                    result.overlong_rows += 1;
                } else {
                    self.appendComplete(ring, &result, line);
                }
                start = end + 1;
            }

            const tail = input[start..];
            if (tail.len > self.bytes.len) {
                self.discarding = .overlong;
            } else {
                @memcpy(self.bytes[0..tail.len], tail);
                self.len = tail.len;
            }
            return result;
        }

        inline fn appendComplete(self: *Self, ring: *Ring, result: *DecodeResult, line: []const u8) void {
            _ = self;
            std.debug.assert(line.len <= max_line_bytes);
            const appended = if (printableAscii(line))
                ring.appendValid(line)
            else
                ring.append(line);
            if (appended) |value| {
                result.appended_rows += 1;
                result.dropped_rows += value.dropped_rows;
            } else |err| switch (err) {
                error.NoCapacity => result.unavailable_rows += 1,
                error.LineTooLong => unreachable,
                error.InvalidLine => result.invalid_rows += 1,
            }
        }

        /// Flushes one final unterminated line and reports any incomplete rejected row.
        pub fn finish(self: *Self, ring: *Ring) DecodeResult {
            var result: DecodeResult = .{};
            if (self.discarding) |reason| {
                recordRejection(&result, reason);
                self.reset();
            } else if (self.pending_cr) {
                result.invalid_rows = 1;
                self.reset();
            } else if (self.len != 0) {
                self.appendLine(ring, &result);
            }
            return result;
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.pending_cr = false;
            self.discarding = null;
        }

        fn appendLine(self: *Self, ring: *Ring, result: *DecodeResult) void {
            const appended = ring.append(self.bytes[0..self.len]) catch |err| {
                switch (err) {
                    error.NoCapacity => result.unavailable_rows += 1,
                    error.LineTooLong => result.overlong_rows += 1,
                    error.InvalidLine => result.invalid_rows += 1,
                }
                self.len = 0;
                return;
            };
            result.appended_rows += 1;
            result.dropped_rows += appended.dropped_rows;
            self.len = 0;
        }

        fn recordRejection(result: *DecodeResult, rejection: Rejection) void {
            switch (rejection) {
                .invalid => result.invalid_rows += 1,
                .overlong => result.overlong_rows += 1,
            }
        }
    };
}

inline fn printableAscii(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return true;
}

fn nextIndex(index: usize, capacity: usize) usize {
    return if (index + 1 == capacity) 0 else index + 1;
}

fn copyLine(destination: []u8, source: []const u8) void {
    @memmove(destination, source);
}

fn maxTop(total_rows: usize, visible_rows: u16) usize {
    if (total_rows == 0) return 0;
    if (visible_rows == 0) return total_rows - 1;
    return total_rows -| visible_rows;
}

fn pageRows(visible_rows: u16) usize {
    return @max(@as(usize, 1), @as(usize, visible_rows) -| 1);
}
