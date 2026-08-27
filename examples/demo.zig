const std = @import("std");
const tui = @import("tui");

const tick_timer_id: tui.runtime.TimerId = 1;
const tab_labels = [_][]const u8{ "OVERVIEW", "WIDGETS", "DATA", "EDITOR", "TERMINAL" };
const workspace_width: u16 = 160;
const workspace_height: u16 = 33;

pub const ColorScheme = enum { adaptive, dark, light };
const Tab = enum(u8) { overview, widgets, data, editor, terminal };
const Control = enum { none, suspend_requested, continued };

const Theme = struct {
    canvas: tui.render.Style,
    accent: tui.render.Style,
    secondary: tui.render.Style,
    heading: tui.render.Style,
    selected: tui.render.Style,
    violet: tui.render.Style,
    muted: tui.render.Style,
    success: tui.render.Style,
    warning: tui.render.Style,
    error_style: tui.render.Style,
};

fn themeFor(scheme: ColorScheme) Theme {
    const accent = paletteColor(scheme, 12, 4);
    const secondary = paletteColor(scheme, 14, 6);
    const violet = paletteColor(scheme, 13, 5);
    const green = paletteColor(scheme, 10, 2);
    const amber = paletteColor(scheme, 11, 3);
    const red = paletteColor(scheme, 9, 1);
    const muted = paletteColor(scheme, 8, 8);
    return .{
        .canvas = .{},
        .accent = .{ .foreground = accent, .attributes = .{ .bold = true } },
        .secondary = .{ .foreground = secondary, .attributes = .{ .bold = true } },
        .heading = .{ .attributes = .{ .bold = true } },
        .selected = .{ .foreground = accent, .attributes = .{ .bold = true, .reverse = true } },
        .violet = .{ .foreground = violet, .attributes = .{ .bold = true } },
        .muted = .{ .foreground = muted },
        .success = .{ .foreground = green, .attributes = .{ .bold = true } },
        .warning = .{ .foreground = amber, .attributes = .{ .bold = true } },
        .error_style = .{ .foreground = red, .attributes = .{ .bold = true } },
    };
}

fn paletteColor(scheme: ColorScheme, dark: u8, light: u8) tui.render.Color {
    return switch (scheme) {
        .adaptive => .default,
        .dark => .{ .indexed = dark },
        .light => .{ .indexed = light },
    };
}

pub fn colorSchemeForBackground(background: tui.terminal.Rgb16) ColorScheme {
    const luminance = @as(u64, 299) * background.red +
        @as(u64, 587) * background.green +
        @as(u64, 114) * background.blue;
    return if (luminance >= @as(u64, 500) * std.math.maxInt(u16)) .light else .dark;
}

pub const Metrics = struct {
    update_ns: u64 = 0,
    draw_ns: u64 = 0,
    present_ns: u64 = 0,
    total_ns: u64 = 0,
    frame: tui.render.FrameStats = .{},
};

const FrameHistory = struct {
    values: [64]f64 = @splat(0),

    fn append(self: *FrameHistory, value: f64) void {
        std.mem.copyForwards(f64, self.values[0 .. self.values.len - 1], self.values[1..]);
        self.values[self.values.len - 1] = value;
    }
};

const ListProvider = struct {
    const rows = [_][]const u8{
        "render.Surface",
        "render.Renderer",
        "widget.TextInput",
        "widget.TextArea",
        "runtime.Posix",
        "terminal.Session",
        "subprocess.PtyProcess",
        "testing.Headless",
    };

    pub fn count(_: *const ListProvider) usize {
        return rows.len;
    }

    pub fn row(_: *const ListProvider, index: usize) []const u8 {
        return rows[index];
    }
};

const TableProvider = struct {
    const rows = [_][4][]const u8{
        .{ "renderer", "ready", "diff", "zero alloc" },
        .{ "input", "ready", "UTF-8", "streaming" },
        .{ "layout", "ready", "bounded", "no heap" },
        .{ "runtime", "active", "POSIX", "timer" },
        .{ "images", "ready", "fallback", "Unicode" },
        .{ "bindings", "ready", "ABI 61", "5 languages" },
    };

    pub fn count(_: *const TableProvider) usize {
        return rows.len;
    }

    pub fn cell(_: *const TableProvider, row: usize, column: usize) []const u8 {
        return rows[row][column];
    }
};

const TreeProvider = struct {
    src_expanded: bool = true,

    const Node = enum { src, render, widget, terminal, readme, build };

    pub fn count(self: *const TreeProvider) usize {
        return if (self.src_expanded) 6 else 3;
    }

    fn node(self: *const TreeProvider, index: usize) Node {
        if (self.src_expanded) return @enumFromInt(index);
        return switch (index) {
            0 => .src,
            1 => .readme,
            2 => .build,
            else => unreachable,
        };
    }

    pub fn row(self: *const TreeProvider, index: usize) []const u8 {
        return switch (self.node(index)) {
            .src => "src",
            .render => "render",
            .widget => "widget",
            .terminal => "terminal",
            .readme => "README.md",
            .build => "build.zig",
        };
    }

    pub fn depth(self: *const TreeProvider, index: usize) usize {
        return switch (self.node(index)) {
            .render, .widget, .terminal => 1,
            else => 0,
        };
    }

    pub fn hasChildren(self: *const TreeProvider, index: usize) bool {
        return self.node(index) == .src;
    }

    pub fn expanded(self: *const TreeProvider, index: usize) bool {
        return self.node(index) == .src and self.src_expanded;
    }
};

const TaskProvider = struct {
    statuses: [6]tui.widget.TaskStatus = .{ .succeeded, .succeeded, .running, .pending, .failed, .cancelled },
    const rows = [_][]const u8{
        "Unicode conformance",
        "incremental renderer",
        "PTY event stream",
        "image negotiation",
        "failed state sample",
        "cancelled state sample",
    };

    pub fn count(_: *const TaskProvider) usize {
        return rows.len;
    }

    pub fn row(_: *const TaskProvider, index: usize) []const u8 {
        return rows[index];
    }

    pub fn status(self: *const TaskProvider, index: usize) tui.widget.TaskStatus {
        return self.statuses[index];
    }
};

const LogProvider = struct {
    const rows = [_][]const u8{
        "Terminal session started",
        "Keyboard input enabled",
        "Mouse click, drag, and wheel enabled",
        "Multi-line paste enabled",
        "Display colors detected",
        "Terminal features checked",
        "First frame drawn",
        "Performance sampling active",
        "App screen isolated from shell",
        "No memory allocations while running",
    };

    pub fn count(_: *const LogProvider) usize {
        return rows.len;
    }

    pub fn row(_: *const LogProvider, index: usize) []const u8 {
        return rows[index];
    }
};

const PageLayout = struct {
    first: tui.render.Rect = empty_rect,
    second: tui.render.Rect = empty_rect,
    third: tui.render.Rect = empty_rect,
    fourth: tui.render.Rect = empty_rect,
};

const empty_rect = tui.render.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };

