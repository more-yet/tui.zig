const std = @import("std");
const builtin = @import("builtin");
const tui = @import("tui");

const ok: i32 = 0;
const invalid_argument: i32 = -1;
const out_of_memory: i32 = -2;
const capacity_error: i32 = -3;
const invalid_text: i32 = -4;
const buffer_too_small: i32 = -5;
const queue_full: i32 = -6;
const queue_empty: i32 = -7;
const output_error: i32 = -8;
const invalid_state: i32 = -10;
const event_payload_capacity = 256;
const provider_batch_capacity = 64;

const CAllocateFn = *const fn (?*anyopaque, u64, u64) callconv(.c) ?*anyopaque;
const CDeallocateFn = *const fn (?*anyopaque, ?*anyopaque, u64, u64) callconv(.c) void;
pub const CAllocator = extern struct {
    context: ?*anyopaque,
    allocate: ?CAllocateFn,
    deallocate: ?CDeallocateFn,
};

pub const tui_renderer_v1 = opaque {};
pub const tui_text_input_v1 = opaque {};
pub const tui_text_area_v1 = opaque {};
pub const tui_line_chart_v1 = opaque {};
pub const tui_event_queue_v1 = opaque {};
pub const tui_parser_v1 = opaque {};

pub const CVersion = extern struct { major: u32, minor: u32, patch: u32 };
pub const CBytes = extern struct { ptr: [*c]const u8, len: u64 };
pub const CSize = extern struct { width: u16, height: u16 };
const CSizeArgument = if (builtin.cpu.arch == .aarch64) u32 else CSize;
pub const CPoint = extern struct { x: u16, y: u16 };
pub const CRect = extern struct { x: u16, y: u16, width: u16, height: u16 };
pub const CColor = extern struct {
    kind: i32,
    index: u8,
    red: u8,
    green: u8,
    blue: u8,
    reserved: [3]u8,
};
pub const CStyle = extern struct {
    foreground: CColor,
    background: CColor,
    attributes: u8,
    reserved: [3]u8,
};
pub const CRole = extern struct {
    normal: CStyle,
    focused: CStyle,
    disabled: CStyle,
    has_focused: u8,
    has_disabled: u8,
    reserved: [2]u8,
};
pub const CEvent = extern struct {
    kind: i32,
    key_kind: i32,
    key_value: u32,
    modifiers: u8,
    key_action: u8,
    mouse_button: u8,
    mouse_action: u8,
    x: u16,
    y: u16,
    reply_kind: i32,
    reply_final: u8,
    reserved: [3]u8,
    payload: CBytes,
};
pub const CRendererConfig = extern struct {
    max_cells: u64,
    grapheme_capacity: u32,
    style_capacity: u16,
    image_capacity: u16,
    tile_width: u8,
    tile_height: u8,
    reserved: [6]u8,
};
pub const CCapabilities = extern struct {
    color_depth: i32,
    image_protocol: i32,
    synchronized_output: u8,
    background_color_erase: u8,
    reserved: [6]u8,
};
pub const CFrameStats = extern struct {
    bytes: u64,
    cells_compared: u32,
    cells_changed: u32,
    runs: u32,
    dirty_rows: u16,
    full_repaint: u8,
    reserved: u8,
};
const CWriteFn = *const fn (?*anyopaque, [*c]const u8, u64) callconv(.c) i32;
pub const COutput = extern struct { context: ?*anyopaque, write: ?CWriteFn };
pub const CImage = extern struct { pixels: CBytes, width: u32, height: u32, format: i32 };
pub const CImageOptions = extern struct {
    image_id: u32,
    placement_id: u32,
    background_red: u8,
    background_green: u8,
    background_blue: u8,
    reserved: u8,
};
pub const CTextDesc = extern struct {
    text: CBytes,
    role: CRole,
    enabled: u8,
    focused: u8,
    width_profile: u8,
    alignment: u8,
};
pub const CPanelDesc = extern struct {
    title: CBytes,
    border_role: CRole,
    title_role: CRole,
    enabled: u8,
    focused: u8,
    reserved: [2]u8,
};
pub const CGaugeDesc = extern struct {
    value: u64,
    total: u64,
    filled_role: CRole,
    empty_role: CRole,
    enabled: u8,
    reserved: [7]u8,
};
pub const CButtonState = extern struct { activated: u8, reserved: [7]u8 };
pub const CCheckboxState = extern struct { checked: u8, reserved: [7]u8 };
pub const CRadioState = extern struct { selected: u32, has_selected: u8, reserved: [3]u8 };
pub const CControlDesc = extern struct {
    label: CBytes,
    role: CRole,
    indicator_role: CRole,
    enabled: u8,
    focused: u8,
    reserved: [2]u8,
};
pub const CScrollState = extern struct {
    top: u64,
    selected: u64,
    has_selected: u8,
    reserved: [7]u8,
};
pub const CProviderRow = extern struct {
    text: CBytes,
    cells: [*c]const CBytes,
    cell_count: u32,
    depth: u32,
    status: i32,
    flags: u32,
};
const CRowsReadFn = *const fn (?*anyopaque, u64, u32, [*c]CProviderRow) callconv(.c) i32;
pub const CRowsProvider = extern struct { context: ?*anyopaque, count: u64, read: ?CRowsReadFn };
pub const CColumn = extern struct { title: CBytes, width: u16, reserved: u16 };
pub const CCollectionDesc = extern struct {
    row_role: CRole,
    selected_role: CRole,
    header_role: CRole,
    enabled: u8,
    focused: u8,
    width_profile: u8,
    reserved: u8,
};
pub const CMenuState = extern struct {
    scroll: CScrollState,
    activated: u64,
    has_activated: u8,
    reserved: [7]u8,
};
pub const CTreeState = extern struct {
    scroll: CScrollState,
    toggled: u64,
    activated: u64,
    has_toggled: u8,
    has_activated: u8,
    reserved: [6]u8,
};
const CSamplesReadFn = *const fn (?*anyopaque, u64, u32, [*c]f64) callconv(.c) i32;
pub const CSamplesProvider = extern struct { context: ?*anyopaque, count: u64, read: ?CSamplesReadFn };

const AllocatorBridge = struct {
    callbacks: CAllocator,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocate,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = deallocate,
    };

    fn init(value: ?*const CAllocator) ?AllocatorBridge {
        const callbacks = (value orelse return null).*;
        if (callbacks.allocate == null or callbacks.deallocate == null) return null;
        return .{ .callbacks = callbacks };
    }

    fn allocator(self: *AllocatorBridge) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn create(self: AllocatorBridge, comptime T: type) ?*T {
        const pointer = self.allocateBytes(@sizeOf(T), @alignOf(T)) orelse return null;
        return @ptrCast(@alignCast(pointer));
    }

    fn destroy(self: AllocatorBridge, pointer: anytype) void {
        const T = @typeInfo(@TypeOf(pointer)).pointer.child;
        self.callbacks.deallocate.?(
            self.callbacks.context,
            @ptrCast(pointer),
            @sizeOf(T),
            @alignOf(T),
        );
    }

    fn allocate(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        _ = return_address;
        const self: *AllocatorBridge = @ptrCast(@alignCast(context));
        const pointer = self.allocateBytes(len, alignment.toByteUnits()) orelse return null;
        return @ptrCast(pointer);
    }

    fn deallocate(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        _ = return_address;
        const self: *AllocatorBridge = @ptrCast(@alignCast(context));
        self.callbacks.deallocate.?(
            self.callbacks.context,
            @ptrCast(memory.ptr),
            memory.len,
            alignment.toByteUnits(),
        );
    }

    fn allocateBytes(self: AllocatorBridge, len: usize, alignment: usize) ?*anyopaque {
        const pointer = self.callbacks.allocate.?(self.callbacks.context, len, alignment) orelse return null;
        if (@intFromPtr(pointer) % alignment == 0) return pointer;
        self.callbacks.deallocate.?(self.callbacks.context, pointer, len, alignment);
        return null;
    }
};

const AllocatorError = error{ InvalidAllocator, OutOfMemory };

fn createHandle(comptime T: type, allocator_value: ?*const CAllocator) AllocatorError!*T {
    const bridge = AllocatorBridge.init(allocator_value) orelse return error.InvalidAllocator;
    const handle = bridge.create(T) orelse return error.OutOfMemory;
    handle.allocator = bridge;
    return handle;
}

