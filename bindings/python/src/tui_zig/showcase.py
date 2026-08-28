from __future__ import annotations

import ctypes as C
import os
import sys
import termios
import tty

from . import raw
from .api import (
    EventQueue,
    LineChart,
    Parser,
    Renderer,
    TextArea,
    TextInput,
    check,
    encoded,
)

WIDTH = 80
HEIGHT = 24
ROW_LABELS = ("renderer", "controls", "editors", "providers", "parser")
ROW_STATES = ("ready", "checked", "editing", "streaming", "bounded")
CHART_SAMPLES = (1.0, 2.5, 1.5, 4.0, 3.0, 5.5, 4.5, 7.0, 6.0, 8.0, 7.0, 9.0)
IMAGE_PIXELS = bytes(
    (
        230,
        70,
        80,
        245,
        155,
        55,
        55,
        190,
        145,
        60,
        135,
        225,
        245,
        155,
        55,
        55,
        190,
        145,
        60,
        135,
        225,
        230,
        70,
        80,
        55,
        190,
        145,
        60,
        135,
        225,
        230,
        70,
        80,
        245,
        155,
        55,
        60,
        135,
        225,
        230,
        70,
        80,
        245,
        155,
        55,
        55,
        190,
        145,
    )
)


def rect(x: int, y: int, width: int, height: int) -> raw.Rect:
    return raw.Rect(x, y, width, height)


def indexed(value: int) -> raw.Color:
    return raw.Color(raw.COLOR_INDEXED, value, 0, 0, 0, (C.c_uint8 * 3)())


def style(foreground: int, background: int, attributes: int = 0) -> raw.Style:
    return raw.Style(
        indexed(foreground), indexed(background), attributes, (C.c_uint8 * 3)()
    )


def role(foreground: int, background: int) -> raw.Role:
    return raw.Role(
        style(foreground, background),
        style(0, 14, 1),
        style(8, background),
        1,
        1,
        (C.c_uint8 * 2)(),
    )


def text(value: str, alignment: int = raw.ALIGN_LEFT) -> tuple[raw.TextDesc, object]:
    value_bytes, storage = encoded(value)
    return (
        raw.TextDesc(value_bytes, role(15, 0), 1, 0, raw.WIDTH_NARROW, alignment),
        storage,
    )


def control(value: str, focused: bool = True) -> tuple[raw.ControlDesc, object]:
    value_bytes, storage = encoded(value)
    return (
        raw.ControlDesc(
            value_bytes,
            role(15, 0),
            role(10, 0),
            1,
            int(focused),
            (C.c_uint8 * 2)(),
        ),
        storage,
    )


def collection() -> raw.CollectionDesc:
    return raw.CollectionDesc(
        role(15, 0),
        role(0, 14),
        role(11, 0),
        1,
        1,
        raw.WIDTH_NARROW,
        0,
    )


class Rows:
    def __init__(self):
        self.storage: list[object] = []
        self.cells = ((raw.Bytes * 2) * len(ROW_LABELS))()

        @raw.RowsReadFn
        def read(_context, first, count, rows):
            try:
                if first > len(ROW_LABELS) or count > len(ROW_LABELS) - first:
                    return raw.ERROR_PROVIDER
                self.storage.clear()
                for offset in range(count):
                    index = first + offset
                    label, label_storage = encoded(ROW_LABELS[index])
                    state, state_storage = encoded(ROW_STATES[index])
                    self.storage.extend((label_storage, state_storage))
                    self.cells[index][0] = label
                    self.cells[index][1] = state
                    rows[offset] = raw.ProviderRow(
                        label,
                        C.cast(self.cells[index], C.POINTER(raw.Bytes)),
                        2,
                        int(index in (1, 2)),
                        index % 5,
                        raw.ROW_HAS_CHILDREN | raw.ROW_EXPANDED if index == 0 else 0,
                    )
                return raw.OK
            except BaseException:  # noqa: BLE001
                return raw.ERROR_PROVIDER

        self.read = read
        self.provider = raw.RowsProvider(None, len(ROW_LABELS), read)