pub const DemoApp = struct {
    editor_model: *tui.editor.Model,
    text_input: tui.widget.TextInput,
    frame_history: FrameHistory = .{},
    tab: Tab = .overview,
    tab_rects: [tab_labels.len]tui.render.Rect = @splat(empty_rect),
    workspace: tui.render.Rect = empty_rect,
    screen_size: tui.render.Size = .{ .width = 0, .height = 0 },
    color_scheme: ColorScheme = .adaptive,
    metrics: Metrics = .{},
    capabilities: tui.terminal.Capabilities = .{},
    chart_paused: bool = false,
    full_paint: bool = true,
    quit: bool = false,

    widgets_focus: u8 = 0,
    highlight_selection: bool = true,
    spacing_selection: ?u32 = 0,
    preferences_saved: bool = false,
    input_mouse_anchor: usize = 0,
    input_mouse_dragging: bool = false,

    data_focus: u8 = 0,
    tree_provider: TreeProvider = .{},
    tree_state: tui.widget.TreeState = .{ .scroll = .{ .selected = 0 } },
    list_provider: ListProvider = .{},
    list_state: tui.widget.ScrollState = .{ .selected = 0 },
    table_provider: TableProvider = .{},
    table_state: tui.widget.ScrollState = .{ .selected = 0 },
    task_provider: TaskProvider = .{},
    task_state: tui.widget.TaskListState = .{ .scroll = .{ .selected = 0 } },

    editor_mouse_anchor: usize = 0,
    editor_mouse_dragging: bool = false,
    editor_soft_wrap: bool = false,
    log_provider: LogProvider = .{},
    log_viewport: tui.scroll.Viewport = .{},
    last_event: [64]u8 = @splat(0),
    last_event_len: usize = 0,

    pub fn init(input_storage: []u8, editor_model: *tui.editor.Model) !DemoApp {
        var text_input = try tui.widget.TextInput.init(input_storage, "Ada Lovelace");
        _ = try text_input.setSelection(4, 12);
        return .{
            .editor_model = editor_model,
            .text_input = text_input,
        };
    }

    pub fn setTerminalBackground(self: *DemoApp, background: tui.terminal.Rgb16) bool {
        const scheme = colorSchemeForBackground(background);
        if (scheme == self.color_scheme) return false;
        self.color_scheme = scheme;
        self.full_paint = true;
        return true;
    }

    pub fn setCapabilities(self: *DemoApp, capabilities: tui.terminal.Capabilities) void {
        self.capabilities = capabilities;
    }

    pub fn layout(self: *DemoApp, size: tui.render.Size) void {
        const width = @min(size.width, workspace_width);
        const x = (size.width - width) / 2;
        self.screen_size = size;
        self.workspace = .{
            .x = x,
            .y = 0,
            .width = width,
            .height = size.height,
        };
        self.layoutTabs(x, self.headerY(), width);
        self.full_paint = true;
    }

    pub fn tick(self: *DemoApp) tui.widget.Update {
        if (self.chart_paused) return .handled;
        self.frame_history.append(nsToMs(self.metrics.total_ns));
        return .redraw;
    }

    pub fn handle(self: *DemoApp, event: tui.input.Event) tui.widget.Update {
        self.recordEvent(event);
        if (event == .key) {
            const key = event.key;
            if (key.action != .release and key.modifiers.control) switch (key.code) {
                .codepoint => |codepoint| if (codepoint == 'q') {
                    self.quit = true;
                    return .handled;
                },
                else => {},
            };
            if (key.action != .release and key.modifiers.alt) switch (key.code) {
                .left => return self.switchRelative(-1),
                .right => return self.switchRelative(1),
                .codepoint => |codepoint| if (codepoint >= '1' and codepoint <= '5') {
                    return self.setTab(@enumFromInt(codepoint - '1'));
                },
                else => {},
            };
            if (key.action != .release and !key.modifiers.hasNonLock()) switch (key.code) {
                .escape => {
                    self.quit = true;
                    return .handled;
                },
                .left => if (self.tab == .overview) return self.switchRelative(-1),
                .right => if (self.tab == .overview) return self.switchRelative(1),
                .codepoint => |codepoint| if (self.tab == .overview and codepoint >= '1' and codepoint <= '5') {
                    return self.setTab(@enumFromInt(codepoint - '1'));
                },
                else => {},
            };
        }
        if (event == .mouse) {
            const mouse = event.mouse;
            if (mouse.action == .press and mouse.button == .left and mouse.y == self.headerY()) {
                for (self.tab_rects, 0..) |rect, index| {
                    if (rect.contains(.{ .x = mouse.x, .y = mouse.y })) return self.setTab(@enumFromInt(index));
                }
            }
        }
        return switch (self.tab) {
            .overview => self.handleOverview(event),
            .widgets => self.handleWidgets(event),
            .data => self.handleData(event),
            .editor => self.handleEditor(event),
            .terminal => self.handleTerminal(event),
        };
    }

    pub fn draw(self: *DemoApp, surface: *tui.render.Surface) !void {
        const theme = themeFor(self.color_scheme);
        if (self.full_paint) try surface.fill(tui.render.Rect.fromSize(surface.size()), theme.canvas);
        var content = surface.surface(self.pageBounds());
        try content.fill(tui.render.Rect.fromSize(content.size()), theme.canvas);
        try self.drawHeader(surface, theme);
        switch (self.tab) {
            .overview => try self.drawOverview(surface, theme),
            .widgets => try self.drawWidgets(surface, theme),
            .data => try self.drawData(surface, theme),
            .editor => try self.drawEditor(surface, theme),
            .terminal => try self.drawTerminal(surface, theme),
        }
        self.full_paint = false;
    }

    fn layoutTabs(self: *DemoApp, origin_x: u16, y: u16, width: u16) void {
        var x = origin_x +| @min(@as(u16, 12), width);
        const right = origin_x +| width;
        for (tab_labels, 0..) |label, index| {
            const wanted: u16 = @intCast(label.len + 3);
            const available = right -| x;
            const tab_width = @min(wanted, available);
            self.tab_rects[index] = .{ .x = x, .y = y, .width = tab_width, .height = @intFromBool(tab_width != 0) };
            x +|= tab_width;
        }
    }

    fn setTab(self: *DemoApp, tab: Tab) tui.widget.Update {
        if (self.tab == tab) return .handled;
        self.tab = tab;
        self.input_mouse_dragging = false;
        self.editor_mouse_dragging = false;
        self.full_paint = true;
        return .redraw;
    }

    fn switchRelative(self: *DemoApp, delta: isize) tui.widget.Update {
        const count: isize = tab_labels.len;
        const current: isize = @intFromEnum(self.tab);
        const next = @mod(current + delta, count);
        return self.setTab(@enumFromInt(next));
    }

    fn pageBounds(self: *const DemoApp) tui.render.Rect {
        const max_height: u16 = switch (self.tab) {
            .overview => 30,
            .widgets => 24,
            .data => 28,
            .editor, .terminal => 30,
        };
        const y = self.headerY() +| 2;
        return .{
            .x = self.workspace.x,
            .y = y,
            .width = self.workspace.width,
            .height = @min(self.screen_size.height -| y, max_height),
        };
    }

    fn headerY(self: *const DemoApp) u16 {
        return (self.screen_size.height -| @min(self.screen_size.height, workspace_height)) / 2;
    }

    fn drawHeader(self: *DemoApp, surface: *tui.render.Surface, theme: Theme) !void {
        const size = surface.size();
        if (size.height == 0) return;
        const y = self.headerY();
        var top = surface.surface(.{ .x = self.workspace.x, .y = y, .width = self.workspace.width, .height = 1 });
        try top.fill(tui.render.Rect.fromSize(top.size()), theme.canvas);
        _ = try top.putText(.{ .x = 2, .y = 0 }, "tui.zig", theme.accent, .narrow);
        for (tab_labels, 0..) |label, index| {
            const rect = self.tab_rects[index];
            if (rect.isEmpty()) continue;
            var tab_surface = surface.surface(rect);
            const style = if (index == @intFromEnum(self.tab)) theme.selected else theme.heading;
            try tab_surface.fill(tui.render.Rect.fromSize(tab_surface.size()), style);
            _ = try tab_surface.putTextLine(.{ .x = 1, .y = 0 }, label, rect.width -| 1, style, .narrow, .{});
        }
        if (size.height < 2) return;
        var metrics = surface.surface(.{
            .x = self.workspace.x,
            .y = y + 1,
            .width = self.workspace.width,
            .height = 1,
        });
        try metrics.fill(tui.render.Rect.fromSize(metrics.size()), theme.canvas);
        var buffer: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buffer,
            "frame {d:.3} ms    input {d:.3} ms    render {d:.3} ms    terminal {d:.3} ms    0 alloc",
            .{
                nsToMs(self.metrics.total_ns),
                nsToMs(self.metrics.update_ns),
                nsToMs(self.metrics.draw_ns),
                nsToMs(self.metrics.present_ns),
            },
        );
        _ = try metrics.putTextLine(.{ .x = 2, .y = 0 }, line, metrics.size().width -| 2, theme.secondary, .narrow, .{ .overflow = .ellipsis });
    }

    fn drawOverview(self: *DemoApp, surface: *tui.render.Surface, theme: Theme) !void {
        const page_layout = overviewLayout(self.pageBounds());
        try drawSection(surface, page_layout.first, "Frame time", theme, theme.secondary, true);
        const chart_content = inset(page_layout.first);
        if (!chart_content.isEmpty()) {
            var value_buffer: [64]u8 = undefined;
            const value = try std.fmt.bufPrint(&value_buffer, "{d:.3} ms", .{nsToMs(self.metrics.total_ns)});
            _ = try surface.putText(.{ .x = chart_content.x, .y = chart_content.y }, value, theme.secondary, .narrow);
            if (chart_content.height > 2) {
                _ = try surface.putText(
                    .{ .x = chart_content.x, .y = chart_content.y + 2 },
                    if (self.chart_paused) "last 64 frames (paused)" else "last 64 frames",
                    theme.muted,
                    .narrow,
                );
            }
            if (chart_content.height > 4) {
                try drawSparkline(surface, .{
                    .x = chart_content.x,
                    .y = chart_content.y + 4,
                    .width = chart_content.width,
                    .height = 1,
                }, &self.frame_history, theme.secondary);
            }
        }

        try drawSection(surface, page_layout.second, "Renderer", theme, theme.violet, false);
        var stats = surface.surface(inset(page_layout.second));
        if (!sizeIsEmpty(stats.size())) {
            var buffer: [256]u8 = undefined;
            const text = try std.fmt.bufPrint(
                &buffer,
                "Rows updated    {d}\nCells updated   {d}\nCells checked   {d}\nOutput written  {d} B\nMemory allocs   0",
                .{
                    self.metrics.frame.dirty_rows,
                    self.metrics.frame.cells_changed,
                    self.metrics.frame.cells_compared,
                    self.metrics.frame.bytes,
                },
            );
            const paragraph = tui.widget.Paragraph{ .text = text, .role = .{ .normal = theme.canvas } };
            try paragraph.draw(&stats);
        }

        try drawSection(surface, page_layout.third, "What this demonstrates", theme, theme.success, false);
        var features = surface.surface(inset(page_layout.third));
        if (!sizeIsEmpty(features.size())) {
            const paragraph = tui.widget.Paragraph{
                .text = "Rendering  incremental cells, surfaces, styles, frame diffs\nWidgets    forms, lists, trees, tables, tasks, text editors\nRuntime    timers, signals, resize, focus, mouse, paste, PTYs\nTerminal   adaptive color, capability and media negotiation\nText       Unicode 17, graphemes, wrapping, selection: café 世界",
                .role = .{ .normal = theme.canvas },
            };
            try paragraph.draw(&features);
        }
    }

    fn handleOverview(self: *DemoApp, event: tui.input.Event) tui.widget.Update {
        const activated = switch (event) {
            .key => |key| key.action == .press and !key.modifiers.hasNonLock() and switch (key.code) {
                .codepoint => |codepoint| codepoint == ' ',
                else => false,
            },
            .text => |text| std.mem.eql(u8, text, " "),
            else => false,
        };
        if (activated) {
            self.chart_paused = !self.chart_paused;
            return .redraw;
        }
        return .ignored;
    }

    fn drawWidgets(self: *DemoApp, surface: *tui.render.Surface, theme: Theme) !void {
        const bounds = self.pageBounds();
        try drawSection(surface, bounds, "Demo preferences", theme, theme.accent, true);
        const form = widgetsFormLayout(preferencesBounds(bounds), self.spacing_selection == 1);
        self.drawTextInput(surface, form.first, theme) catch |err| return err;
        try self.drawFormControls(surface, form, theme);
    }

    fn drawTextInput(self: *DemoApp, surface: *tui.render.Surface, bounds: tui.render.Rect, theme: Theme) !void {
        if (bounds.isEmpty()) return;
        _ = try surface.putText(.{ .x = bounds.x, .y = bounds.y -| 1 }, "Session label", theme.heading, .narrow);
        self.text_input.focused = self.widgets_focus == 0;
        self.text_input.role = .{ .normal = theme.canvas, .focused = theme.canvas };
        self.text_input.selection_role = if (self.highlight_selection)
            .{ .normal = theme.selected, .focused = theme.selected }
        else
            .{ .normal = theme.canvas, .focused = theme.canvas };
        var input_surface = surface.surface(bounds);
        try self.text_input.draw(&input_surface);
    }

    fn drawFormControls(self: *DemoApp, surface: *tui.render.Surface, form_layout: PageLayout, theme: Theme) !void {
        const checkbox = tui.widget.Checkbox{
            .label = "highlight selection",
            .checked = self.highlight_selection,
            .focused = self.widgets_focus == 1,
            .role = .{ .normal = theme.canvas, .focused = theme.accent },
        };
        var checkbox_surface = surface.surface(form_layout.second);
        try checkbox.draw(&checkbox_surface);

        var radio_a = tui.widget.Radio{
            .label = "compact spacing",
            .value = 0,
            .selection = &self.spacing_selection,
            .focused = self.widgets_focus == 2,
            .role = .{ .normal = theme.canvas, .focused = theme.accent },
        };
        var radio_surface = surface.surface(form_layout.third);
        try radio_a.draw(&radio_surface);
        var radio_b = tui.widget.Radio{
            .label = "comfortable spacing",
            .value = 1,
            .selection = &self.spacing_selection,
            .focused = self.widgets_focus == 3,
            .role = .{ .normal = theme.canvas, .focused = theme.accent },
        };
        const radio_b_rect = offsetRow(form_layout.third, 1);
        radio_surface = surface.surface(radio_b_rect);
        try radio_b.draw(&radio_surface);
        var button = tui.widget.Button{
            .label = if (self.preferences_saved) "preferences saved" else "save preferences",
            .focused = self.widgets_focus == 4,
            .role = .{ .normal = theme.canvas, .focused = theme.selected },
        };
        var button_surface = surface.surface(form_layout.fourth);
        try button.draw(&button_surface);
    }

    fn handleWidgets(self: *DemoApp, event: tui.input.Event) tui.widget.Update {
        const form = widgetsFormLayout(preferencesBounds(self.pageBounds()), self.spacing_selection == 1);
        if (event == .key) {
            const key = event.key;
            if (key.action != .release and key.code == .tab) {
                self.widgets_focus = if (key.modifiers.shift)
                    if (self.widgets_focus == 0) 4 else self.widgets_focus - 1
                else
                    (self.widgets_focus + 1) % 5;
                return .redraw;
            }
        }
        if (event == .mouse) {
            const mouse = event.mouse;
            switch (mouse.action) {
                .press => if (mouse.button == .left) {
                    if (form.first.contains(.{ .x = mouse.x, .y = mouse.y })) {
                        self.widgets_focus = 0;
                        return self.beginInputSelection(mouse, form.first);
                    }
                    self.input_mouse_dragging = false;
                    if (form.second.contains(.{ .x = mouse.x, .y = mouse.y })) self.widgets_focus = 1;
                    if (form.third.contains(.{ .x = mouse.x, .y = mouse.y })) self.widgets_focus = if (mouse.y == form.third.y) 2 else 3;
                    if (form.fourth.contains(.{ .x = mouse.x, .y = mouse.y })) self.widgets_focus = 4;
                },
                .move => if (self.input_mouse_dragging) return self.extendInputSelection(mouse, form.first),
                .release => if (self.input_mouse_dragging) {
                    self.input_mouse_dragging = false;
                    return self.extendInputSelection(mouse, form.first);
                },
                else => {},
            }
        }
        return switch (self.widgets_focus) {
            0 => self.text_input.handle(event),
            1 => self.handleCheckbox(event),
            2 => self.handleRadio(event, 0),
            3 => self.handleRadio(event, 1),
            4 => self.handleButton(event),
            else => .ignored,
        };
    }

    fn inputCursorAt(self: *const DemoApp, mouse: tui.input.Mouse, bounds: tui.render.Rect) usize {
        const view_start = self.text_input.view_start;
        const column = if (mouse.x <= bounds.x) 0 else @min(mouse.x - bounds.x, bounds.width);
        return view_start + byteOffsetAtColumn(
            self.text_input.value()[view_start..],
            column,
            self.text_input.width_profile,
        );
    }

    fn beginInputSelection(self: *DemoApp, mouse: tui.input.Mouse, bounds: tui.render.Rect) tui.widget.Update {
        const cursor = self.inputCursorAt(mouse, bounds);
        const anchor = if (mouse.modifiers.shift)
            self.text_input.anchor orelse self.text_input.cursor
        else
            cursor;
        _ = self.text_input.setSelection(anchor, cursor) catch return .handled;
        self.input_mouse_anchor = anchor;
        self.input_mouse_dragging = true;
        return .redraw;
    }

    fn extendInputSelection(self: *DemoApp, mouse: tui.input.Mouse, bounds: tui.render.Rect) tui.widget.Update {
        _ = self.text_input.setSelection(self.input_mouse_anchor, self.inputCursorAt(mouse, bounds)) catch return .handled;
        return .redraw;
    }

    fn handleCheckbox(self: *DemoApp, event: tui.input.Event) tui.widget.Update {
        var checkbox = tui.widget.Checkbox{ .label = "highlight selection", .checked = self.highlight_selection };
        const update = checkbox.handle(event);
        if (checkbox.checked != self.highlight_selection) self.preferences_saved = false;
        self.highlight_selection = checkbox.checked;
        return update;
    }

    fn handleRadio(self: *DemoApp, event: tui.input.Event, value: u32) tui.widget.Update {
        const previous = self.spacing_selection;
        var radio = tui.widget.Radio{ .label = "", .value = value, .selection = &self.spacing_selection };
        const update = radio.handle(event);
        if (self.spacing_selection != previous) self.preferences_saved = false;
        return update;
    }

    fn handleButton(self: *DemoApp, event: tui.input.Event) tui.widget.Update {
        var button = tui.widget.Button{ .label = "save preferences" };
        const update = button.handle(event);
        if (button.takeActivation()) {
            self.preferences_saved = true;
            return .redraw;
        }
        return update;
    }

    fn drawData(self: *DemoApp, surface: *tui.render.Surface, theme: Theme) !void {
        const page_layout = fourGrid(self.pageBounds());
        try self.drawTree(surface, page_layout.first, theme);
        try self.drawList(surface, page_layout.second, theme);
        try self.drawTable(surface, page_layout.third, theme);
        try self.drawTasks(surface, page_layout.fourth, theme);
    }

    fn drawTree(self: *DemoApp, surface: *tui.render.Surface, bounds: tui.render.Rect, theme: Theme) !void {
        try drawSection(surface, bounds, "Project tree", theme, theme.accent, self.data_focus == 0);
        const content = inset(bounds);
        var tree = tui.widget.Tree(TreeProvider){
            .provider = &self.tree_provider,
            .state = &self.tree_state,
            .bounds = content,
            .row_role = .{ .normal = theme.canvas },
            .selected_role = .{ .normal = theme.selected, .focused = theme.selected },
            .focused = self.data_focus == 0,
        };
        var tree_surface = surface.surface(content);
        try tree.draw(&tree_surface);
    }

    fn drawList(self: *DemoApp, surface: *tui.render.Surface, bounds: tui.render.Rect, theme: Theme) !void {
        try drawSection(surface, bounds, "Components", theme, theme.secondary, self.data_focus == 1);
        const content = inset(bounds);
        var list = tui.widget.List(ListProvider){
            .provider = &self.list_provider,
            .state = &self.list_state,
            .bounds = content,
            .row_role = .{ .normal = theme.canvas },
            .selected_role = .{ .normal = theme.selected, .focused = theme.selected },
            .focused = self.data_focus == 1,
        };
        var list_surface = surface.surface(content);
        try list.draw(&list_surface);
    }

    fn drawTable(self: *DemoApp, surface: *tui.render.Surface, bounds: tui.render.Rect, theme: Theme) !void {
        try drawSection(surface, bounds, "Runtime matrix", theme, theme.violet, self.data_focus == 2);
        const content = inset(bounds);
        var columns = tableColumns(content.width);
        var table = tui.widget.Table(TableProvider){
            .provider = &self.table_provider,
            .state = &self.table_state,
            .bounds = content,
            .columns = &columns,
            .row_role = .{ .normal = theme.canvas },
            .selected_role = .{ .normal = theme.selected, .focused = theme.selected },
            .header_role = .{ .normal = theme.violet },
            .focused = self.data_focus == 2,
        };
        var table_surface = surface.surface(content);
        try table.draw(&table_surface);
    }

    fn drawTasks(self: *DemoApp, surface: *tui.render.Surface, bounds: tui.render.Rect, theme: Theme) !void {
        try drawSection(surface, bounds, "Task states", theme, theme.success, self.data_focus == 3);
        const content = inset(bounds);
        var tasks = tui.widget.TaskList(TaskProvider){
            .provider = &self.task_provider,
            .state = &self.task_state,
            .bounds = content,
            .row_role = .{ .normal = theme.canvas },
            .running_role = .{ .normal = theme.warning },
            .succeeded_role = .{ .normal = theme.success },
            .failed_role = .{ .normal = theme.error_style },
            .cancelled_role = .{ .normal = theme.secondary },
            .selected_role = .{ .normal = theme.selected, .focused = theme.selected },
            .focused = self.data_focus == 3,
        };
        var task_surface = surface.surface(content);
        try tasks.draw(&task_surface);
    }

    fn handleData(self: *DemoApp, event: tui.input.Event) tui.widget.Update {
        const page_layout = fourGrid(self.pageBounds());
        const bounds = [_]tui.render.Rect{ inset(page_layout.first), inset(page_layout.second), inset(page_layout.third), inset(page_layout.fourth) };
        if (event == .key) {
            const key = event.key;
            if (key.action != .release and key.code == .tab) {
                self.data_focus = if (key.modifiers.shift)
                    if (self.data_focus == 0) 3 else self.data_focus - 1
                else
                    (self.data_focus + 1) % 4;
                return .redraw;
            }
        }
        if (event == .mouse) {
            const mouse = event.mouse;
            if (mouse.action == .press or mouse.action == .scroll_up or mouse.action == .scroll_down) {
                for (bounds, 0..) |rect, index| if (rect.contains(.{ .x = mouse.x, .y = mouse.y })) {
                    self.data_focus = @intCast(index);
                    break;
                };
            }
        }
        return switch (self.data_focus) {
            0 => self.handleTree(event, bounds[0]),
            1 => self.handleList(event, bounds[1]),
            2 => self.handleTable(event, bounds[2]),
            3 => self.handleTasks(event, bounds[3]),
            else => .ignored,
        };
    }

    fn handleTree(self: *DemoApp, event: tui.input.Event, bounds: tui.render.Rect) tui.widget.Update {
        var tree = tui.widget.Tree(TreeProvider){ .provider = &self.tree_provider, .state = &self.tree_state, .bounds = bounds };
        const update = tree.handle(event);
        if (self.tree_state.takeToggle()) |index| if (self.tree_provider.hasChildren(index)) {
            self.tree_provider.src_expanded = !self.tree_provider.src_expanded;
            return .redraw;
        };
        return update;
    }

    fn handleList(self: *DemoApp, event: tui.input.Event, bounds: tui.render.Rect) tui.widget.Update {
        var list = tui.widget.List(ListProvider){ .provider = &self.list_provider, .state = &self.list_state, .bounds = bounds };
        return list.handle(event);
    }

    fn handleTable(self: *DemoApp, event: tui.input.Event, bounds: tui.render.Rect) tui.widget.Update {
        var columns = tableColumns(bounds.width);
        var table = tui.widget.Table(TableProvider){ .provider = &self.table_provider, .state = &self.table_state, .bounds = bounds, .columns = &columns };
        return table.handle(event);
    }

    fn handleTasks(self: *DemoApp, event: tui.input.Event, bounds: tui.render.Rect) tui.widget.Update {
        var tasks = tui.widget.TaskList(TaskProvider){ .provider = &self.task_provider, .state = &self.task_state, .bounds = bounds };
        const update = tasks.handle(event);
        if (self.task_state.takeActivation()) |index| {
            self.task_provider.statuses[index] = .succeeded;
            return .redraw;
        }
        return update;
    }

    fn drawEditor(self: *DemoApp, surface: *tui.render.Surface, theme: Theme) !void {
        const page_layout = editorLayout(self.pageBounds());
        try drawSection(surface, page_layout.first, "Editor", theme, theme.secondary, true);
        try drawSection(surface, page_layout.second, "Inspector", theme, theme.violet, false);
        const editor_bounds = inset(page_layout.first);
        var editor = tui.widget.TextArea{
            .model = self.editor_model,
            .focused = true,
            .role = .{ .normal = theme.canvas, .focused = theme.canvas },
            .selection_role = .{ .normal = theme.selected, .focused = theme.selected },
        };
        _ = editor.layout(.{ .width = editor_bounds.width, .height = editor_bounds.height });
        var editor_surface = surface.surface(editor_bounds);
        try editor.draw(&editor_surface);

        var info = surface.surface(inset(page_layout.second));
        if (!sizeIsEmpty(info.size())) {
            const position = self.editor_model.cursorPosition();
            const selected_bytes = if (self.editor_model.selectedText()) |selected| selected.len else 0;
            var buffer: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(
                &buffer,
                "Cursor\n  row {d}, column {d}\n\nSelection\n  {d} bytes\n\nSoft wrap\n  {s}\n\nShortcuts\n  Shift+Arrow select\n  Ctrl+A select all\n  F2 toggle wrap\n  Mouse drag select",
                .{ position.row + 1, position.column + 1, selected_bytes, if (self.editor_soft_wrap) "on" else "off" },
            );
            const paragraph = tui.widget.Paragraph{ .text = text, .role = .{ .normal = theme.canvas } };
            try paragraph.draw(&info);
        }
    }

    fn handleEditor(self: *DemoApp, event: tui.input.Event) tui.widget.Update {
        const page_layout = editorLayout(self.pageBounds());
        const editor_bounds = inset(page_layout.first);
        if (event == .mouse) {
            const mouse = event.mouse;
            switch (mouse.action) {
                .press => if (mouse.button == .left and editor_bounds.contains(.{ .x = mouse.x, .y = mouse.y })) {
                    return self.beginEditorSelection(mouse, editor_bounds);
                },
                .move => if (self.editor_mouse_dragging) return self.extendEditorSelection(mouse, editor_bounds),
                .release => if (self.editor_mouse_dragging) {
                    self.editor_mouse_dragging = false;
                    return self.extendEditorSelection(mouse, editor_bounds);
                },
                else => {},
            }
            if ((mouse.action == .scroll_up or mouse.action == .scroll_down) and editor_bounds.contains(.{ .x = mouse.x, .y = mouse.y })) {
                const key: tui.input.KeyCode = if (mouse.action == .scroll_up) .up else .down;
                var editor = tui.widget.TextArea{ .model = self.editor_model, .focused = true };
                return editor.handle(.{ .key = .{ .code = key } });
            }
        }
        if (event == .key) {
            const key = event.key;
            if (key.action != .release and !key.modifiers.hasNonLock() and key.code == .function and key.code.function == 2) {
                self.editor_soft_wrap = !self.editor_soft_wrap;
                _ = self.editor_model.setSoftWrap(self.editor_soft_wrap);
                return .redraw;
            }
        }
        var editor = tui.widget.TextArea{ .model = self.editor_model, .focused = true };
        return editor.handle(event);
    }

    fn editorCursorAt(self: *DemoApp, mouse: tui.input.Mouse, bounds: tui.render.Rect) usize {
        if (bounds.isEmpty()) return self.editor_model.cursor;
        const relative_y: u16 = if (mouse.y <= bounds.y) 0 else @min(mouse.y - bounds.y, bounds.height - 1);
        const visible_row = self.editor_model.viewport.top_row + relative_y;
        const range = if (self.editor_model.softWrapEnabled()) wrapped: {
            var rows = self.editor_model.visualRows();
            for (0..visible_row) |_| _ = rows.next() orelse return self.editor_model.value().len;
            const row = rows.next() orelse return self.editor_model.value().len;
            break :wrapped tui.editor.Selection{ .start = row.start, .end = row.end };
        } else self.editor_model.lineRange(visible_row) orelse return self.editor_model.value().len;
        const relative_x: u16 = if (mouse.x <= bounds.x) 0 else @min(mouse.x - bounds.x, bounds.width);
        const target_column = @as(usize, relative_x) + self.editor_model.viewport.left_column;
        return range.start + byteOffsetAtColumn(
            self.editor_model.value()[range.start..range.end],
            target_column,
            self.editor_model.width_profile,
        );
    }

    fn beginEditorSelection(self: *DemoApp, mouse: tui.input.Mouse, bounds: tui.render.Rect) tui.widget.Update {
        const cursor = self.editorCursorAt(mouse, bounds);
        const anchor = if (mouse.modifiers.shift)
            self.editor_model.anchor orelse self.editor_model.cursor
        else
            cursor;
        _ = self.editor_model.setSelection(anchor, cursor) catch return .handled;
        self.editor_mouse_anchor = anchor;
        self.editor_mouse_dragging = true;
        return .redraw;
    }

    fn extendEditorSelection(self: *DemoApp, mouse: tui.input.Mouse, bounds: tui.render.Rect) tui.widget.Update {
        _ = self.editor_model.setSelection(self.editor_mouse_anchor, self.editorCursorAt(mouse, bounds)) catch return .handled;
        return .redraw;
    }

    fn drawTerminal(self: *DemoApp, surface: *tui.render.Surface, theme: Theme) !void {
        const page_layout = terminalLayout(self.pageBounds());
        try drawSection(surface, page_layout.first, "Display support", theme, theme.accent, false);
        try drawSection(surface, page_layout.second, "Active input", theme, theme.violet, false);
        try drawSection(surface, page_layout.third, "Session activity", theme, theme.success, true);
        var caps = surface.surface(inset(page_layout.first));
        if (!sizeIsEmpty(caps.size())) {
            var buffer: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(
                &buffer,
                "Colors         {s}\nFrame updates  {s}\nKeyboard       {s}\nImages         {s}\nLinks          {s}\nClipboard      {s}\nTheme          {s}",
                .{
                    colorDepthLabel(self.capabilities.color_depth),
                    if (self.capabilities.synchronized_output) "flicker-free" else "standard",
                    if (self.capabilities.kitty_keyboard) "enhanced" else "standard",
                    imageLabel(self.capabilities.image_protocol),
                    availability(self.capabilities.hyperlinks),
                    availability(self.capabilities.clipboard_write),
                    @tagName(self.color_scheme),
                },
            );
            const paragraph = tui.widget.Paragraph{ .text = text, .role = .{ .normal = theme.canvas } };
            try paragraph.draw(&caps);
        }
        var media = surface.surface(inset(page_layout.second));
        if (!sizeIsEmpty(media.size())) {
            var buffer: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(
                &buffer,
                "Last activity\n{s}\n\nKeyboard   Unicode text\nMouse      click, drag, wheel\nPaste      multi-line\nSelection  keyboard or mouse",
                .{self.last_event[0..self.last_event_len]},
            );
            const paragraph = tui.widget.Paragraph{ .text = text, .role = .{ .normal = theme.canvas } };
            try paragraph.draw(&media);
        }
        const log_bounds = inset(page_layout.third);
        var logs = tui.widget.Scrollback(LogProvider){
            .provider = &self.log_provider,
            .viewport = &self.log_viewport,
            .bounds = log_bounds,
            .role = .{ .normal = theme.canvas, .focused = theme.canvas },
            .focused = true,
        };
        var log_surface = surface.surface(log_bounds);
        try logs.draw(&log_surface);
    }

    fn handleTerminal(self: *DemoApp, event: tui.input.Event) tui.widget.Update {
        const log_bounds = inset(terminalLayout(self.pageBounds()).third);
        var logs = tui.widget.Scrollback(LogProvider){
            .provider = &self.log_provider,
            .viewport = &self.log_viewport,
            .bounds = log_bounds,
            .focused = true,
        };
        const update = logs.handle(event);
        return if (update == .ignored) .redraw else update;
    }

    fn recordEvent(self: *DemoApp, event: tui.input.Event) void {
        const label = switch (event) {
            .key => "Keyboard command",
            .text => "Text entered",
            .mouse => |mouse| switch (mouse.action) {
                .press => "Mouse pressed",
                .release => "Mouse released",
                .move => "Mouse dragged",
                .scroll_up => "Scrolled up",
                .scroll_down => "Scrolled down",
                .scroll_left => "Scrolled left",
                .scroll_right => "Scrolled right",
            },
            .paste_start => "Paste started",
            .paste_chunk => "Text pasted",
            .paste_end => "Paste finished",
            .focus_in => "Window focused",
            .focus_out => "Window focus lost",
            .cursor_position => "Cursor position received",
            .terminal_reply => "Terminal response received",
            .malformed => "Invalid input ignored",
        };
        self.last_event_len = @min(label.len, self.last_event.len);
        @memcpy(self.last_event[0..self.last_event_len], label[0..self.last_event_len]);
    }
};