fn allocatorResult(err: AllocatorError) i32 {
    return switch (err) {
        error.InvalidAllocator => invalid_argument,
        error.OutOfMemory => out_of_memory,
    };
}

fn destroyHandle(handle: anytype) void {
    const allocator = handle.allocator;
    allocator.destroy(handle);
}

const RendererHandle = struct {
    allocator: AllocatorBridge,
    renderer: tui.render.Renderer,
    frame_active: bool = false,
};
const TextInputHandle = struct {
    allocator: AllocatorBridge,
    storage: []u8,
    input: tui.widget.TextInput,
};
const TextAreaHandle = struct {
    allocator: AllocatorBridge,
    storage: []u8,
    model: tui.editor.Model,
    area: tui.widget.TextArea,
};
const SampleProvider = struct {
    values: []const f64,
    pub fn count(self: *@This()) usize {
        return self.values.len;
    }
    pub fn sample(self: *@This(), index: usize) f64 {
        return self.values[index];
    }
};
const LineChartHandle = struct {
    allocator: AllocatorBridge,
    samples: []f64,
    masks: []u8,
    canvas: tui.render.BrailleCanvas,
};

const QueueSlot = struct {
    event: CEvent,
    payload_len: u16,
    payload: [event_payload_capacity]u8,
};
const EventQueueHandle = struct {
    allocator: AllocatorBridge,
    slots: []QueueSlot,
    produced: std.atomic.Value(usize) = .init(0),
    consumed: std.atomic.Value(usize) = .init(0),
};
const ParserHandle = struct {
    allocator: AllocatorBridge,
    parser: tui.input.Parser = .{},
};

fn rendererHandle(value: *tui_renderer_v1) *RendererHandle {
    return @ptrCast(@alignCast(value));
}
fn textInputHandle(value: *tui_text_input_v1) *TextInputHandle {
    return @ptrCast(@alignCast(value));
}
fn textAreaHandle(value: *tui_text_area_v1) *TextAreaHandle {
    return @ptrCast(@alignCast(value));
}
fn lineChartHandle(value: *tui_line_chart_v1) *LineChartHandle {
    return @ptrCast(@alignCast(value));
}
fn eventQueueHandle(value: *tui_event_queue_v1) *EventQueueHandle {
    return @ptrCast(@alignCast(value));
}
fn parserHandle(value: *tui_parser_v1) *ParserHandle {
    return @ptrCast(@alignCast(value));
}

fn bytes(value: CBytes) ![]const u8 {
    const len = std.math.cast(usize, value.len) orelse return error.InvalidArgument;
    if (len == 0) return "";
    if (value.ptr == null) return error.InvalidArgument;
    return value.ptr[0..len];
}

fn mutableBytes(pointer: [*c]u8, len: usize) ![]u8 {
    if (len == 0) return &.{};
    if (pointer == null) return error.InvalidArgument;
    return pointer[0..len];
}

fn toRect(value: CRect) tui.render.Rect {
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}

fn toColor(value: CColor) !tui.render.Color {
    return switch (value.kind) {
        0 => .default,
        1 => .{ .indexed = value.index },
        2 => .{ .rgb = .{ .r = value.red, .g = value.green, .b = value.blue } },
        else => error.InvalidArgument,
    };
}

fn toStyle(value: CStyle) !tui.render.Style {
    return .{
        .foreground = try toColor(value.foreground),
        .background = try toColor(value.background),
        .attributes = @bitCast(value.attributes),
    };
}

fn toRole(value: CRole) !tui.theme.Role {
    return .{
        .normal = try toStyle(value.normal),
        .focused = if (value.has_focused != 0) try toStyle(value.focused) else null,
        .disabled = if (value.has_disabled != 0) try toStyle(value.disabled) else null,
    };
}

fn toWidth(value: u8) !tui.text.WidthProfile {
    return switch (value) {
        0 => .narrow,
        1 => .wide_ambiguous,
        else => error.InvalidArgument,
    };
}

fn toAlignment(value: u8) !tui.text.TextAlignment {
    return switch (value) {
        0 => .left,
        1 => .center,
        2 => .right,
        else => error.InvalidArgument,
    };
}

fn themeState(enabled: u8, focused: u8) tui.theme.State {
    return tui.theme.State.from(enabled != 0, focused != 0);
}

fn sizeArgument(value: CSizeArgument) CSize {
    // Zig 0.16 mislowers four-byte extern struct arguments on AArch64.
    return if (comptime builtin.cpu.arch == .aarch64) @bitCast(value) else value;
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => out_of_memory,
        error.BufferTooSmall, error.OutputStorageTooSmall => buffer_too_small,
        error.CapacityExceeded, error.HistoryCapacityExceeded, error.ImageCapacityExceeded, error.SizeLimitExceeded => capacity_error,
        error.InvalidUtf8, error.InvalidText, error.ControlCharacter, error.ZeroWidthGrapheme, error.GraphemeTooLong => invalid_text,
        error.WriteFailed => output_error,
        else => invalid_argument,
    };
}

fn updateValue(value: tui.widget.Update) i32 {
    return @intFromEnum(value);
}

fn toEvent(value: CEvent) !tui.input.Event {
    return switch (value.kind) {
        1 => .{ .key = .{
            .code = switch (value.key_kind) {
                0 => .{ .codepoint = std.math.cast(u21, value.key_value) orelse return error.InvalidArgument },
                1 => .{ .functional = std.math.cast(u21, value.key_value) orelse return error.InvalidArgument },
                2 => .escape,
                3 => .enter,
                4 => .tab,
                5 => .backspace,
                6 => .up,
                7 => .down,
                8 => .left,
                9 => .right,
                10 => .home,
                11 => .end,
                12 => .insert,
                13 => .delete,
                14 => .page_up,
                15 => .page_down,
                16 => .{ .function = std.math.cast(u8, value.key_value) orelse return error.InvalidArgument },
                else => return error.InvalidArgument,
            },
            .modifiers = @bitCast(value.modifiers),
            .action = switch (value.key_action) {
                0 => .press,
                1 => .repeat,
                2 => .release,
                else => return error.InvalidArgument,
            },
        } },
        2 => .{ .text = try bytes(value.payload) },
        3 => .{ .mouse = .{
            .x = value.x,
            .y = value.y,
            .button = switch (value.mouse_button) {
                0 => .none,
                1 => .left,
                2 => .middle,
                3 => .right,
                else => return error.InvalidArgument,
            },
            .action = switch (value.mouse_action) {
                0 => .press,
                1 => .release,
                2 => .move,
                3 => .scroll_up,
                4 => .scroll_down,
                5 => .scroll_left,
                6 => .scroll_right,
                else => return error.InvalidArgument,
            },
            .modifiers = @bitCast(value.modifiers),
        } },
        4 => .paste_start,
        5 => .{ .paste_chunk = try bytes(value.payload) },
        6 => .paste_end,
        7 => .focus_in,
        8 => .focus_out,
        9 => .{ .cursor_position = .{ .row = value.y, .column = value.x } },
        10 => .{ .terminal_reply = .{
            .kind = switch (value.reply_kind) {
                0 => .csi,
                1 => .osc,
                2 => .apc,
                else => return error.InvalidArgument,
            },
            .final = value.reply_final,
            .raw = try bytes(value.payload),
        } },
        11 => .malformed,
        else => return error.InvalidArgument,
    };
}

