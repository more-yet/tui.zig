const std = @import("std");
const input = @import("../input/event.zig");

/// Pinned protocol target: Kitty graphics protocol as documented on 2026-09-16.
/// Wire behavior was audited against kitty commit
/// 87ab3e98f4d399337777e4329960d7cd09101e99.
pub const specification_revision = "2026-09-16";
pub const specification_source =
    "https://github.com/kovidgoyal/kitty/blob/87ab3e98f4d399337777e4329960d7cd09101e99/docs/graphics-protocol.rst";
/// Maximum encoded control header supported by `Sender`.
pub const max_control_bytes = 480;

pub const ResponseMode = enum(u2) {
    /// Request success and error replies.
    all = 0,
    /// Suppress successful `OK` replies.
    errors_only = 1,
    /// Suppress all replies.
    none = 2,
};

pub const Format = enum(u8) {
    rgb = 24,
    rgba = 32,
    png = 100,
};

pub const Medium = enum(u8) {
    direct = 'd',
    file = 'f',
    temporary_file = 't',
    shared_memory = 's',
};

pub const Compression = enum(u8) {
    none,
    zlib,
};

pub const Identifiers = struct {
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
};

pub const Transmission = struct {
    format: Format = .rgba,
    medium: Medium = .direct,
    width_pixels: u32 = 0,
    height_pixels: u32 = 0,
    data_size_bytes: u32 = 0,
    data_offset_bytes: u32 = 0,
    identifiers: Identifiers = .{},
    compression: Compression = .none,
    transient: bool = false,
};

pub const CursorPolicy = enum(u1) {
    move = 0,
    preserve = 1,
};

pub const Placement = struct {
    source_x_pixels: u32 = 0,
    source_y_pixels: u32 = 0,
    source_width_pixels: u32 = 0,
    source_height_pixels: u32 = 0,
    cell_x_offset_pixels: u32 = 0,
    cell_y_offset_pixels: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    z_order: i32 = 0,
    cursor: CursorPolicy = .move,
    virtual: bool = false,
    parent_image_id: u32 = 0,
    parent_placement_id: u32 = 0,
    parent_x_cells: i32 = 0,
    parent_y_cells: i32 = 0,
};

pub const Transmit = struct {
    transmission: Transmission,
};

pub const TransmitAndDisplay = struct {
    transmission: Transmission,
    placement: Placement,
};

pub const Display = struct {
    identifiers: Identifiers,
    placement: Placement,
};

pub const Query = struct {
    transmission: Transmission,
};

pub const DeleteSelector = union(enum) {
    all: bool,
    image_id: struct { free_data: bool = false, image_id: u32, placement_id: u32 = 0 },
    image_number: struct { free_data: bool = false, image_number: u32, placement_id: u32 = 0 },
    cursor: bool,
    animation_frames: struct {
        free_data: bool = false,
        image_id: u32 = 0,
        image_number: u32 = 0,
        frame: u32 = 0,
    },
    cell: struct { free_data: bool = false, x: u32, y: u32 },
    cell_z: struct { free_data: bool = false, x: u32, y: u32, z_order: i32 },
    id_range: struct { free_data: bool = false, first: u32, last: u32 },
    column: struct { free_data: bool = false, x: u32 },
    row: struct { free_data: bool = false, y: u32 },
    z_order: struct { free_data: bool = false, z_order: i32 },
};

pub const Delete = struct {
    selector: DeleteSelector,
};

pub const CompositionMode = enum(u1) {
    alpha_blend = 0,
    overwrite = 1,
};

pub const AnimationFrame = struct {
    transmission: Transmission,
    destination_x_pixels: u32 = 0,
    destination_y_pixels: u32 = 0,
    base_frame: u32 = 0,
    edit_frame: u32 = 0,
    gap_ms: i32 = 0,
    composition: CompositionMode = .alpha_blend,
    background_rgba: u32 = 0,
};

pub const AnimationState = enum(u2) {
    stop = 1,
    run_wait = 2,
    run = 3,
};