class App:
    def __init__(self):
        version = raw.tui_abi_version_v1()
        if version.major != 1:
            raise RuntimeError(
                f"unsupported tui ABI {version.major}.{version.minor}.{version.patch}"
            )
        created = []
        try:
            self.renderer = Renderer(WIDTH, HEIGHT)
            created.append(self.renderer)
            self.input = TextInput(128, "edit me")
            created.append(self.input)
            self.area = TextArea(1024, "Unicode: e\u0301 and 世界\nSoft-wrapped editor")
            created.append(self.area)
            self.chart = LineChart(64, WIDTH * HEIGHT)
            created.append(self.chart)
            self.queue = EventQueue(64)
            created.append(self.queue)
            self.parser = Parser()
            created.append(self.parser)
        except BaseException:
            for resource in reversed(created):
                resource.close()
            raise
        self.frame_images: list[object] = []
        self.button = raw.ButtonState()
        self.checkbox = raw.CheckboxState()
        self.radio = raw.RadioState()
        self.scroll = raw.ScrollState()
        self.menu = raw.MenuState()
        self.tree = raw.TreeState()
        self.page = 0

    def close(self) -> None:
        self.parser.close()
        self.queue.close()
        self.chart.close()
        self.area.close()
        self.input.close()
        self.renderer.close()
        self.frame_images.clear()

    def pop(self) -> raw.Event:
        payload = (C.c_uint8 * 256)()
        event = raw.Event()
        check(
            raw.tui_event_queue_try_pop_v1(
                self.queue.pointer, payload, len(payload), C.byref(event)
            )
        )
        return event

    def exercise(self) -> None:
        rows = Rows()
        event = raw.Event()
        event.kind = raw.EVENT_KEY
        event.key_kind = raw.KEY_ENTER
        event.key_action = raw.KEY_PRESS
        update = C.c_int32(raw.UPDATE_IGNORED)
        button, _button_storage = control("Activate")
        checkbox, _checkbox_storage = control("Checked")
        radio, _radio_storage = control("Choice two")
        check(
            raw.tui_button_handle_v1(
                C.byref(button), C.byref(self.button), C.byref(event), C.byref(update)
            )
        )
        check(
            raw.tui_checkbox_handle_v1(
                C.byref(checkbox),
                C.byref(self.checkbox),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_radio_handle_v1(
                C.byref(radio), C.byref(self.radio), 2, C.byref(event), C.byref(update)
            )
        )

        event.key_kind = raw.KEY_DOWN
        check(
            raw.tui_scrollback_handle_v1(
                rect(2, 2, 24, 4),
                C.byref(self.scroll),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_list_handle_v1(
                rect(2, 7, 24, 4),
                C.byref(self.scroll),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_table_handle_v1(
                rect(28, 2, 28, 7),
                C.byref(self.scroll),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_tree_handle_v1(
                rect(2, 12, 24, 5),
                C.byref(self.tree),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_task_list_handle_v1(
                rect(28, 10, 28, 6),
                C.byref(self.menu),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_menu_handle_v1(
                rect(2, 18, 24, 4),
                C.byref(self.menu),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )

        check(raw.tui_text_input_set_focus_v1(self.input.pointer, 1))
        check(raw.tui_text_input_set_selection_v1(self.input.pointer, 0, 4))
        replacement, _replacement_storage = encoded("type")
        check(raw.tui_text_input_replace_selection_v1(self.input.pointer, replacement))
        event.kind = raw.EVENT_TEXT
        event.payload, _event_storage = encoded("!")
        check(
            raw.tui_text_input_handle_v1(
                self.input.pointer, C.byref(event), C.byref(update)
            )
        )
        value = (C.c_uint8 * 1024)()
        needed = C.c_uint64()
        failure = C.c_int32()
        check(
            raw.tui_text_input_copy_value_v1(
                self.input.pointer, value, len(value), C.byref(needed)
            )
        )
        check(raw.tui_text_input_take_failure_v1(self.input.pointer, C.byref(failure)))

        check(raw.tui_text_area_set_focus_v1(self.area.pointer, 1))
        check(raw.tui_text_area_set_soft_wrap_v1(self.area.pointer, 1))
        check(raw.tui_text_area_layout_v1(self.area.pointer, raw.Size(48, 8)))
        check(
            raw.tui_text_area_handle_v1(
                self.area.pointer, C.byref(event), C.byref(update)
            )
        )
        check(
            raw.tui_text_area_copy_value_v1(
                self.area.pointer, value, len(value), C.byref(needed)
            )
        )
        check(raw.tui_text_area_take_failure_v1(self.area.pointer, C.byref(failure)))

        event.payload, _queued_storage = encoded("queued")
        check(raw.tui_event_queue_try_push_v1(self.queue.pointer, C.byref(event)))
        self.pop()
        parser_input, _parser_storage = encoded("p")
        check(
            raw.tui_parser_feed_v1(
                self.parser.pointer, parser_input, self.queue.pointer
            )
        )
        self.pop()
        check(raw.tui_parser_finish_v1(self.parser.pointer, self.queue.pointer))
        check(raw.tui_parser_abort_v1(self.parser.pointer, self.queue.pointer))
        raw.tui_renderer_invalidate_terminal_v1(self.renderer.pointer)

    def draw_frame(self, width: int, height: int, output: bytearray) -> None:
        check(
            raw.tui_renderer_resize_v1(self.renderer.pointer, raw.Size(width, height))
        )
        check(raw.tui_renderer_begin_frame_v1(self.renderer.pointer))
        title, _title_storage = encoded(
            " tui.zig C ABI: controls " if self.page == 0 else " tui.zig C ABI: data "
        )
        panel = raw.PanelDesc(
            title,
            role(14, 0),
            role(11, 0),
            1,
            1,
            (C.c_uint8 * 2)(),
        )
        bounds = rect(0, 0, width, height)
        check(raw.tui_panel_draw_v1(self.renderer.pointer, bounds, C.byref(panel)))
        content = raw.Rect()
        check(raw.tui_panel_content_rect_v1(bounds, C.byref(content)))
        if width < WIDTH or height < HEIGHT:
            description, _description_storage = text(
                "The showcase needs an 80x24 terminal.", raw.ALIGN_CENTER
            )
            check(
                raw.tui_paragraph_draw_v1(
                    self.renderer.pointer, content, C.byref(description)
                )
            )
        elif self.page == 0:
            self.draw_controls()
        else:
            self.draw_data()

        @raw.WriteFn
        def write_output(_context, data, length):
            try:
                output.extend(C.string_at(data, length))
                return raw.OK
            except BaseException:  # noqa: BLE001
                return raw.ERROR_OUTPUT

        capabilities = raw.Capabilities(
            raw.COLOR_TRUECOLOR,
            raw.IMAGE_NONE,
            1,
            0,
            (C.c_uint8 * 6)(),
        )
        stats = raw.FrameStats()
        check(
            raw.tui_renderer_present_v1(
                self.renderer.pointer,
                capabilities,
                raw.Output(None, write_output),
                C.byref(stats),
            )
        )
        self.frame_images.clear()

    def draw_controls(self) -> None:
        paragraph, _paragraph_storage = text(
            "All bindings call the same versioned C ABI. Tab changes page; q or Escape quits."
        )
        check(
            raw.tui_paragraph_draw_v1(
                self.renderer.pointer, rect(2, 2, 76, 2), C.byref(paragraph)
            )
        )
        label, _label_storage = text("Unicode 17: e\u0301  世界  🦀")
        check(
            raw.tui_label_draw_v1(
                self.renderer.pointer, rect(2, 5, 44, 1), C.byref(label)
            )
        )
        gauge = raw.GaugeDesc(
            73,
            100,
            role(0, 10),
            role(8, 0),
            1,
            (C.c_uint8 * 7)(),
        )
        check(
            raw.tui_gauge_draw_v1(
                self.renderer.pointer, rect(2, 7, 44, 1), C.byref(gauge)
            )
        )
        button, _button_storage = control("Activate")
        checkbox, _checkbox_storage = control("Checked")
        radio, _radio_storage = control("Choice two")
        check(
            raw.tui_button_draw_v1(
                self.renderer.pointer,
                rect(2, 10, 18, 1),
                C.byref(button),
                C.byref(self.button),
            )
        )
        check(
            raw.tui_checkbox_draw_v1(
                self.renderer.pointer,
                rect(2, 12, 18, 1),
                C.byref(checkbox),
                C.byref(self.checkbox),
            )
        )
        check(
            raw.tui_radio_draw_v1(
                self.renderer.pointer,
                rect(2, 14, 18, 1),
                C.byref(radio),
                C.byref(self.radio),
                2,
            )
        )
        check(
            raw.tui_text_input_draw_v1(
                self.input.pointer, self.renderer.pointer, rect(28, 10, 48, 1)
            )
        )
        check(raw.tui_text_area_layout_v1(self.area.pointer, raw.Size(48, 8)))
        check(
            raw.tui_text_area_draw_v1(
                self.area.pointer, self.renderer.pointer, rect(28, 13, 48, 8)
            )
        )

    def draw_data(self) -> None:
        rows = Rows()
        description = collection()
        check(
            raw.tui_scrollback_draw_v1(
                self.renderer.pointer,
                rect(2, 2, 24, 4),
                C.byref(description),
                C.byref(self.scroll),
                C.byref(rows.provider),
            )
        )
        check(
            raw.tui_list_draw_v1(
                self.renderer.pointer,
                rect(2, 7, 24, 4),
                C.byref(description),
                C.byref(self.scroll),
                C.byref(rows.provider),
            )
        )
        check(
            raw.tui_tree_draw_v1(
                self.renderer.pointer,
                rect(2, 12, 24, 5),
                C.byref(description),
                C.byref(self.tree),
                C.byref(rows.provider),
            )
        )
        check(
            raw.tui_menu_draw_v1(
                self.renderer.pointer,
                rect(2, 18, 24, 4),
                C.byref(description),
                C.byref(self.menu),
                C.byref(rows.provider),
            )
        )
        component, _component_storage = encoded("component")
        state, _state_storage = encoded("state")
        columns = (raw.Column * 2)(
            raw.Column(component, 14, 0), raw.Column(state, 11, 0)
        )
        check(
            raw.tui_table_draw_v1(
                self.renderer.pointer,
                rect(28, 2, 28, 7),
                C.byref(description),
                C.byref(self.scroll),
                C.byref(rows.provider),
                columns,
                2,
            )
        )
        check(
            raw.tui_task_list_draw_v1(
                self.renderer.pointer,
                rect(28, 10, 28, 6),
                C.byref(description),
                C.byref(self.menu),
                C.byref(rows.provider),
            )
        )

        @raw.SamplesReadFn
        def read_samples(_context, first, count, samples):
            try:
                if first > len(CHART_SAMPLES) or count > len(CHART_SAMPLES) - first:
                    return raw.ERROR_PROVIDER
                for offset in range(count):
                    samples[offset] = CHART_SAMPLES[first + offset]
                return raw.OK
            except BaseException:  # noqa: BLE001
                return raw.ERROR_PROVIDER

        samples = raw.SamplesProvider(None, len(CHART_SAMPLES), read_samples)
        check(
            raw.tui_line_chart_draw_v1(
                self.chart.pointer,
                self.renderer.pointer,
                rect(58, 2, 20, 10),
                C.byref(samples),
                role(10, 0),
            )
        )
        pixels, _pixels_storage = encoded(IMAGE_PIXELS)
        image = raw.Image(pixels, 4, 4, raw.PIXELS_RGB8)
        options = raw.ImageOptions(7, 1, 0, 0, 0, 0)
        self.frame_images.append(_pixels_storage)
        try:
            check(
                raw.tui_renderer_put_image_v1(
                    self.renderer.pointer, rect(58, 14, 4, 4), image, options
                )
            )
        except BaseException:
            self.frame_images.pop()
            raise
        diagnostics, _diagnostics_storage = text("parser + SPSC queue\nRGB image 4x4")
        check(
            raw.tui_paragraph_draw_v1(
                self.renderer.pointer, rect(64, 14, 14, 4), C.byref(diagnostics)
            )
        )

    def dispatch(self, event: raw.Event) -> bool:
        if event.kind == raw.EVENT_KEY and event.key_action != raw.KEY_RELEASE:
            if event.key_kind == raw.KEY_ESCAPE or (
                event.key_kind == raw.KEY_CODEPOINT and event.key_value == ord("q")
            ):
                return False
            if event.key_kind == raw.KEY_TAB:
                self.page ^= 1
                return True
        rows = Rows()
        update = C.c_int32(raw.UPDATE_IGNORED)
        button, _button_storage = control("Activate")
        checkbox, _checkbox_storage = control("Checked")
        radio, _radio_storage = control("Choice two")
        check(
            raw.tui_button_handle_v1(
                C.byref(button), C.byref(self.button), C.byref(event), C.byref(update)
            )
        )
        check(
            raw.tui_checkbox_handle_v1(
                C.byref(checkbox),
                C.byref(self.checkbox),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_radio_handle_v1(
                C.byref(radio), C.byref(self.radio), 2, C.byref(event), C.byref(update)
            )
        )
        check(
            raw.tui_text_input_handle_v1(
                self.input.pointer, C.byref(event), C.byref(update)
            )
        )
        check(
            raw.tui_text_area_handle_v1(
                self.area.pointer, C.byref(event), C.byref(update)
            )
        )
        check(
            raw.tui_scrollback_handle_v1(
                rect(2, 2, 24, 4),
                C.byref(self.scroll),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_list_handle_v1(
                rect(2, 7, 24, 4),
                C.byref(self.scroll),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_table_handle_v1(
                rect(28, 2, 28, 7),
                C.byref(self.scroll),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_tree_handle_v1(
                rect(2, 12, 24, 5),
                C.byref(self.tree),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_task_list_handle_v1(
                rect(28, 10, 28, 6),
                C.byref(self.menu),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        check(
            raw.tui_menu_handle_v1(
                rect(2, 18, 24, 4),
                C.byref(self.menu),
                C.byref(rows.provider),
                C.byref(event),
                C.byref(update),
            )
        )
        return True


def render_headless(app: App) -> bytearray:
    output = bytearray()
    app.draw_frame(WIDTH, HEIGHT, output)
    app.page = 1
    raw.tui_renderer_invalidate_terminal_v1(app.renderer.pointer)
    app.draw_frame(WIDTH, HEIGHT, output)
    return output


def fnv1a(data: bytes | bytearray) -> int:
    result = 14_695_981_039_346_656_037
    for value in data:
        result = ((result ^ value) * 1_099_511_628_211) & ((1 << 64) - 1)
    return result


def run_interactive(app: App) -> None:
    input_fd = sys.stdin.fileno()
    output_fd = sys.stdout.fileno()
    if not os.isatty(input_fd) or not os.isatty(output_fd):
        raise RuntimeError("interactive mode requires a terminal")
    original = termios.tcgetattr(input_fd)
    try:
        tty.setraw(input_fd)
        attributes = termios.tcgetattr(input_fd)
        attributes[3] |= termios.ISIG
        termios.tcsetattr(input_fd, termios.TCSAFLUSH, attributes)
        sys.stdout.buffer.write(
            b"\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h"
        )
        sys.stdout.buffer.flush()
        while True:
            width, height = os.get_terminal_size(output_fd)
            output = bytearray()
            app.draw_frame(width, height, output)
            sys.stdout.buffer.write(output)
            sys.stdout.buffer.flush()
            input_data = os.read(input_fd, 64)
            if not input_data:
                return
            input_bytes, _input_storage = encoded(input_data)
            check(
                raw.tui_parser_feed_v1(
                    app.parser.pointer, input_bytes, app.queue.pointer
                )
            )
            payload = (C.c_uint8 * 256)()
            while True:
                event = raw.Event()
                result = raw.tui_event_queue_try_pop_v1(
                    app.queue.pointer, payload, len(payload), C.byref(event)
                )
                if result == raw.ERROR_QUEUE_EMPTY:
                    break
                check(result)
                if not app.dispatch(event):
                    return
    finally:
        termios.tcsetattr(input_fd, termios.TCSAFLUSH, original)
        sys.stdout.buffer.write(
            b"\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l"
        )
        sys.stdout.buffer.flush()


def main() -> None:
    arguments = sys.argv[1:]
    if len(arguments) > 1 or (
        arguments and arguments[0] not in ("--headless", "--headless-hash")
    ):
        raise SystemExit(
            "usage: python -m tui_zig.showcase [--headless|--headless-hash]"
        )
    app = App()
    try:
        app.exercise()
        if arguments:
            output = render_headless(app)
            if arguments[0] == "--headless":
                sys.stdout.buffer.write(output)
            else:
                print(f"{fnv1a(output):016x} {len(output)}")
        else:
            run_interactive(app)
    finally:
        app.close()


if __name__ == "__main__":
    main()