fn drawSection(
    surface: *tui.render.Surface,
    bounds: tui.render.Rect,
    title: []const u8,
    theme: Theme,
    tone: tui.render.Style,
    focused: bool,
) !void {
    if (bounds.isEmpty()) return;
    var section = surface.surface(bounds);
    try section.fill(tui.render.Rect.fromSize(section.size()), theme.canvas);
    if (focused) _ = try section.putText(.{ .x = 0, .y = 0 }, "›", tone, .narrow);
    _ = try section.putTextLine(.{ .x = 2, .y = 0 }, title, section.size().width -| 2, tone, .narrow, .{ .overflow = .ellipsis });
}

fn drawSparkline(
    surface: *tui.render.Surface,
    bounds: tui.render.Rect,
    history: *const FrameHistory,
    style: tui.render.Style,
) !void {
    if (bounds.isEmpty()) return;
    const glyphs = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    const count = @min(@as(usize, bounds.width), history.values.len);
    const start = history.values.len - count;
    var minimum = history.values[start];
    var maximum = minimum;
    for (history.values[start..]) |value| {
        minimum = @min(minimum, value);
        maximum = @max(maximum, value);
    }
    const range = maximum - minimum;
    for (history.values[start..], 0..) |value, index| {
        const level: usize = if (range <= 0)
            0
        else
            @intFromFloat(@round((value - minimum) * 7 / range));
        _ = try surface.putText(
            .{ .x = bounds.x + @as(u16, @intCast(index)), .y = bounds.y },
            glyphs[@min(level, glyphs.len - 1)],
            style,
            .narrow,
        );
    }
}