fn fromEvent(value: tui.input.Event) CEvent {
    var result: CEvent = std.mem.zeroes(CEvent);
    switch (value) {
        .key => |key| {
            result.kind = 1;
            result.modifiers = @bitCast(key.modifiers);
            result.key_action = @intFromEnum(key.action);
            switch (key.code) {
                .codepoint => |codepoint| {
                    result.key_kind = 0;
                    result.key_value = codepoint;
                },
                .functional => |functional| {
                    result.key_kind = 1;
                    result.key_value = functional;
                },
                .function => |number| {
                    result.key_kind = 16;
                    result.key_value = number;
                },
                else => result.key_kind = switch (key.code) {
                    .escape => 2,
                    .enter => 3,
                    .tab => 4,
                    .backspace => 5,
                    .up => 6,
                    .down => 7,
                    .left => 8,
                    .right => 9,
                    .home => 10,
                    .end => 11,
                    .insert => 12,
                    .delete => 13,
                    .page_up => 14,
                    .page_down => 15,
                    else => unreachable,
                },
            }
        },
        .text => |payload| {
            result.kind = 2;
            result.payload = .{ .ptr = payload.ptr, .len = payload.len };
        },
        .mouse => |mouse| {
            result.kind = 3;
            result.x = mouse.x;
            result.y = mouse.y;
            result.mouse_button = @intFromEnum(mouse.button);
            result.mouse_action = @intFromEnum(mouse.action);
            result.modifiers = @bitCast(mouse.modifiers);
        },
        .paste_start => result.kind = 4,
        .paste_chunk => |payload| {
            result.kind = 5;
            result.payload = .{ .ptr = payload.ptr, .len = payload.len };
        },
        .paste_end => result.kind = 6,
        .focus_in => result.kind = 7,
        .focus_out => result.kind = 8,
        .cursor_position => |position| {
            result.kind = 9;
            result.x = position.column;
            result.y = position.row;
        },
        .terminal_reply => |reply| {
            result.kind = 10;
            result.reply_kind = @intFromEnum(reply.kind);
            result.reply_final = reply.final;
            result.payload = .{ .ptr = reply.raw.ptr, .len = reply.raw.len };
        },
        .malformed => result.kind = 11,
    }
    return result;
}

fn surfaceFor(handle: *RendererHandle, bounds: CRect) !tui.render.Surface {
    if (!handle.frame_active) return error.InvalidState;
    const rect = toRect(bounds);
    if (rect.right() > handle.renderer.size().width or rect.bottom() > handle.renderer.size().height) return error.InvalidArgument;
    var frame = tui.render.Frame{ .renderer = &handle.renderer };
    return frame.surface(rect);
}

const CallbackWriter = struct {
    output: COutput,
    callback_result: i32 = 0,
    writer: std.Io.Writer,

    fn init(output: COutput) CallbackWriter {
        return .{
            .output = output,
            .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CallbackWriter = @alignCast(@fieldParentPtr("writer", writer));
        const callback = self.output.write orelse return error.WriteFailed;
        for (data[0 .. data.len - 1]) |part| try self.send(callback, part);
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.send(callback, pattern);
        return std.Io.Writer.countSplat(data, splat);
    }

    fn send(self: *CallbackWriter, callback: CWriteFn, value: []const u8) std.Io.Writer.Error!void {
        if (value.len == 0) return;
        const result = callback(self.output.context, value.ptr, value.len);
        if (result != 0) {
            self.callback_result = result;
            return error.WriteFailed;
        }
    }
};

pub export fn tui_abi_version_v1() callconv(.c) CVersion {
    return .{ .major = 1, .minor = 0, .patch = 0 };
}

pub export fn tui_renderer_create_v1(allocator_value: ?*const CAllocator, size_value: CSizeArgument, config: ?*const CRendererConfig, out: ?*?*tui_renderer_v1) callconv(.c) i32 {
    const output = out orelse return invalid_argument;
    output.* = null;
    const size = sizeArgument(size_value);
    const limits: tui.render.Limits = if (config) |value| .{
        .max_cells = std.math.cast(usize, value.max_cells) orelse return invalid_argument,
        .grapheme_capacity = value.grapheme_capacity,
        .style_capacity = value.style_capacity,
        .image_capacity = value.image_capacity,
        .tile_width = value.tile_width,
        .tile_height = value.tile_height,
    } else .{};
    const handle = createHandle(RendererHandle, allocator_value) catch |err| return allocatorResult(err);
    handle.renderer = tui.render.Renderer.init(handle.allocator.allocator(), .{ .width = size.width, .height = size.height }, limits) catch |err| {
        destroyHandle(handle);
        return mapError(err);
    };
    handle.frame_active = false;
    output.* = @ptrCast(handle);
    return ok;
}

pub export fn tui_renderer_destroy_v1(value: ?*tui_renderer_v1) callconv(.c) void {
    const pointer = value orelse return;
    const handle = rendererHandle(pointer);
    handle.renderer.deinit();
    destroyHandle(handle);
}

pub export fn tui_renderer_resize_v1(value: ?*tui_renderer_v1, size_value: CSizeArgument) callconv(.c) i32 {
    const handle = rendererHandle(value orelse return invalid_argument);
    const size = sizeArgument(size_value);
    handle.renderer.resize(.{ .width = size.width, .height = size.height }) catch |err| return mapError(err);
    handle.frame_active = false;
    return ok;
}

pub export fn tui_renderer_begin_frame_v1(value: ?*tui_renderer_v1) callconv(.c) i32 {
    const handle = rendererHandle(value orelse return invalid_argument);
    _ = handle.renderer.frame();
    handle.frame_active = true;
    return ok;
}

pub export fn tui_renderer_invalidate_terminal_v1(value: ?*tui_renderer_v1) callconv(.c) void {
    rendererHandle(value orelse return).renderer.invalidateTerminal();
}

pub export fn tui_renderer_put_image_v1(
    value: ?*tui_renderer_v1,
    bounds: CRect,
    image: CImage,
    options: CImageOptions,
) callconv(.c) i32 {
    const handle = rendererHandle(value orelse return invalid_argument);
    if (!handle.frame_active) return invalid_state;
    const pixels = bytes(image.pixels) catch return invalid_argument;
    const format: tui.terminal.ImagePixelFormat = switch (image.format) {
        0 => .rgb8,
        1 => .rgba8,
        else => return invalid_argument,
    };
    var frame = tui.render.Frame{ .renderer = &handle.renderer };
    frame.putImage(toRect(bounds), .{
        .pixels = pixels,
        .width = image.width,
        .height = image.height,
        .format = format,
    }, .{
        .image_id = options.image_id,
        .placement_id = options.placement_id,
        .background = .{ .red = options.background_red, .green = options.background_green, .blue = options.background_blue },
    }) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_renderer_present_v1(
    value: ?*tui_renderer_v1,
    capability_value: CCapabilities,
    output: COutput,
    stats_out: ?*CFrameStats,
) callconv(.c) i32 {
    const handle = rendererHandle(value orelse return invalid_argument);
    if (!handle.frame_active or output.write == null) return invalid_state;
    const capabilities = toCapabilities(capability_value) catch return invalid_argument;
    var callback_writer = CallbackWriter.init(output);
    const stats = handle.renderer.present(&callback_writer.writer, capabilities) catch {
        return if (callback_writer.callback_result != 0) callback_writer.callback_result else output_error;
    };
    if (stats_out) |target| target.* = .{
        .bytes = stats.bytes,
        .cells_compared = stats.cells_compared,
        .cells_changed = stats.cells_changed,
        .runs = stats.runs,
        .dirty_rows = stats.dirty_rows,
        .full_repaint = @intFromBool(stats.full_repaint),
        .reserved = 0,
    };
    handle.frame_active = false;
    return ok;
}

fn toCapabilities(value: CCapabilities) !tui.terminal.Capabilities {
    return .{
        .color_depth = switch (value.color_depth) {
            0 => .ansi16,
            1 => .indexed256,
            2 => .truecolor,
            else => return error.InvalidArgument,
        },
        .synchronized_output = value.synchronized_output != 0,
        .background_color_erase = value.background_color_erase != 0,
        .image_protocol = switch (value.image_protocol) {
            0 => .none,
            1 => .kitty,
            2 => .iterm2,
            3 => .sixel,
            else => return error.InvalidArgument,
        },
    };
}

pub export fn tui_label_draw_v1(value: ?*tui_renderer_v1, bounds: CRect, descriptor: ?*const CTextDesc) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const handle = rendererHandle(value orelse return invalid_argument);
    var surface = surfaceFor(handle, bounds) catch return invalid_state;
    const label = tui.widget.Label{
        .text = bytes(desc.text) catch return invalid_argument,
        .role = toRole(desc.role) catch return invalid_argument,
        .state = themeState(desc.enabled, desc.focused),
        .width_profile = toWidth(desc.width_profile) catch return invalid_argument,
    };
    label.draw(&surface) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_paragraph_draw_v1(value: ?*tui_renderer_v1, bounds: CRect, descriptor: ?*const CTextDesc) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const handle = rendererHandle(value orelse return invalid_argument);
    var surface = surfaceFor(handle, bounds) catch return invalid_state;
    const paragraph = tui.widget.Paragraph{
        .text = bytes(desc.text) catch return invalid_argument,
        .role = toRole(desc.role) catch return invalid_argument,
        .state = themeState(desc.enabled, desc.focused),
        .width_profile = toWidth(desc.width_profile) catch return invalid_argument,
        .alignment = toAlignment(desc.alignment) catch return invalid_argument,
    };
    paragraph.draw(&surface) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_panel_draw_v1(value: ?*tui_renderer_v1, bounds: CRect, descriptor: ?*const CPanelDesc) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const handle = rendererHandle(value orelse return invalid_argument);
    var surface = surfaceFor(handle, bounds) catch return invalid_state;
    const panel = tui.widget.Panel{
        .title = bytes(desc.title) catch return invalid_argument,
        .border = toRole(desc.border_role) catch return invalid_argument,
        .title_role = toRole(desc.title_role) catch return invalid_argument,
        .state = themeState(desc.enabled, desc.focused),
    };
    panel.draw(&surface) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_panel_content_rect_v1(bounds: CRect, output: ?*CRect) callconv(.c) i32 {
    const target = output orelse return invalid_argument;
    const content = tui.widget.Panel.contentRect(.{ .width = bounds.width, .height = bounds.height });
    target.* = .{
        .x = bounds.x +| content.x,
        .y = bounds.y +| content.y,
        .width = content.width,
        .height = content.height,
    };
    return ok;
}

pub export fn tui_gauge_draw_v1(value: ?*tui_renderer_v1, bounds: CRect, descriptor: ?*const CGaugeDesc) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const handle = rendererHandle(value orelse return invalid_argument);
    var surface = surfaceFor(handle, bounds) catch return invalid_state;
    const gauge = tui.widget.Gauge{
        .value = desc.value,
        .total = desc.total,
        .filled = toRole(desc.filled_role) catch return invalid_argument,
        .empty = toRole(desc.empty_role) catch return invalid_argument,
        .state = themeState(desc.enabled, 0),
    };
    gauge.draw(&surface) catch |err| return mapError(err);
    return ok;
}

fn controlValues(desc: *const CControlDesc) !struct {
    label: []const u8,
    role: tui.theme.Role,
    enabled: bool,
    focused: bool,
} {
    return .{
        .label = try bytes(desc.label),
        .role = try toRole(desc.role),
        .enabled = desc.enabled != 0,
        .focused = desc.focused != 0,
    };
}

pub export fn tui_button_draw_v1(
    renderer_value: ?*tui_renderer_v1,
    bounds: CRect,
    descriptor: ?*const CControlDesc,
    state: ?*CButtonState,
) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const target = state orelse return invalid_argument;
    const values = controlValues(desc) catch return invalid_argument;
    var surface = surfaceFor(rendererHandle(renderer_value orelse return invalid_argument), bounds) catch return invalid_state;
    const button = tui.widget.Button{
        .label = values.label,
        .role = values.role,
        .enabled = values.enabled,
        .focused = values.focused,
        .activated = target.activated != 0,
    };
    button.draw(&surface) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_button_handle_v1(
    descriptor: ?*const CControlDesc,
    state: ?*CButtonState,
    event_value: ?*const CEvent,
    update: ?*i32,
) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const target = state orelse return invalid_argument;
    const event = toEvent((event_value orelse return invalid_argument).*) catch return invalid_argument;
    const values = controlValues(desc) catch return invalid_argument;
    var button = tui.widget.Button{
        .label = values.label,
        .role = values.role,
        .enabled = values.enabled,
        .focused = values.focused,
        .activated = target.activated != 0,
    };
    const result = button.handle(event);
    target.activated = @intFromBool(button.activated);
    if (update) |output| output.* = updateValue(result);
    return ok;
}

