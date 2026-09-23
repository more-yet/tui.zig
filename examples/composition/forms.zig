const tui = @import("tui");

const name_id: tui.focus.Id = 1;
const password_id: tui.focus.Id = 2;
const remember_id: tui.focus.Id = 3;
const submit_id: tui.focus.Id = 4;

pub const Status = enum {
    idle,
    missing_name,
    missing_password,
    submitted,
    input_error,
};

pub const App = struct {
    name: tui.widget.TextInput,
    password: tui.widget.TextInput,
    remember: tui.widget.Checkbox = .{ .label = "Remember name" },
    submit: tui.widget.Button = .{ .label = "Submit" },
    registry: tui.focus.Registry,
    focus: tui.focus.Manager = .{},
    status: Status = .idle,
    size: tui.render.Size = .{ .width = 0, .height = 0 },
    name_rect: tui.render.Rect = empty_rect,
    password_rect: tui.render.Rect = empty_rect,
    remember_rect: tui.render.Rect = empty_rect,
    submit_rect: tui.render.Rect = empty_rect,

    pub fn init(
        name_model: *tui.editor.Model,
        password_model: *tui.editor.Model,
        focus_storage: []tui.focus.Node,
    ) !App {
        var password = tui.widget.TextInput.init(password_model);
        password.display_mode = .masked;
        return .{
            .name = tui.widget.TextInput.init(name_model),
            .password = password,
            .registry = try tui.focus.Registry.init(focus_storage),
        };
    }

    pub fn layout(self: *App, size: tui.render.Size) !void {
        const previous_focus = self.focus.current();
        self.size = size;
        self.name_rect = rowRect(size, 1);
        self.password_rect = rowRect(size, 3);
        self.remember_rect = rowRect(size, 4);
        self.submit_rect = rowRect(size, 5);

        self.registry.reset();
        try self.addTarget(name_id, self.name_rect, self.name.enabled);
        try self.addTarget(password_id, self.password_rect, self.password.enabled);
        try self.addTarget(remember_id, self.remember_rect, self.remember.enabled);
        try self.addTarget(submit_id, self.submit_rect, self.submit.enabled);
        if (self.focus.current()) |id| {
            _ = self.focus.set(&self.registry, id) catch recovered: {
                _ = self.focus.clear();
                _ = self.focus.move(&self.registry, .next);
                break :recovered true;
            };
        } else {
            _ = self.focus.move(&self.registry, .next);
        }
        self.abortPasteOnFocusChange(previous_focus, self.focus.current());
        self.syncFocus();
    }

    pub fn draw(self: *App, surface: *tui.render.Surface) !void {
        try surface.fill(tui.render.Rect.fromSize(surface.size()), .{});
        try drawLabel(surface, 0, "Name");
        try self.drawControl(surface, self.name_rect, &self.name);
        try drawLabel(surface, 2, "Password");
        try self.drawControl(surface, self.password_rect, &self.password);
        try self.drawControl(surface, self.remember_rect, &self.remember);
        try self.drawControl(surface, self.submit_rect, &self.submit);
        if (self.size.height > 6) {
            const label = tui.widget.Label{ .text = statusText(self.status) };
            var status_surface = surface.surface(rowRect(self.size, 6));
            try label.draw(&status_surface);
        }
    }

    pub fn handle(self: *App, event: tui.input.Event) tui.widget.Update {
        if (event == .key) {
            const key = event.key;
            if (key.action != .release and key.code == .tab and
                !key.modifiers.alt and !key.modifiers.control and !key.modifiers.super and
                !key.modifiers.hyper and !key.modifiers.meta)
            {
                const previous = self.focus.current();
                _ = self.focus.move(&self.registry, if (key.modifiers.shift) .previous else .next);
                self.abortPasteOnFocusChange(previous, self.focus.current());
                self.syncFocus();
                return .redraw;
            }
        }

        if (event == .mouse and event.mouse.action == .press and event.mouse.button == .left) {
            if (self.registry.hit(.{ .x = event.mouse.x, .y = event.mouse.y })) |id| {
                const previous = self.focus.current();
                _ = self.focus.set(&self.registry, id) catch return .ignored;
                self.abortPasteOnFocusChange(previous, self.focus.current());
                self.syncFocus();
            } else return .ignored;
        }

        const update = switch (self.focus.current() orelse return .ignored) {
            name_id => self.name.handle(event),
            password_id => self.password.handle(event),
            remember_id => self.remember.handle(event),
            submit_id => self.submit.handle(event),
            else => .ignored,
        };
        if (self.name.takeFailure() != null or self.password.takeFailure() != null) {
            self.status = .input_error;
            return .redraw;
        }
        if (self.submit.takeActivation()) {
            self.status = if (self.name.model.value().len == 0)
                .missing_name
            else if (self.password.model.value().len == 0)
                .missing_password
            else
                .submitted;
            return .redraw;
        }
        return update;
    }

    fn addTarget(self: *App, id: tui.focus.Id, rect: tui.render.Rect, enabled: bool) !void {
        if (!rect.isEmpty()) try self.registry.add(.{ .id = id, .rect = rect, .enabled = enabled });
    }

    fn abortPasteOnFocusChange(self: *App, previous: ?tui.focus.Id, current: ?tui.focus.Id) void {
        if (previous == current) return;
        if (previous == name_id) _ = self.name.handle(.malformed);
        if (previous == password_id) _ = self.password.handle(.malformed);
    }

    fn syncFocus(self: *App) void {
        const current = self.focus.current();
        self.name.focused = current == name_id;
        self.password.focused = current == password_id;
        self.remember.focused = current == remember_id;
        self.submit.focused = current == submit_id;
    }

    fn drawControl(self: *App, surface: *tui.render.Surface, rect: tui.render.Rect, control: anytype) !void {
        _ = self;
        if (rect.isEmpty()) return;
        var child = surface.surface(rect);
        try control.draw(&child);
    }
};

const empty_rect = tui.render.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };

fn rowRect(size: tui.render.Size, y: u16) tui.render.Rect {
    if (y >= size.height) return empty_rect;
    return .{ .x = 0, .y = y, .width = size.width, .height = 1 };
}

fn drawLabel(surface: *tui.render.Surface, y: u16, text: []const u8) !void {
    if (y >= surface.size().height) return;
    const label = tui.widget.Label{ .text = text };
    var child = surface.surface(.{ .x = 0, .y = y, .width = surface.size().width, .height = 1 });
    try label.draw(&child);
}

fn statusText(status: Status) []const u8 {
    return switch (status) {
        .idle => "",
        .missing_name => "Name is required.",
        .missing_password => "Password is required.",
        .submitted => "Submitted.",
        .input_error => "Input is full or invalid.",
    };
}