fn inset(rect: tui.render.Rect) tui.render.Rect {
    if (rect.width < 4 or rect.height < 2) return empty_rect;
    return .{ .x = rect.x + 2, .y = rect.y + 2, .width = rect.width - 4, .height = rect.height - 2 };
}

fn sizeIsEmpty(size: tui.render.Size) bool {
    return size.width == 0 or size.height == 0;
}

fn offsetRow(rect: tui.render.Rect, offset: u16) tui.render.Rect {
    if (offset >= rect.height) return empty_rect;
    return .{ .x = rect.x, .y = rect.y + offset, .width = rect.width, .height = 1 };
}

fn preferencesBounds(section: tui.render.Rect) tui.render.Rect {
    var bounds = inset(section);
    const width = @min(bounds.width, 72);
    bounds.x += (bounds.width - width) / 2;
    bounds.width = width;
    return bounds;
}

fn twoColumns(bounds: tui.render.Rect) PageLayout {
    const gap: u16 = @intFromBool(bounds.width > 2);
    const left = (bounds.width - gap) / 2;
    return .{
        .first = .{ .x = bounds.x, .y = bounds.y, .width = left, .height = bounds.height },
        .second = .{ .x = bounds.x + left + gap, .y = bounds.y, .width = bounds.width - left - gap, .height = bounds.height },
    };
}