pub export fn tui_checkbox_draw_v1(
    renderer_value: ?*tui_renderer_v1,
    bounds: CRect,
    descriptor: ?*const CControlDesc,
    state: ?*CCheckboxState,
) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const target = state orelse return invalid_argument;
    const values = controlValues(desc) catch return invalid_argument;
    var surface = surfaceFor(rendererHandle(renderer_value orelse return invalid_argument), bounds) catch return invalid_state;
    const checkbox = tui.widget.Checkbox{
        .label = values.label,
        .checked = target.checked != 0,
        .role = values.role,
        .enabled = values.enabled,
        .focused = values.focused,
    };
    checkbox.draw(&surface) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_checkbox_handle_v1(
    descriptor: ?*const CControlDesc,
    state: ?*CCheckboxState,
    event_value: ?*const CEvent,
    update: ?*i32,
) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const target = state orelse return invalid_argument;
    const values = controlValues(desc) catch return invalid_argument;
    var checkbox = tui.widget.Checkbox{
        .label = values.label,
        .checked = target.checked != 0,
        .role = values.role,
        .enabled = values.enabled,
        .focused = values.focused,
    };
    const result = checkbox.handle(toEvent((event_value orelse return invalid_argument).*) catch return invalid_argument);
    target.checked = @intFromBool(checkbox.checked);
    if (update) |output| output.* = updateValue(result);
    return ok;
}

pub export fn tui_radio_draw_v1(
    renderer_value: ?*tui_renderer_v1,
    bounds: CRect,
    descriptor: ?*const CControlDesc,
    state: ?*CRadioState,
    radio_value: u32,
) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const target = state orelse return invalid_argument;
    const values = controlValues(desc) catch return invalid_argument;
    var selection: ?u32 = if (target.has_selected != 0) target.selected else null;
    const radio = tui.widget.Radio{
        .label = values.label,
        .value = radio_value,
        .selection = &selection,
        .role = values.role,
        .enabled = values.enabled,
        .focused = values.focused,
    };
    var surface = surfaceFor(rendererHandle(renderer_value orelse return invalid_argument), bounds) catch return invalid_state;
    radio.draw(&surface) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_radio_handle_v1(
    descriptor: ?*const CControlDesc,
    state: ?*CRadioState,
    radio_value: u32,
    event_value: ?*const CEvent,
    update: ?*i32,
) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const target = state orelse return invalid_argument;
    const values = controlValues(desc) catch return invalid_argument;
    var selection: ?u32 = if (target.has_selected != 0) target.selected else null;
    var radio = tui.widget.Radio{
        .label = values.label,
        .value = radio_value,
        .selection = &selection,
        .role = values.role,
        .enabled = values.enabled,
        .focused = values.focused,
    };
    const result = radio.handle(toEvent((event_value orelse return invalid_argument).*) catch return invalid_argument);
    if (selection) |selected| {
        target.selected = selected;
        target.has_selected = 1;
    } else {
        target.has_selected = 0;
    }
    if (update) |output| output.* = updateValue(result);
    return ok;
}

pub export fn tui_text_input_create_v1(allocator_value: ?*const CAllocator, capacity: u64, initial_value: CBytes, out: ?*?*tui_text_input_v1) callconv(.c) i32 {
    const output = out orelse return invalid_argument;
    output.* = null;
    const initial = bytes(initial_value) catch return invalid_argument;
    const storage_len = std.math.cast(usize, capacity) orelse return invalid_argument;
    const handle = createHandle(TextInputHandle, allocator_value) catch |err| return allocatorResult(err);
    const allocator = handle.allocator.allocator();
    const storage = allocator.alloc(u8, storage_len) catch {
        destroyHandle(handle);
        return out_of_memory;
    };
    handle.storage = storage;
    handle.input = tui.widget.TextInput.init(storage, initial) catch |err| {
        allocator.free(storage);
        destroyHandle(handle);
        return mapError(err);
    };
    output.* = @ptrCast(handle);
    return ok;
}

pub export fn tui_text_input_destroy_v1(value: ?*tui_text_input_v1) callconv(.c) void {
    const pointer = value orelse return;
    const handle = textInputHandle(pointer);
    handle.allocator.allocator().free(handle.storage);
    destroyHandle(handle);
}