pub const AnimationControl = struct {
    identifiers: Identifiers,
    state: ?AnimationState = null,
    frame: u32 = 0,
    gap_ms: i32 = 0,
    current_frame: u32 = 0,
    /// Wire semantics: 0 leaves unchanged, 1 loops forever, n>1 performs n-1 loops.
    loops: u32 = 0,
};

pub const ComposeFrames = struct {
    identifiers: Identifiers,
    destination_frame: u32,
    source_frame: u32,
    destination_x_pixels: u32 = 0,
    destination_y_pixels: u32 = 0,
    width_pixels: u32 = 0,
    height_pixels: u32 = 0,
    source_x_pixels: u32 = 0,
    source_y_pixels: u32 = 0,
    composition: CompositionMode = .alpha_blend,
};

pub const Command = union(enum) {
    transmit: Transmit,
    transmit_and_display: TransmitAndDisplay,
    display: Display,
    query: Query,
    delete: Delete,
    animation_frame: AnimationFrame,
    animation_control: AnimationControl,
    compose_frames: ComposeFrames,

    pub fn transmission(self: Command) ?Transmission {
        return switch (self) {
            .transmit => |value| value.transmission,
            .transmit_and_display => |value| value.transmission,
            .query => |value| value.transmission,
            .animation_frame => |value| value.transmission,
            else => null,
        };
    }
};

pub const EncodeContext = struct {
    first_chunk: bool = true,
    more_chunks: bool = false,
    response: ResponseMode = .all,
};

pub const EncodeError = error{ BufferTooSmall, InvalidCommand };

/// Checks field combinations that are invalid independently of payload bytes.
pub fn validate(command: Command) error{InvalidCommand}!void {
    switch (command) {
        .transmit => |value| try validateIdentifiers(value.transmission.identifiers, false),
        .transmit_and_display => |value| {
            try validateIdentifiers(value.transmission.identifiers, false);
            try validatePlacement(value.placement);
        },
        .display => |value| {
            try validateIdentifiers(value.identifiers, true);
            try validatePlacement(value.placement);
        },
        .query => |value| try validateIdentifiers(value.transmission.identifiers, false),
        .delete => |value| try validateDelete(value.selector),
        .animation_frame => |value| try validateIdentifiers(value.transmission.identifiers, true),
        .animation_control => |value| try validateIdentifiers(value.identifiers, true),
        .compose_frames => |value| {
            try validateIdentifiers(value.identifiers, true);
            if (value.destination_frame == 0 or value.source_frame == 0) return error.InvalidCommand;
        },
    }
}

fn validateIdentifiers(value: Identifiers, required: bool) error{InvalidCommand}!void {
    if (value.image_id != 0 and value.image_number != 0) return error.InvalidCommand;
    if (required and value.image_id == 0 and value.image_number == 0) return error.InvalidCommand;
}

fn validatePlacement(value: Placement) error{InvalidCommand}!void {
    const has_parent = value.parent_image_id != 0 or value.parent_placement_id != 0;
    if (value.virtual and has_parent) return error.InvalidCommand;
    if ((value.parent_image_id == 0) != (value.parent_placement_id == 0)) return error.InvalidCommand;
    if (!has_parent and (value.parent_x_cells != 0 or value.parent_y_cells != 0)) return error.InvalidCommand;
}

fn validateDelete(selector: DeleteSelector) error{InvalidCommand}!void {
    switch (selector) {
        .all, .cursor, .z_order => {},
        .image_id => |value| if (value.image_id == 0) return error.InvalidCommand,
        .image_number => |value| if (value.image_number == 0) return error.InvalidCommand,
        .animation_frames => |value| {
            try validateIdentifiers(.{ .image_id = value.image_id, .image_number = value.image_number }, true);
        },
        .cell => |value| if (value.x == 0 or value.y == 0) return error.InvalidCommand,
        .cell_z => |value| if (value.x == 0 or value.y == 0) return error.InvalidCommand,
        .id_range => |value| if (value.first == 0 or value.first > value.last) return error.InvalidCommand,
        .column => |value| if (value.x == 0) return error.InvalidCommand,
        .row => |value| if (value.y == 0) return error.InvalidCommand,
    }
}