fn overviewLayout(bounds: tui.render.Rect) PageLayout {
    const column_gap: u16 = @intFromBool(bounds.width > 2);
    const row_gap: u16 = @intFromBool(bounds.height > 2);
    const top_height = @max(@as(u16, 10), (bounds.height - row_gap) / 2);
    const top = @min(top_height, bounds.height - row_gap);
    const left = (bounds.width - column_gap) * 2 / 3;
    return .{
        .first = .{ .x = bounds.x, .y = bounds.y, .width = left, .height = top },
        .second = .{ .x = bounds.x + left + column_gap, .y = bounds.y, .width = bounds.width - left - column_gap, .height = top },
        .third = .{ .x = bounds.x, .y = bounds.y + top + row_gap, .width = bounds.width, .height = bounds.height - top - row_gap },
    };
}

fn widgetsFormLayout(bounds: tui.render.Rect, comfortable: bool) PageLayout {
    const input_y = bounds.y + @intFromBool(bounds.height > 1);
    const checkbox_row: u16 = if (comfortable) 5 else 4;
    const radio_row: u16 = if (comfortable) 8 else 6;
    const button_row: u16 = if (comfortable) 12 else 9;
    return .{
        .first = .{ .x = bounds.x +| 1, .y = input_y, .width = bounds.width -| 2, .height = @intFromBool(bounds.height > 1) },
        .second = .{ .x = bounds.x +| 1, .y = bounds.y +| checkbox_row, .width = bounds.width -| 2, .height = @intFromBool(bounds.height > checkbox_row) },
        .third = .{ .x = bounds.x +| 1, .y = bounds.y +| radio_row, .width = bounds.width -| 2, .height = @min(bounds.height -| radio_row, 2) },
        .fourth = .{ .x = bounds.x +| 1, .y = bounds.y +| button_row, .width = @min(bounds.width -| 2, 24), .height = @intFromBool(bounds.height > button_row) },
    };
}