pub export fn tui_text_input_draw_v1(value: ?*tui_text_input_v1, renderer_value: ?*tui_renderer_v1, bounds: CRect) callconv(.c) i32 {
    const handle = textInputHandle(value orelse return invalid_argument);
    var surface = surfaceFor(rendererHandle(renderer_value orelse return invalid_argument), bounds) catch return invalid_state;
    handle.input.draw(&surface) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_text_input_handle_v1(value: ?*tui_text_input_v1, event_value: ?*const CEvent, update: ?*i32) callconv(.c) i32 {
    const handle = textInputHandle(value orelse return invalid_argument);
    const result = handle.input.handle(toEvent((event_value orelse return invalid_argument).*) catch return invalid_argument);
    if (update) |output| output.* = updateValue(result);
    return ok;
}

pub export fn tui_text_input_set_focus_v1(value: ?*tui_text_input_v1, focused: u8) callconv(.c) i32 {
    textInputHandle(value orelse return invalid_argument).input.focused = focused != 0;
    return ok;
}

pub export fn tui_text_input_set_selection_v1(value: ?*tui_text_input_v1, anchor: u64, cursor: u64) callconv(.c) i32 {
    const handle = textInputHandle(value orelse return invalid_argument);
    _ = handle.input.setSelection(
        std.math.cast(usize, anchor) orelse return invalid_argument,
        std.math.cast(usize, cursor) orelse return invalid_argument,
    ) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_text_input_replace_selection_v1(value: ?*tui_text_input_v1, text_value: CBytes) callconv(.c) i32 {
    const handle = textInputHandle(value orelse return invalid_argument);
    _ = handle.input.replaceSelection(bytes(text_value) catch return invalid_argument) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_text_input_copy_value_v1(
    value: ?*const tui_text_input_v1,
    output_pointer: [*c]u8,
    output_capacity: u64,
    needed: ?*u64,
) callconv(.c) i32 {
    const handle = textInputHandle(@constCast(value orelse return invalid_argument));
    return copyValue(handle.input.value(), output_pointer, output_capacity, needed);
}

pub export fn tui_text_input_take_failure_v1(value: ?*tui_text_input_v1, failure: ?*i32) callconv(.c) i32 {
    const output = failure orelse return invalid_argument;
    output.* = if (textInputHandle(value orelse return invalid_argument).input.takeFailure()) |err| mapError(err) else 0;
    return ok;
}

fn copyValue(value: []const u8, output_pointer: [*c]u8, output_capacity: u64, needed: ?*u64) i32 {
    const required = needed orelse return invalid_argument;
    required.* = value.len;
    const capacity = std.math.cast(usize, output_capacity) orelse return invalid_argument;
    if (capacity < value.len) return buffer_too_small;
    const output = mutableBytes(output_pointer, capacity) catch return invalid_argument;
    @memcpy(output[0..value.len], value);
    return ok;
}

pub export fn tui_text_area_create_v1(allocator_value: ?*const CAllocator, capacity: u64, initial_value: CBytes, out: ?*?*tui_text_area_v1) callconv(.c) i32 {
    const output = out orelse return invalid_argument;
    output.* = null;
    const initial = bytes(initial_value) catch return invalid_argument;
    const storage_len = std.math.cast(usize, capacity) orelse return invalid_argument;
    const handle = createHandle(TextAreaHandle, allocator_value) catch |err| return allocatorResult(err);
    const allocator = handle.allocator.allocator();
    const storage = allocator.alloc(u8, storage_len) catch {
        destroyHandle(handle);
        return out_of_memory;
    };
    handle.storage = storage;
    handle.model = tui.editor.Model.init(storage, initial) catch |err| {
        allocator.free(storage);
        destroyHandle(handle);
        return mapError(err);
    };
    handle.area = .{ .model = &handle.model };
    output.* = @ptrCast(handle);
    return ok;
}

pub export fn tui_text_area_destroy_v1(value: ?*tui_text_area_v1) callconv(.c) void {
    const pointer = value orelse return;
    const handle = textAreaHandle(pointer);
    handle.allocator.allocator().free(handle.storage);
    destroyHandle(handle);
}

pub export fn tui_text_area_layout_v1(value: ?*tui_text_area_v1, size_value: CSizeArgument) callconv(.c) i32 {
    const size = sizeArgument(size_value);
    _ = textAreaHandle(value orelse return invalid_argument).area.layout(.{ .width = size.width, .height = size.height });
    return ok;
}

pub export fn tui_text_area_draw_v1(value: ?*tui_text_area_v1, renderer_value: ?*tui_renderer_v1, bounds: CRect) callconv(.c) i32 {
    const handle = textAreaHandle(value orelse return invalid_argument);
    if (handle.model.viewport.width != bounds.width or handle.model.viewport.height != bounds.height) return invalid_state;
    var surface = surfaceFor(rendererHandle(renderer_value orelse return invalid_argument), bounds) catch return invalid_state;
    handle.area.draw(&surface) catch |err| return mapError(err);
    return ok;
}

pub export fn tui_text_area_handle_v1(value: ?*tui_text_area_v1, event_value: ?*const CEvent, update: ?*i32) callconv(.c) i32 {
    const handle = textAreaHandle(value orelse return invalid_argument);
    const result = handle.area.handle(toEvent((event_value orelse return invalid_argument).*) catch return invalid_argument);
    if (update) |output| output.* = updateValue(result);
    return ok;
}

pub export fn tui_text_area_set_focus_v1(value: ?*tui_text_area_v1, focused: u8) callconv(.c) i32 {
    textAreaHandle(value orelse return invalid_argument).area.focused = focused != 0;
    return ok;
}

pub export fn tui_text_area_set_soft_wrap_v1(value: ?*tui_text_area_v1, enabled: u8) callconv(.c) i32 {
    _ = textAreaHandle(value orelse return invalid_argument).model.setSoftWrap(enabled != 0);
    return ok;
}

pub export fn tui_text_area_copy_value_v1(
    value: ?*const tui_text_area_v1,
    output_pointer: [*c]u8,
    output_capacity: u64,
    needed: ?*u64,
) callconv(.c) i32 {
    const handle = textAreaHandle(@constCast(value orelse return invalid_argument));
    return copyValue(handle.model.value(), output_pointer, output_capacity, needed);
}

pub export fn tui_text_area_take_failure_v1(value: ?*tui_text_area_v1, failure: ?*i32) callconv(.c) i32 {
    const output = failure orelse return invalid_argument;
    output.* = if (textAreaHandle(value orelse return invalid_argument).area.takeFailure()) |err| mapError(err) else 0;
    return ok;
}

pub export fn tui_event_queue_create_v1(allocator_value: ?*const CAllocator, capacity: u64, out: ?*?*tui_event_queue_v1) callconv(.c) i32 {
    const output = out orelse return invalid_argument;
    output.* = null;
    const count = std.math.cast(usize, capacity) orelse return invalid_argument;
    if (count == 0 or count > std.math.maxInt(usize) / 2) return invalid_argument;
    const handle = createHandle(EventQueueHandle, allocator_value) catch |err| return allocatorResult(err);
    const slots = handle.allocator.allocator().alloc(QueueSlot, count) catch {
        destroyHandle(handle);
        return out_of_memory;
    };
    handle.slots = slots;
    handle.produced = .init(0);
    handle.consumed = .init(0);
    output.* = @ptrCast(handle);
    return ok;
}

pub export fn tui_event_queue_destroy_v1(value: ?*tui_event_queue_v1) callconv(.c) void {
    const pointer = value orelse return;
    const handle = eventQueueHandle(pointer);
    handle.allocator.allocator().free(handle.slots);
    destroyHandle(handle);
}

pub export fn tui_event_queue_try_push_v1(value: ?*tui_event_queue_v1, event_value: ?*const CEvent) callconv(.c) i32 {
    const handle = eventQueueHandle(value orelse return invalid_argument);
    const input = event_value orelse return invalid_argument;
    _ = toEvent(input.*) catch return invalid_argument;
    const payload = bytes(input.payload) catch return invalid_argument;
    if (payload.len > event_payload_capacity) return capacity_error;
    queuePush(handle, input.*, payload) catch return queue_full;
    return ok;
}

pub export fn tui_event_queue_try_pop_v1(
    value: ?*tui_event_queue_v1,
    payload_pointer: [*c]u8,
    payload_capacity: u64,
    output: ?*CEvent,
) callconv(.c) i32 {
    const handle = eventQueueHandle(value orelse return invalid_argument);
    const target = output orelse return invalid_argument;
    const capacity = std.math.cast(usize, payload_capacity) orelse return invalid_argument;
    const consumed = handle.consumed.load(.monotonic);
    const produced = handle.produced.load(.acquire);
    if (consumed == produced) return queue_empty;
    const slot = &handle.slots[consumed % handle.slots.len];
    if (capacity < slot.payload_len) return buffer_too_small;
    const output_payload = mutableBytes(payload_pointer, capacity) catch return invalid_argument;
    @memcpy(output_payload[0..slot.payload_len], slot.payload[0..slot.payload_len]);
    target.* = slot.event;
    target.payload = .{
        .ptr = if (slot.payload_len == 0) null else output_payload.ptr,
        .len = slot.payload_len,
    };
    handle.consumed.store(consumed +% 1, .release);
    return ok;
}

fn queuePush(handle: *EventQueueHandle, metadata: CEvent, payload: []const u8) error{Full}!void {
    const produced = handle.produced.load(.monotonic);
    const consumed = handle.consumed.load(.acquire);
    if (produced -% consumed == handle.slots.len) return error.Full;
    const slot = &handle.slots[produced % handle.slots.len];
    slot.event = metadata;
    slot.event.payload = .{ .ptr = null, .len = payload.len };
    slot.payload_len = @intCast(payload.len);
    @memcpy(slot.payload[0..payload.len], payload);
    handle.produced.store(produced +% 1, .release);
}

const QueueSink = struct {
    queue: *EventQueueHandle,

    pub fn emit(self: *QueueSink, value: tui.input.Event) !void {
        const metadata = fromEvent(value);
        const payload = switch (value) {
            .text, .paste_chunk => |part| part,
            .terminal_reply => |reply| reply.raw,
            else => "",
        };
        if (payload.len > event_payload_capacity) return error.PayloadTooLarge;
        try queuePush(self.queue, metadata, payload);
    }
};

pub export fn tui_parser_create_v1(allocator_value: ?*const CAllocator, out: ?*?*tui_parser_v1) callconv(.c) i32 {
    const output = out orelse return invalid_argument;
    output.* = null;
    const handle = createHandle(ParserHandle, allocator_value) catch |err| return allocatorResult(err);
    handle.parser = .{};
    output.* = @ptrCast(handle);
    return ok;
}

pub export fn tui_parser_destroy_v1(value: ?*tui_parser_v1) callconv(.c) void {
    destroyHandle(parserHandle(value orelse return));
}

pub export fn tui_parser_feed_v1(value: ?*tui_parser_v1, input: CBytes, queue_value: ?*tui_event_queue_v1) callconv(.c) i32 {
    const handle = parserHandle(value orelse return invalid_argument);
    var sink = QueueSink{ .queue = eventQueueHandle(queue_value orelse return invalid_argument) };
    handle.parser.feed(bytes(input) catch return invalid_argument, &sink) catch |err| return switch (err) {
        error.Full => queue_full,
        error.PayloadTooLarge => capacity_error,
        else => mapError(err),
    };
    return ok;
}

pub export fn tui_parser_finish_v1(value: ?*tui_parser_v1, queue_value: ?*tui_event_queue_v1) callconv(.c) i32 {
    const handle = parserHandle(value orelse return invalid_argument);
    var sink = QueueSink{ .queue = eventQueueHandle(queue_value orelse return invalid_argument) };
    handle.parser.finish(&sink) catch |err| return switch (err) {
        error.Full => queue_full,
        else => mapError(err),
    };
    return ok;
}

pub export fn tui_parser_abort_v1(value: ?*tui_parser_v1, queue_value: ?*tui_event_queue_v1) callconv(.c) i32 {
    const handle = parserHandle(value orelse return invalid_argument);
    var sink = QueueSink{ .queue = eventQueueHandle(queue_value orelse return invalid_argument) };
    handle.parser.abort(&sink) catch |err| return switch (err) {
        error.Full => queue_full,
        else => mapError(err),
    };
    return ok;
}

fn normalizeScroll(state: *CScrollState, count: u64, visible_rows: u16) void {
    if (count == 0) {
        state.top = 0;
        state.has_selected = 0;
        return;
    }
    if (state.has_selected != 0 and state.selected >= count) state.selected = count - 1;
    state.top = @min(state.top, maxTop(count, visible_rows));
}

fn maxTop(count: u64, visible_rows: u16) u64 {
    return count -| visible_rows;
}

fn revealSelection(state: *CScrollState, count: u64, visible_rows: u16) void {
    if (state.has_selected == 0 or visible_rows == 0) return;
    if (state.selected < state.top) {
        state.top = state.selected;
    } else if (state.selected - state.top >= visible_rows) {
        state.top = state.selected - visible_rows + 1;
    }
    state.top = @min(state.top, maxTop(count, visible_rows));
}

fn handleCollection(bounds: CRect, state: *CScrollState, count: u64, header_rows: u16, event: CEvent) i32 {
    const visible_rows = bounds.height -| header_rows;
    normalizeScroll(state, count, visible_rows);
    if (event.kind == 1) {
        if (event.key_action == 2 or event.modifiers & 0x3f != 0) return 0;
        const previous = if (state.has_selected != 0) state.selected else null;
        const step: u64 = @max(@as(u64, 1), @as(u64, visible_rows) -| 1);
        const selected: u64 = switch (event.key_kind) {
            10 => 0,
            11 => if (count == 0) 0 else count - 1,
            6 => if (previous) |index| index -| 1 else if (count == 0) 0 else count - 1,
            7 => if (previous) |index| @min(index +| 1, count -| 1) else 0,
            14 => if (previous) |index| index -| step else if (count == 0) 0 else count - 1,
            15 => if (previous) |index| @min(index +| step, count -| 1) else 0,
            else => return 0,
        };
        if (count == 0) return 1;
        state.selected = selected;
        state.has_selected = 1;
        if (previous != null and previous.? == selected) return 1;
        revealSelection(state, count, visible_rows);
        return 2;
    }
    if (event.kind == 3 and event.modifiers & 0x3f == 0) {
        const inside = event.x >= bounds.x and event.x < @as(u32, bounds.x) + bounds.width and
            event.y >= bounds.y and event.y < @as(u32, bounds.y) + bounds.height;
        if (!inside) return 0;
        if (event.mouse_action == 3 or event.mouse_action == 4) {
            const previous = state.top;
            state.top = if (event.mouse_action == 3)
                state.top -| 1
            else
                @min(state.top +| 1, maxTop(count, visible_rows));
            return if (state.top == previous) 1 else 2;
        }
        if (event.mouse_action == 0 and event.mouse_button == 1) {
            const local_y = event.y - bounds.y;
            if (local_y < header_rows) return 1;
            const index = state.top + local_y - header_rows;
            if (index >= count) return 1;
            if (state.has_selected != 0 and state.selected == index) return 1;
            state.selected = index;
            state.has_selected = 1;
            return 2;
        }
    }
    return 0;
}

fn activationEvent(event: CEvent) bool {
    if (event.kind == 2) {
        const payload = bytes(event.payload) catch return false;
        return std.mem.eql(u8, payload, " ");
    }
    if (event.kind != 1 or event.key_action != 0 or event.modifiers & 0x3f != 0) return false;
    return event.key_kind == 3 or event.key_kind == 0 and
        (event.key_value == ' ' or event.key_value == '\r' or event.key_value == '\n');
}

fn providerRead(provider: *const CRowsProvider, first: u64, rows: []CProviderRow) i32 {
    if (first > provider.count or rows.len > provider.count - first) return invalid_argument;
    const read = provider.read orelse return invalid_argument;
    return read(provider.context, first, @intCast(rows.len), rows.ptr);
}

const CollectionKind = enum { list, tree, task };

fn drawCollection(
    renderer_value: ?*tui_renderer_v1,
    bounds: CRect,
    descriptor: ?*const CCollectionDesc,
    state: *CScrollState,
    provider_value: ?*const CRowsProvider,
    kind: CollectionKind,
) i32 {
    const desc = descriptor orelse return invalid_argument;
    const provider = provider_value orelse return invalid_argument;
    const handle = rendererHandle(renderer_value orelse return invalid_argument);
    var surface = surfaceFor(handle, bounds) catch return invalid_state;
    const row_role = toRole(desc.row_role) catch return invalid_argument;
    const selected_role = toRole(desc.selected_role) catch return invalid_argument;
    const width_profile = toWidth(desc.width_profile) catch return invalid_argument;
    normalizeScroll(state, provider.count, bounds.height);
    var row_buffer: [provider_batch_capacity]CProviderRow = undefined;
    var y: u16 = 0;
    while (y < bounds.height) {
        const remaining = @min(@as(u64, bounds.height - y), provider.count -| (state.top + y));
        if (remaining == 0) {
            while (y < bounds.height) : (y += 1) {
                surface.fill(.{ .x = 0, .y = y, .width = bounds.width, .height = 1 }, row_role.resolve(themeState(desc.enabled, desc.focused))) catch |err| return mapError(err);
            }
            break;
        }
        const batch_len: usize = @intCast(@min(remaining, provider_batch_capacity));
        const read_result = providerRead(provider, state.top + y, row_buffer[0..batch_len]);
        if (read_result != 0) return read_result;
        for (row_buffer[0..batch_len], 0..) |row, offset| {
            const index = state.top + y + offset;
            const selected = state.has_selected != 0 and state.selected == index;
            const style = if (selected)
                selected_role.resolve(themeState(desc.enabled, desc.focused))
            else
                row_role.resolve(themeState(desc.enabled, desc.focused));
            const draw_y: u16 = @intCast(y + offset);
            surface.fill(.{ .x = 0, .y = draw_y, .width = bounds.width, .height = 1 }, style) catch |err| return mapError(err);
            const text_value = bytes(row.text) catch return invalid_argument;
            switch (kind) {
                .list => _ = surface.putTextLine(.{ .x = 0, .y = draw_y }, text_value, bounds.width, style, width_profile, .{ .overflow = .ellipsis }) catch |err| return mapError(err),
                .tree => {
                    const indent = @min(@as(usize, row.depth), @as(usize, bounds.width) / 2) * 2;
                    if (indent < bounds.width) {
                        const marker = if (row.flags & 1 == 0) "  " else if (row.flags & 2 != 0) "v " else "> ";
                        const marker_width = @min(@as(u16, 2), bounds.width - @as(u16, @intCast(indent)));
                        _ = surface.putTextLine(.{ .x = @intCast(indent), .y = draw_y }, marker, marker_width, style, width_profile, .{}) catch |err| return mapError(err);
                        const text_x = @as(u16, @intCast(indent)) + marker_width;
                        if (text_x < bounds.width) _ = surface.putTextLine(.{ .x = text_x, .y = draw_y }, text_value, bounds.width - text_x, style, width_profile, .{ .overflow = .ellipsis }) catch |err| return mapError(err);
                    }
                },
                .task => {
                    const marker: []const u8 = switch (row.status) {
                        0 => "[ ] ",
                        1 => "[~] ",
                        2 => "[x] ",
                        3 => "[!] ",
                        4 => "[-] ",
                        else => return invalid_argument,
                    };
                    const marker_width = @min(@as(u16, 4), bounds.width);
                    _ = surface.putTextLine(.{ .x = 0, .y = draw_y }, marker, marker_width, style, width_profile, .{}) catch |err| return mapError(err);
                    if (marker_width < bounds.width) _ = surface.putTextLine(.{ .x = marker_width, .y = draw_y }, text_value, bounds.width - marker_width, style, width_profile, .{ .overflow = .ellipsis }) catch |err| return mapError(err);
                },
            }
        }
        y += @intCast(batch_len);
    }
    return ok;
}

pub export fn tui_scrollback_draw_v1(r: ?*tui_renderer_v1, b: CRect, d: ?*const CCollectionDesc, s: ?*CScrollState, p: ?*const CRowsProvider) callconv(.c) i32 {
    return drawCollection(r, b, d, s orelse return invalid_argument, p, .list);
}
pub export fn tui_list_draw_v1(r: ?*tui_renderer_v1, b: CRect, d: ?*const CCollectionDesc, s: ?*CScrollState, p: ?*const CRowsProvider) callconv(.c) i32 {
    return drawCollection(r, b, d, s orelse return invalid_argument, p, .list);
}
pub export fn tui_menu_draw_v1(r: ?*tui_renderer_v1, b: CRect, d: ?*const CCollectionDesc, s: ?*CMenuState, p: ?*const CRowsProvider) callconv(.c) i32 {
    return drawCollection(r, b, d, &(s orelse return invalid_argument).scroll, p, .list);
}
pub export fn tui_tree_draw_v1(r: ?*tui_renderer_v1, b: CRect, d: ?*const CCollectionDesc, s: ?*CTreeState, p: ?*const CRowsProvider) callconv(.c) i32 {
    return drawCollection(r, b, d, &(s orelse return invalid_argument).scroll, p, .tree);
}
pub export fn tui_task_list_draw_v1(r: ?*tui_renderer_v1, b: CRect, d: ?*const CCollectionDesc, s: ?*CMenuState, p: ?*const CRowsProvider) callconv(.c) i32 {
    return drawCollection(r, b, d, &(s orelse return invalid_argument).scroll, p, .task);
}

fn collectionHandle(bounds: CRect, state: ?*CScrollState, provider: ?*const CRowsProvider, event_value: ?*const CEvent, update: ?*i32, header: u16) i32 {
    const target = state orelse return invalid_argument;
    const rows = provider orelse return invalid_argument;
    const event = event_value orelse return invalid_argument;
    if (update) |output| output.* = handleCollection(bounds, target, rows.count, header, event.*);
    return ok;
}

pub export fn tui_scrollback_handle_v1(b: CRect, s: ?*CScrollState, p: ?*const CRowsProvider, e: ?*const CEvent, u: ?*i32) callconv(.c) i32 {
    return collectionHandle(b, s, p, e, u, 0);
}
pub export fn tui_list_handle_v1(b: CRect, s: ?*CScrollState, p: ?*const CRowsProvider, e: ?*const CEvent, u: ?*i32) callconv(.c) i32 {
    return collectionHandle(b, s, p, e, u, 0);
}
pub export fn tui_table_handle_v1(b: CRect, s: ?*CScrollState, p: ?*const CRowsProvider, e: ?*const CEvent, u: ?*i32) callconv(.c) i32 {
    return collectionHandle(b, s, p, e, u, 1);
}

pub export fn tui_menu_handle_v1(b: CRect, state_value: ?*CMenuState, provider: ?*const CRowsProvider, event_value: ?*const CEvent, update: ?*i32) callconv(.c) i32 {
    const state = state_value orelse return invalid_argument;
    const event = event_value orelse return invalid_argument;
    if (activationEvent(event.*)) {
        if (state.scroll.has_selected != 0) {
            state.activated = state.scroll.selected;
            state.has_activated = 1;
        }
        if (update) |output| output.* = 1;
        return ok;
    }
    return collectionHandle(b, &state.scroll, provider, event, update, 0);
}

pub export fn tui_task_list_handle_v1(b: CRect, state_value: ?*CMenuState, provider: ?*const CRowsProvider, event_value: ?*const CEvent, update: ?*i32) callconv(.c) i32 {
    return tui_menu_handle_v1(b, state_value, provider, event_value, update);
}

pub export fn tui_tree_handle_v1(
    bounds: CRect,
    state_value: ?*CTreeState,
    provider_value: ?*const CRowsProvider,
    event_value: ?*const CEvent,
    update: ?*i32,
) callconv(.c) i32 {
    const state = state_value orelse return invalid_argument;
    const provider = provider_value orelse return invalid_argument;
    const event = event_value orelse return invalid_argument;
    normalizeScroll(&state.scroll, provider.count, bounds.height);
    if (activationEvent(event.*)) {
        if (state.scroll.has_selected != 0) {
            state.activated = state.scroll.selected;
            state.has_activated = 1;
        }
        if (update) |output| output.* = 1;
        return ok;
    }
    if (event.kind == 1 and event.key_action != 2 and event.modifiers & 0x3f == 0 and
        (event.key_kind == 8 or event.key_kind == 9 or event.key_kind == 0 and event.key_value == ' '))
    {
        if (state.scroll.has_selected == 0) {
            if (update) |output| output.* = 1;
            return ok;
        }
        var rows: [2]CProviderRow = undefined;
        const count: usize = if (state.scroll.selected + 1 < provider.count) 2 else 1;
        const result = providerRead(provider, state.scroll.selected, rows[0..count]);
        if (result != 0) return result;
        const selected = rows[0];
        if (event.key_kind == 0 or
            event.key_kind == 8 and selected.flags & 1 != 0 and selected.flags & 2 != 0 or
            event.key_kind == 9 and selected.flags & 1 != 0 and selected.flags & 2 == 0)
        {
            if (selected.flags & 1 != 0) {
                state.toggled = state.scroll.selected;
                state.has_toggled = 1;
            }
            if (update) |output| output.* = 1;
            return ok;
        }
        if (event.key_kind == 9 and count == 2 and rows[1].depth > selected.depth) {
            state.scroll.selected += 1;
            revealSelection(&state.scroll, provider.count, bounds.height);
            if (update) |output| output.* = 2;
            return ok;
        }
        if (event.key_kind == 8 and selected.depth != 0) {
            var end = state.scroll.selected;
            var buffer: [provider_batch_capacity]CProviderRow = undefined;
            while (end != 0) {
                const start = end -| provider_batch_capacity;
                const batch_len: usize = @intCast(end - start);
                const read_result = providerRead(provider, start, buffer[0..batch_len]);
                if (read_result != 0) return read_result;
                var index = batch_len;
                while (index != 0) {
                    index -= 1;
                    if (buffer[index].depth < selected.depth) {
                        state.scroll.selected = start + index;
                        revealSelection(&state.scroll, provider.count, bounds.height);
                        if (update) |output| output.* = 2;
                        return ok;
                    }
                }
                end = start;
            }
        }
        if (update) |output| output.* = 1;
        return ok;
    }
    return collectionHandle(bounds, &state.scroll, provider, event, update, 0);
}

pub export fn tui_table_draw_v1(
    renderer_value: ?*tui_renderer_v1,
    bounds: CRect,
    descriptor: ?*const CCollectionDesc,
    state_value: ?*CScrollState,
    provider_value: ?*const CRowsProvider,
    columns_pointer: [*c]const CColumn,
    column_count: u32,
) callconv(.c) i32 {
    const desc = descriptor orelse return invalid_argument;
    const state = state_value orelse return invalid_argument;
    const provider = provider_value orelse return invalid_argument;
    if (column_count != 0 and columns_pointer == null) return invalid_argument;
    const columns = columns_pointer[0..column_count];
    var surface = surfaceFor(rendererHandle(renderer_value orelse return invalid_argument), bounds) catch return invalid_state;
    const width_profile = toWidth(desc.width_profile) catch return invalid_argument;
    const header_style = (toRole(desc.header_role) catch return invalid_argument).resolve(themeState(desc.enabled, desc.focused));
    const row_role = toRole(desc.row_role) catch return invalid_argument;
    const selected_role = toRole(desc.selected_role) catch return invalid_argument;
    if (bounds.height == 0) return ok;
    surface.fill(.{ .x = 0, .y = 0, .width = bounds.width, .height = 1 }, header_style) catch |err| return mapError(err);
    var x: u16 = 0;
    for (columns) |column| {
        if (x == bounds.width) break;
        const field_width = @min(column.width, bounds.width - x);
        _ = surface.putTextLine(.{ .x = x, .y = 0 }, bytes(column.title) catch return invalid_argument, field_width, header_style, width_profile, .{ .overflow = .ellipsis }) catch |err| return mapError(err);
        x += field_width;
    }
    const visible_rows = bounds.height - 1;
    normalizeScroll(state, provider.count, visible_rows);
    var row_buffer: [provider_batch_capacity]CProviderRow = undefined;
    var y: u16 = 0;
    while (y < visible_rows) {
        const remaining = @min(@as(u64, visible_rows - y), provider.count -| (state.top + y));
        if (remaining == 0) {
            surface.fill(.{ .x = 0, .y = y + 1, .width = bounds.width, .height = visible_rows - y }, row_role.resolve(themeState(desc.enabled, desc.focused))) catch |err| return mapError(err);
            break;
        }
        const batch_len: usize = @intCast(@min(remaining, provider_batch_capacity));
        const read_result = providerRead(provider, state.top + y, row_buffer[0..batch_len]);
        if (read_result != 0) return read_result;
        for (row_buffer[0..batch_len], 0..) |row, offset| {
            if (row.cell_count < column_count or column_count != 0 and row.cells == null) return invalid_argument;
            const selected = state.has_selected != 0 and state.selected == state.top + y + offset;
            const style = if (selected) selected_role.resolve(themeState(desc.enabled, desc.focused)) else row_role.resolve(themeState(desc.enabled, desc.focused));
            const draw_y: u16 = @intCast(y + offset + 1);
            surface.fill(.{ .x = 0, .y = draw_y, .width = bounds.width, .height = 1 }, style) catch |err| return mapError(err);
            x = 0;
            for (columns, 0..) |column, column_index| {
                if (x == bounds.width) break;
                const field_width = @min(column.width, bounds.width - x);
                _ = surface.putTextLine(.{ .x = x, .y = draw_y }, bytes(row.cells[column_index]) catch return invalid_argument, field_width, style, width_profile, .{ .overflow = .ellipsis }) catch |err| return mapError(err);
                x += field_width;
            }
        }
        y += @intCast(batch_len);
    }
    return ok;
}

pub export fn tui_line_chart_create_v1(allocator_value: ?*const CAllocator, sample_capacity: u64, cell_capacity: u64, out: ?*?*tui_line_chart_v1) callconv(.c) i32 {
    const output = out orelse return invalid_argument;
    output.* = null;
    const sample_count = std.math.cast(usize, sample_capacity) orelse return invalid_argument;
    const cell_count = std.math.cast(usize, cell_capacity) orelse return invalid_argument;
    const handle = createHandle(LineChartHandle, allocator_value) catch |err| return allocatorResult(err);
    const allocator = handle.allocator.allocator();
    const samples = allocator.alloc(f64, sample_count) catch {
        destroyHandle(handle);
        return out_of_memory;
    };
    const masks = allocator.alloc(u8, cell_count) catch {
        allocator.free(samples);
        destroyHandle(handle);
        return out_of_memory;
    };
    handle.samples = samples;
    handle.masks = masks;
    handle.canvas = tui.render.BrailleCanvas.init(masks, .{ .width = 0, .height = 0 }) catch unreachable;
    output.* = @ptrCast(handle);
    return ok;
}

pub export fn tui_line_chart_destroy_v1(value: ?*tui_line_chart_v1) callconv(.c) void {
    const pointer = value orelse return;
    const handle = lineChartHandle(pointer);
    const allocator = handle.allocator.allocator();
    allocator.free(handle.masks);
    allocator.free(handle.samples);
    destroyHandle(handle);
}

pub export fn tui_line_chart_draw_v1(
    value: ?*tui_line_chart_v1,
    renderer_value: ?*tui_renderer_v1,
    bounds: CRect,
    provider_value: ?*const CSamplesProvider,
    role_value: CRole,
) callconv(.c) i32 {
    const handle = lineChartHandle(value orelse return invalid_argument);
    const provider = provider_value orelse return invalid_argument;
    const sample_count = std.math.cast(usize, provider.count) orelse return invalid_argument;
    if (sample_count > handle.samples.len or provider.count != 0 and provider.read == null) return capacity_error;
    const read = provider.read;
    var offset: usize = 0;
    while (offset < sample_count) {
        const count: usize = @min(provider_batch_capacity, sample_count - offset);
        const result = read.?(provider.context, offset, @intCast(count), handle.samples[offset..].ptr);
        if (result != 0) return result;
        offset += count;
    }
    _ = handle.canvas.resize(.{ .width = bounds.width, .height = bounds.height }) catch return capacity_error;
    var sample_provider = SampleProvider{ .values = handle.samples[0..sample_count] };
    var chart = tui.widget.LineChart(SampleProvider){
        .provider = &sample_provider,
        .canvas = &handle.canvas,
        .role = toRole(role_value) catch return invalid_argument,
    };
    var surface = surfaceFor(rendererHandle(renderer_value orelse return invalid_argument), bounds) catch return invalid_state;
    chart.draw(&surface) catch |err| return mapError(err);
    return ok;
}