/// Encodes only APC control data. Payload framing and base64 belong to Sender.
pub fn encodeControl(output: []u8, command: Command, context: EncodeContext) EncodeError![]const u8 {
    try validate(command);
    if (context.more_chunks) {
        const tx = command.transmission() orelse return error.InvalidCommand;
        if (tx.medium != .direct) return error.InvalidCommand;
    }
    var builder = Builder{ .buffer = output };
    if (!context.first_chunk) {
        const tx = command.transmission() orelse return error.InvalidCommand;
        if (tx.medium != .direct) return error.InvalidCommand;
        if (command == .animation_frame) try builder.action('f');
        try builder.fieldUnsigned('m', @intFromBool(context.more_chunks));
        if (context.response != .all) try builder.fieldUnsigned('q', @intFromEnum(context.response));
        return builder.written();
    }

    switch (command) {
        .transmit => |value| {
            try builder.action('t');
            try builder.transmission(value.transmission, context.more_chunks);
        },
        .transmit_and_display => |value| {
            try builder.action('T');
            try builder.transmission(value.transmission, context.more_chunks);
            try builder.placement(value.placement);
        },
        .display => |value| {
            try builder.action('p');
            try builder.identifiers(value.identifiers);
            try builder.placement(value.placement);
        },
        .query => |value| {
            try builder.action('q');
            try builder.transmission(value.transmission, context.more_chunks);
        },
        .delete => |value| {
            try builder.action('d');
            try builder.delete(value.selector);
        },
        .animation_frame => |value| {
            try builder.action('f');
            try builder.transmission(value.transmission, context.more_chunks);
            try builder.optionalUnsigned('x', value.destination_x_pixels);
            try builder.optionalUnsigned('y', value.destination_y_pixels);
            try builder.optionalUnsigned('c', value.base_frame);
            try builder.optionalUnsigned('r', value.edit_frame);
            try builder.optionalSigned('z', value.gap_ms);
            try builder.fieldUnsigned('X', @intFromEnum(value.composition));
            try builder.optionalUnsigned('Y', value.background_rgba);
        },
        .animation_control => |value| {
            try builder.action('a');
            try builder.identifiers(value.identifiers);
            if (value.state) |state| try builder.fieldUnsigned('s', @intFromEnum(state));
            try builder.optionalUnsigned('r', value.frame);
            try builder.optionalSigned('z', value.gap_ms);
            try builder.optionalUnsigned('c', value.current_frame);
            try builder.optionalUnsigned('v', value.loops);
        },
        .compose_frames => |value| {
            try builder.action('c');
            try builder.identifiers(value.identifiers);
            try builder.fieldUnsigned('c', value.destination_frame);
            try builder.fieldUnsigned('r', value.source_frame);
            try builder.optionalUnsigned('x', value.destination_x_pixels);
            try builder.optionalUnsigned('y', value.destination_y_pixels);
            try builder.optionalUnsigned('w', value.width_pixels);
            try builder.optionalUnsigned('h', value.height_pixels);
            try builder.optionalUnsigned('X', value.source_x_pixels);
            try builder.optionalUnsigned('Y', value.source_y_pixels);
            try builder.fieldUnsigned('C', @intFromEnum(value.composition));
        },
    }
    if (context.response != .all) try builder.fieldUnsigned('q', @intFromEnum(context.response));
    return builder.written();
}