fn fourGrid(bounds: tui.render.Rect) PageLayout {
    const column_gap: u16 = @intFromBool(bounds.width > 2);
    const row_gap: u16 = @intFromBool(bounds.height > 2);
    const left = (bounds.width - column_gap) / 2;
    const top = (bounds.height - row_gap) / 2;
    return .{
        .first = .{ .x = bounds.x, .y = bounds.y, .width = left, .height = top },
        .second = .{ .x = bounds.x + left + column_gap, .y = bounds.y, .width = bounds.width - left - column_gap, .height = top },
        .third = .{ .x = bounds.x, .y = bounds.y + top + row_gap, .width = left, .height = bounds.height - top - row_gap },
        .fourth = .{ .x = bounds.x + left + column_gap, .y = bounds.y + top + row_gap, .width = bounds.width - left - column_gap, .height = bounds.height - top - row_gap },
    };
}

fn editorLayout(bounds: tui.render.Rect) PageLayout {
    const gap: u16 = @intFromBool(bounds.width > 2);
    const left = (bounds.width - gap) * 2 / 3;
    return .{
        .first = .{ .x = bounds.x, .y = bounds.y, .width = left, .height = bounds.height },
        .second = .{ .x = bounds.x + left + gap, .y = bounds.y, .width = bounds.width - left - gap, .height = bounds.height },
    };
}

fn terminalLayout(bounds: tui.render.Rect) PageLayout {
    const column_gap: u16 = @intFromBool(bounds.width > 2);
    const row_gap: u16 = @intFromBool(bounds.height > 2);
    const top = (bounds.height - row_gap) / 2;
    const left = (bounds.width - column_gap) / 2;
    return .{
        .first = .{ .x = bounds.x, .y = bounds.y, .width = left, .height = top },
        .second = .{ .x = bounds.x + left + column_gap, .y = bounds.y, .width = bounds.width - left - column_gap, .height = top },
        .third = .{ .x = bounds.x, .y = bounds.y + top + row_gap, .width = bounds.width, .height = bounds.height - top - row_gap },
    };
}

fn tableColumns(width: u16) [4]tui.widget.Column {
    const first = @max(@as(u16, 8), width * 35 / 100);
    const second = @max(@as(u16, 7), width * 22 / 100);
    const third = @max(@as(u16, 7), width * 20 / 100);
    return .{
        .{ .title = "MODULE", .width = @min(first, width) },
        .{ .title = "STATE", .width = @min(second, width -| first) },
        .{ .title = "MODE", .width = @min(third, width -| first -| second) },
        .{ .title = "DETAIL", .width = width -| first -| second -| third },
    };
}

fn colorDepthLabel(depth: tui.terminal.ColorDepth) []const u8 {
    return switch (depth) {
        .ansi16 => "16 colors",
        .indexed256 => "256 colors",
        .truecolor => "full color",
    };
}