const Builder = struct {
    buffer: []u8,
    len: usize = 0,
    fields: usize = 0,

    fn written(self: *const Builder) []const u8 {
        return self.buffer[0..self.len];
    }

    fn append(self: *Builder, bytes: []const u8) EncodeError!void {
        if (bytes.len > self.buffer.len - self.len) return error.BufferTooSmall;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn fieldPrefix(self: *Builder, key: u8) EncodeError!void {
        if (self.fields != 0) try self.append(",");
        try self.append(&.{ key, '=' });
        self.fields += 1;
    }

    fn fieldUnsigned(self: *Builder, key: u8, value: anytype) EncodeError!void {
        try self.fieldPrefix(key);
        var storage: [20]u8 = undefined;
        const bytes = std.fmt.bufPrint(&storage, "{d}", .{value}) catch return error.BufferTooSmall;
        try self.append(bytes);
    }

    fn fieldSigned(self: *Builder, key: u8, value: i32) EncodeError!void {
        try self.fieldPrefix(key);
        var storage: [16]u8 = undefined;
        const bytes = std.fmt.bufPrint(&storage, "{d}", .{value}) catch return error.BufferTooSmall;
        try self.append(bytes);
    }

    fn fieldChar(self: *Builder, key: u8, value: u8) EncodeError!void {
        try self.fieldPrefix(key);
        try self.append(&.{value});
    }

    fn optionalUnsigned(self: *Builder, key: u8, value: u32) EncodeError!void {
        if (value != 0) try self.fieldUnsigned(key, value);
    }

    fn optionalSigned(self: *Builder, key: u8, value: i32) EncodeError!void {
        if (value != 0) try self.fieldSigned(key, value);
    }

    fn action(self: *Builder, value: u8) EncodeError!void {
        try self.fieldChar('a', value);
    }

    fn identifiers(self: *Builder, value: Identifiers) EncodeError!void {
        try self.optionalUnsigned('i', value.image_id);
        try self.optionalUnsigned('I', value.image_number);
        try self.optionalUnsigned('p', value.placement_id);
    }

    fn transmission(self: *Builder, value: Transmission, more_chunks: bool) EncodeError!void {
        try self.fieldUnsigned('f', @intFromEnum(value.format));
        try self.fieldChar('t', @intFromEnum(value.medium));
        try self.optionalUnsigned('s', value.width_pixels);
        try self.optionalUnsigned('v', value.height_pixels);
        try self.optionalUnsigned('S', value.data_size_bytes);
        try self.optionalUnsigned('O', value.data_offset_bytes);
        try self.identifiers(value.identifiers);
        if (value.compression == .zlib) try self.fieldChar('o', 'z');
        if (more_chunks) try self.fieldUnsigned('m', 1);
        if (value.transient) try self.fieldUnsigned('N', 1);
    }

    fn placement(self: *Builder, value: Placement) EncodeError!void {
        try self.optionalUnsigned('x', value.source_x_pixels);
        try self.optionalUnsigned('y', value.source_y_pixels);
        try self.optionalUnsigned('w', value.source_width_pixels);
        try self.optionalUnsigned('h', value.source_height_pixels);
        try self.optionalUnsigned('X', value.cell_x_offset_pixels);
        try self.optionalUnsigned('Y', value.cell_y_offset_pixels);
        try self.optionalUnsigned('c', value.columns);
        try self.optionalUnsigned('r', value.rows);
        try self.optionalSigned('z', value.z_order);
        if (value.cursor == .preserve) try self.fieldUnsigned('C', 1);
        if (value.virtual) try self.fieldUnsigned('U', 1);
        try self.optionalUnsigned('P', value.parent_image_id);
        try self.optionalUnsigned('Q', value.parent_placement_id);
        try self.optionalSigned('H', value.parent_x_cells);
        try self.optionalSigned('V', value.parent_y_cells);
    }

    fn delete(self: *Builder, selector: DeleteSelector) EncodeError!void {
        switch (selector) {
            .all => |free| try self.fieldChar('d', if (free) 'A' else 'a'),
            .image_id => |value| {
                try self.fieldChar('d', if (value.free_data) 'I' else 'i');
                try self.fieldUnsigned('i', value.image_id);
                try self.optionalUnsigned('p', value.placement_id);
            },
            .image_number => |value| {
                try self.fieldChar('d', if (value.free_data) 'N' else 'n');
                try self.fieldUnsigned('I', value.image_number);
                try self.optionalUnsigned('p', value.placement_id);
            },
            .cursor => |free| try self.fieldChar('d', if (free) 'C' else 'c'),
            .animation_frames => |value| {
                try self.fieldChar('d', if (value.free_data) 'F' else 'f');
                try self.optionalUnsigned('i', value.image_id);
                try self.optionalUnsigned('I', value.image_number);
                try self.optionalUnsigned('r', value.frame);
            },
            .cell => |value| {
                try self.fieldChar('d', if (value.free_data) 'P' else 'p');
                try self.fieldUnsigned('x', value.x);
                try self.fieldUnsigned('y', value.y);
            },
            .cell_z => |value| {
                try self.fieldChar('d', if (value.free_data) 'Q' else 'q');
                try self.fieldUnsigned('x', value.x);
                try self.fieldUnsigned('y', value.y);
                try self.fieldSigned('z', value.z_order);
            },
            .id_range => |value| {
                try self.fieldChar('d', if (value.free_data) 'R' else 'r');
                try self.fieldUnsigned('x', value.first);
                try self.fieldUnsigned('y', value.last);
            },
            .column => |value| {
                try self.fieldChar('d', if (value.free_data) 'X' else 'x');
                try self.fieldUnsigned('x', value.x);
            },
            .row => |value| {
                try self.fieldChar('d', if (value.free_data) 'Y' else 'y');
                try self.fieldUnsigned('y', value.y);
            },
            .z_order => |value| {
                try self.fieldChar('d', if (value.free_data) 'Z' else 'z');
                try self.fieldSigned('z', value.z_order);
            },
        }
    }
};

pub const Reply = struct {
    pub const max_unknown_fields = 8;

    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    frame: u32 = 0,
    unknown_fields: [max_unknown_fields]UnknownField = undefined,
    unknown_field_count: u4 = 0,
    /// Borrows the terminal-reply input storage.
    message: []const u8,
    status: Status,

    pub const UnknownField = struct {
        key: u8,
        value: []const u8,
    };

    pub const Status = union(enum) {
        ok,
        remote_error: RemoteError,
    };

    pub const RemoteError = struct {
        /// Both slices borrow the terminal-reply input storage.
        code: []const u8,
        message: []const u8,
    };

    pub fn unknownFields(self: *const Reply) []const UnknownField {
        return self.unknown_fields[0..self.unknown_field_count];
    }

    pub fn parse(value: input.TerminalReply) !Reply {
        if (value.kind != .apc or value.final != '\\' or value.raw.len < 3 or value.raw[0] != 'G') {
            return error.NotGraphicsReply;
        }
        const separator = std.mem.indexOfScalar(u8, value.raw, ';') orelse return error.MalformedReply;
        if (separator + 1 >= value.raw.len) return error.MalformedReply;
        var result = Reply{
            .message = value.raw[separator + 1 ..],
            .status = undefined,
        };
        var seen: u4 = 0;
        var fields = std.mem.splitScalar(u8, value.raw[1..separator], ',');
        while (fields.next()) |field| {
            const equal = std.mem.indexOfScalar(u8, field, '=') orelse return error.MalformedReply;
            if (equal != 1 or field.len == 2) return error.MalformedReply;
            const target: ?struct { u4, *u32 } = switch (field[0]) {
                'i' => .{ 1, &result.image_id },
                'I' => .{ 2, &result.image_number },
                'p' => .{ 4, &result.placement_id },
                'r' => .{ 8, &result.frame },
                else => null,
            };
            if (target == null) {
                if (result.unknown_field_count == max_unknown_fields) return error.TooManyUnknownFields;
                result.unknown_fields[result.unknown_field_count] = .{
                    .key = field[0],
                    .value = field[2..],
                };
                result.unknown_field_count += 1;
                continue;
            }
            const parsed = std.fmt.parseInt(u32, field[2..], 10) catch return error.MalformedReply;
            const bit = target.?.@"0";
            const destination = target.?.@"1";
            if (seen & bit != 0 and destination.* != parsed) return error.ConflictingField;
            seen |= bit;
            destination.* = parsed;
        }
        for (result.message) |byte| if (byte < 0x20 or byte > 0x7e) return error.MalformedReply;
        if (std.mem.eql(u8, result.message, "OK")) {
            result.status = .ok;
        } else {
            const colon = std.mem.indexOfScalar(u8, result.message, ':') orelse result.message.len;
            if (colon == 0) return error.MalformedReply;
            result.status = .{ .remote_error = .{
                .code = result.message[0..colon],
                .message = result.message,
            } };
        }
        return result;
    }
};