fn imageLabel(protocol: tui.terminal.ImageProtocol) []const u8 {
    return if (protocol == .none) "text fallback" else "inline images";
}

fn availability(value: bool) []const u8 {
    return if (value) "available" else "unavailable";
}

fn byteOffsetAtColumn(value: []const u8, target_column: usize, width_profile: tui.text.WidthProfile) usize {
    var clusters = tui.text.GraphemeIterator.init(value) catch unreachable;
    var offset: usize = 0;
    var column: usize = 0;
    while (clusters.next()) |cluster| {
        if (column >= target_column) break;
        column += cluster.displayWidthAssumeValid(width_profile) catch unreachable;
        offset += cluster.bytes.len;
    }
    return offset;
}

fn durationNs(start: std.Io.Timestamp, end: std.Io.Timestamp) u64 {
    const elapsed = start.durationTo(end).nanoseconds;
    if (elapsed <= 0) return 0;
    return std.math.cast(u64, elapsed) orelse 0;
}

fn nsToMs(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

fn addDurations(update_ns: u64, draw_ns: u64, present_ns: u64) u64 {
    return update_ns +| draw_ns +| present_ns;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    const size = tui.terminal.querySize(io, stdout) catch tui.render.Size{ .width = 100, .height = 32 };

    var output_buffer: [4096]u8 = undefined;
    var file_writer = stdout.writer(io, &output_buffer);
    const output = &file_writer.interface;
    var session = try tui.terminal.Session.enter(stdin, output, .{ .mouse = true, .focus_events = true });
    defer session.leave(output) catch {};

    var renderer = try tui.render.Renderer.init(init.gpa, size, .{});
    defer renderer.deinit();
    var input_storage: [256]u8 = undefined;
    var editor_storage: [2048]u8 = undefined;
    const editor_initial =
        "tui.zig portfolio\n\n" ++
        "Edit this caller-owned buffer.\n" ++
        "Use Shift+Arrow for grapheme-safe selection.\n" ++
        "Click to place the caret; Shift+click extends selection.\n" ++
        "Unicode stays intact: café · 世界 · 👋\n\n" ++
        "Every update and frame remains bounded.";
    var editor_model = try tui.editor.Model.init(&editor_storage, editor_initial);
    var application = try DemoApp.init(&input_storage, &editor_model);
    application.layout(renderer.size());

    var read_buffer: [512]u8 = undefined;
    var timers: [1]tui.runtime.TimerSlot = undefined;
    var signals = try tui.runtime.SignalSource.init(io, .{});
    defer signals.deinit();
    var runtime = try tui.runtime.Posix.init(io, stdin, &read_buffer, &timers, .{
        .resize = .{ .file = stdout, .initial_size = size, .poll_interval = .fromMilliseconds(50) },
        .signals = &signals,
    });
    defer runtime.deinit();
    var negotiator = tui.terminal.CapabilityNegotiator.init(.{});
    try negotiator.writeQueries(output);

    var changed = true;
    var timer_armed = false;
    while (!application.quit) {
        if (changed) {
            const draw_start = std.Io.Clock.awake.now(io);
            var frame = renderer.frame();
            var root = frame.surface(tui.render.Rect.fromSize(renderer.size()));
            try application.draw(&root);
            const draw_end = std.Io.Clock.awake.now(io);
            const present_start = draw_end;
            const stats = try renderer.present(output, negotiator.capabilities);
            const present_end = std.Io.Clock.awake.now(io);
            application.metrics.draw_ns = durationNs(draw_start, draw_end);
            application.metrics.present_ns = durationNs(present_start, present_end);
            application.metrics.total_ns = addDurations(
                application.metrics.update_ns,
                application.metrics.draw_ns,
                application.metrics.present_ns,
            );
            application.metrics.frame = stats;
            changed = false;
        }

        var control: Control = .none;
        var sink = DemoSink{
            .io = io,
            .application = &application,
            .renderer = &renderer,
            .changed = &changed,
            .timer_armed = &timer_armed,
            .control = &control,
            .negotiator = &negotiator,
        };
        if (!timer_armed) {
            var deadline = runtime.now();
            deadline.raw.nanoseconds += 100 * std.time.ns_per_ms;
            _ = try runtime.setTimer(tick_timer_id, deadline);
            timer_armed = true;
        }
        try runtime.step(&sink);
        switch (control) {
            .none => {},
            .suspend_requested => {
                try session.leave(output);
                try signals.suspendProcess();
                try session.reenter(output);
                try negotiator.writeQueries(output);
                renderer.invalidateTerminal();
                changed = true;
            },
            .continued => {
                try negotiator.writeQueries(output);
                renderer.invalidateTerminal();
                changed = true;
            },
        }
    }
    try session.leave(output);
}

const DemoSink = struct {
    io: std.Io,
    application: *DemoApp,
    renderer: *tui.render.Renderer,
    changed: *bool,
    timer_armed: *bool,
    control: *Control,
    negotiator: *tui.terminal.CapabilityNegotiator,

    pub fn emit(self: *DemoSink, event: tui.runtime.Event) !void {
        switch (event) {
            .input => |value| {
                const start = std.Io.Clock.awake.now(self.io);
                self.negotiator.observe(value);
                self.application.setCapabilities(self.negotiator.capabilities);
                if (self.negotiator.observations.default_background) |background| {
                    if (self.application.setTerminalBackground(background)) self.changed.* = true;
                }
                if (self.application.handle(value) == .redraw) self.changed.* = true;
                self.application.metrics.update_ns = durationNs(start, std.Io.Clock.awake.now(self.io));
            },
            .resize => |new_size| {
                const start = std.Io.Clock.awake.now(self.io);
                try self.renderer.resize(new_size);
                self.application.layout(new_size);
                self.application.metrics.update_ns = durationNs(start, std.Io.Clock.awake.now(self.io));
                self.changed.* = true;
            },
            .timer => |timer| if (timer.id == tick_timer_id) {
                const start = std.Io.Clock.awake.now(self.io);
                self.timer_armed.* = false;
                if (self.application.tick() == .redraw) self.changed.* = true;
                self.application.metrics.update_ns = durationNs(start, std.Io.Clock.awake.now(self.io));
            },
            .signal => |signal| switch (signal) {
                .interrupt, .terminate => self.application.quit = true,
                .suspend_requested => self.control.* = .suspend_requested,
                .continued => self.control.* = .continued,
            },
            .eof => self.application.quit = true,
            .wakeup, .ready => {},
        }
    }
};
