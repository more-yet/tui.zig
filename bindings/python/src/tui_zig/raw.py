from __future__ import annotations

import ctypes as C
import os
from pathlib import Path
from typing import Any

OK = 0
ERROR_INVALID_ARGUMENT = -1
ERROR_OUT_OF_MEMORY = -2
ERROR_CAPACITY = -3
ERROR_INVALID_TEXT = -4
ERROR_BUFFER_TOO_SMALL = -5
ERROR_QUEUE_FULL = -6
ERROR_QUEUE_EMPTY = -7
ERROR_OUTPUT = -8
ERROR_PROVIDER = -9
ERROR_INVALID_STATE = -10
ERROR_UNSUPPORTED = -11

UPDATE_IGNORED = 0
UPDATE_HANDLED = 1
UPDATE_REDRAW = 2
UPDATE_RELAYOUT = 3

EVENT_KEY = 1
EVENT_TEXT = 2
EVENT_MOUSE = 3
EVENT_PASTE_START = 4
EVENT_PASTE_CHUNK = 5
EVENT_PASTE_END = 6
EVENT_FOCUS_IN = 7
EVENT_FOCUS_OUT = 8
EVENT_CURSOR_POSITION = 9
EVENT_TERMINAL_REPLY = 10
EVENT_MALFORMED = 11

KEY_CODEPOINT = 0
KEY_FUNCTIONAL = 1
KEY_ESCAPE = 2
KEY_ENTER = 3
KEY_TAB = 4
KEY_BACKSPACE = 5
KEY_UP = 6
KEY_DOWN = 7
KEY_LEFT = 8
KEY_RIGHT = 9
KEY_HOME = 10
KEY_END = 11
KEY_INSERT = 12
KEY_DELETE = 13
KEY_PAGE_UP = 14
KEY_PAGE_DOWN = 15
KEY_FUNCTION = 16
KEY_PRESS = 0
KEY_REPEAT = 1
KEY_RELEASE = 2

COLOR_DEFAULT = 0
COLOR_INDEXED = 1
COLOR_RGB = 2
COLOR_TRUECOLOR = 2
IMAGE_NONE = 0
PIXELS_RGB8 = 0
WIDTH_NARROW = 0
ALIGN_LEFT = 0
ALIGN_CENTER = 1
ALIGN_RIGHT = 2
ROW_HAS_CHILDREN = 1
ROW_EXPANDED = 2


class Version(C.Structure):
    _fields_ = [("major", C.c_uint32), ("minor", C.c_uint32), ("patch", C.c_uint32)]


class Bytes(C.Structure):
    _fields_ = [("ptr", C.POINTER(C.c_uint8)), ("len", C.c_uint64)]


class Size(C.Structure):
    _fields_ = [("width", C.c_uint16), ("height", C.c_uint16)]


class Point(C.Structure):
    _fields_ = [("x", C.c_uint16), ("y", C.c_uint16)]


class Rect(C.Structure):
    _fields_ = [
        ("x", C.c_uint16),
        ("y", C.c_uint16),
        ("width", C.c_uint16),
        ("height", C.c_uint16),
    ]


AllocateFn = C.CFUNCTYPE(C.c_void_p, C.c_void_p, C.c_uint64, C.c_uint64)
DeallocateFn = C.CFUNCTYPE(None, C.c_void_p, C.c_void_p, C.c_uint64, C.c_uint64)


class Allocator(C.Structure):
    _fields_ = [
        ("context", C.c_void_p),
        ("allocate", AllocateFn),
        ("deallocate", DeallocateFn),
    ]


class Color(C.Structure):
    _fields_ = [
        ("kind", C.c_int32),
        ("index", C.c_uint8),
        ("red", C.c_uint8),
        ("green", C.c_uint8),
        ("blue", C.c_uint8),
        ("reserved", C.c_uint8 * 3),
    ]


class Style(C.Structure):
    _fields_ = [
        ("foreground", Color),
        ("background", Color),
        ("attributes", C.c_uint8),
        ("reserved", C.c_uint8 * 3),
    ]


class Role(C.Structure):
    _fields_ = [
        ("normal", Style),
        ("focused", Style),
        ("disabled", Style),
        ("has_focused", C.c_uint8),
        ("has_disabled", C.c_uint8),
        ("reserved", C.c_uint8 * 2),
    ]


class Event(C.Structure):
    _fields_ = [
        ("kind", C.c_int32),
        ("key_kind", C.c_int32),
        ("key_value", C.c_uint32),
        ("modifiers", C.c_uint8),
        ("key_action", C.c_uint8),
        ("mouse_button", C.c_uint8),
        ("mouse_action", C.c_uint8),
        ("x", C.c_uint16),
        ("y", C.c_uint16),
        ("reply_kind", C.c_int32),
        ("reply_final", C.c_uint8),
        ("reserved", C.c_uint8 * 3),
        ("payload", Bytes),
    ]


class RendererConfig(C.Structure):
    _fields_ = [
        ("max_cells", C.c_uint64),
        ("grapheme_capacity", C.c_uint32),
        ("style_capacity", C.c_uint16),
        ("image_capacity", C.c_uint16),
        ("tile_width", C.c_uint8),
        ("tile_height", C.c_uint8),
        ("reserved", C.c_uint8 * 6),
    ]


class Capabilities(C.Structure):
    _fields_ = [
        ("color_depth", C.c_int32),
        ("image_protocol", C.c_int32),
        ("synchronized_output", C.c_uint8),
        ("background_color_erase", C.c_uint8),
        ("reserved", C.c_uint8 * 6),
    ]


class FrameStats(C.Structure):
    _fields_ = [
        ("bytes", C.c_uint64),
        ("cells_compared", C.c_uint32),
        ("cells_changed", C.c_uint32),
        ("runs", C.c_uint32),
        ("dirty_rows", C.c_uint16),
        ("full_repaint", C.c_uint8),
        ("reserved", C.c_uint8),
    ]


WriteFn = C.CFUNCTYPE(C.c_int32, C.c_void_p, C.POINTER(C.c_uint8), C.c_uint64)


class Output(C.Structure):
    _fields_ = [("context", C.c_void_p), ("write", WriteFn)]


class Image(C.Structure):
    _fields_ = [
        ("pixels", Bytes),
        ("width", C.c_uint32),
        ("height", C.c_uint32),
        ("format", C.c_int32),
    ]


class ImageOptions(C.Structure):
    _fields_ = [
        ("image_id", C.c_uint32),
        ("placement_id", C.c_uint32),
        ("background_red", C.c_uint8),
        ("background_green", C.c_uint8),
        ("background_blue", C.c_uint8),
        ("reserved", C.c_uint8),
    ]


class TextDesc(C.Structure):
    _fields_ = [
        ("text", Bytes),
        ("role", Role),
        ("enabled", C.c_uint8),
        ("focused", C.c_uint8),
        ("width_profile", C.c_uint8),
        ("alignment", C.c_uint8),
    ]


class PanelDesc(C.Structure):
    _fields_ = [
        ("title", Bytes),
        ("border_role", Role),
        ("title_role", Role),
        ("enabled", C.c_uint8),
        ("focused", C.c_uint8),
        ("reserved", C.c_uint8 * 2),
    ]


class GaugeDesc(C.Structure):
    _fields_ = [
        ("value", C.c_uint64),
        ("total", C.c_uint64),
        ("filled_role", Role),
        ("empty_role", Role),
        ("enabled", C.c_uint8),
        ("reserved", C.c_uint8 * 7),
    ]


class ButtonState(C.Structure):
    _fields_ = [("activated", C.c_uint8), ("reserved", C.c_uint8 * 7)]


class CheckboxState(C.Structure):
    _fields_ = [("checked", C.c_uint8), ("reserved", C.c_uint8 * 7)]


class RadioState(C.Structure):
    _fields_ = [
        ("selected", C.c_uint32),
        ("has_selected", C.c_uint8),
        ("reserved", C.c_uint8 * 3),
    ]


class ControlDesc(C.Structure):
    _fields_ = [
        ("label", Bytes),
        ("role", Role),
        ("indicator_role", Role),
        ("enabled", C.c_uint8),
        ("focused", C.c_uint8),
        ("reserved", C.c_uint8 * 2),
    ]


class ScrollState(C.Structure):
    _fields_ = [
        ("top", C.c_uint64),
        ("selected", C.c_uint64),
        ("has_selected", C.c_uint8),
        ("reserved", C.c_uint8 * 7),
    ]


class ProviderRow(C.Structure):
    pass


RowsReadFn = C.CFUNCTYPE(
    C.c_int32, C.c_void_p, C.c_uint64, C.c_uint32, C.POINTER(ProviderRow)
)
ProviderRow._fields_ = [
    ("text", Bytes),
    ("cells", C.POINTER(Bytes)),
    ("cell_count", C.c_uint32),
    ("depth", C.c_uint32),
    ("status", C.c_int32),
    ("flags", C.c_uint32),
]


class RowsProvider(C.Structure):
    _fields_ = [("context", C.c_void_p), ("count", C.c_uint64), ("read", RowsReadFn)]


class Column(C.Structure):
    _fields_ = [("title", Bytes), ("width", C.c_uint16), ("reserved", C.c_uint16)]


class CollectionDesc(C.Structure):
    _fields_ = [
        ("row_role", Role),
        ("selected_role", Role),
        ("header_role", Role),
        ("enabled", C.c_uint8),
        ("focused", C.c_uint8),
        ("width_profile", C.c_uint8),
        ("reserved", C.c_uint8),
    ]


class MenuState(C.Structure):
    _fields_ = [
        ("scroll", ScrollState),
        ("activated", C.c_uint64),
        ("has_activated", C.c_uint8),
        ("reserved", C.c_uint8 * 7),
    ]


class TreeState(C.Structure):
    _fields_ = [
        ("scroll", ScrollState),
        ("toggled", C.c_uint64),
        ("activated", C.c_uint64),
        ("has_toggled", C.c_uint8),
        ("has_activated", C.c_uint8),
        ("reserved", C.c_uint8 * 6),
    ]


SamplesReadFn = C.CFUNCTYPE(
    C.c_int32, C.c_void_p, C.c_uint64, C.c_uint32, C.POINTER(C.c_double)
)


class SamplesProvider(C.Structure):
    _fields_ = [("context", C.c_void_p), ("count", C.c_uint64), ("read", SamplesReadFn)]


def _load_library() -> C.CDLL:
    configured = os.environ.get("TUI_LIBRARY")
    if configured:
        return C.CDLL(str(Path(configured).expanduser().resolve(strict=True)))
    name = "libtui.dylib" if os.uname().sysname == "Darwin" else "libtui.so.1"
    try:
        return C.CDLL(name)
    except OSError as load_error:
        root = Path(__file__).resolve().parents[4]
        fallback_name = (
            "libtui.dylib" if os.uname().sysname == "Darwin" else "libtui.so.1.0.0"
        )
        fallback = root / "zig-out" / "lib" / fallback_name
        try:
            return C.CDLL(str(fallback.resolve(strict=True)))
        except (OSError, FileNotFoundError):
            raise load_error


lib = _load_library()


def _fn(name: str, restype: object, *argtypes: object) -> Any:
    function = getattr(lib, name)
    function.restype = restype
    function.argtypes = list(argtypes)
    return function


P = C.c_void_p
tui_abi_version_v1 = _fn("tui_abi_version_v1", Version)
tui_renderer_create_v1 = _fn(
    "tui_renderer_create_v1",
    C.c_int32,
    C.POINTER(Allocator),
    Size,
    C.POINTER(RendererConfig),
    C.POINTER(P),
)
tui_renderer_destroy_v1 = _fn("tui_renderer_destroy_v1", None, P)
tui_renderer_resize_v1 = _fn("tui_renderer_resize_v1", C.c_int32, P, Size)
tui_renderer_begin_frame_v1 = _fn("tui_renderer_begin_frame_v1", C.c_int32, P)
tui_renderer_invalidate_terminal_v1 = _fn(
    "tui_renderer_invalidate_terminal_v1", None, P
)
tui_renderer_put_image_v1 = _fn(
    "tui_renderer_put_image_v1", C.c_int32, P, Rect, Image, ImageOptions
)
tui_renderer_present_v1 = _fn(
    "tui_renderer_present_v1", C.c_int32, P, Capabilities, Output, C.POINTER(FrameStats)
)
tui_label_draw_v1 = _fn("tui_label_draw_v1", C.c_int32, P, Rect, C.POINTER(TextDesc))
tui_paragraph_draw_v1 = _fn(
    "tui_paragraph_draw_v1", C.c_int32, P, Rect, C.POINTER(TextDesc)
)
tui_panel_draw_v1 = _fn("tui_panel_draw_v1", C.c_int32, P, Rect, C.POINTER(PanelDesc))
tui_panel_content_rect_v1 = _fn(
    "tui_panel_content_rect_v1", C.c_int32, Rect, C.POINTER(Rect)
)
tui_gauge_draw_v1 = _fn("tui_gauge_draw_v1", C.c_int32, P, Rect, C.POINTER(GaugeDesc))


def _control_functions(name: str, state: type[C.Structure]) -> tuple[Any, Any]:
    return (
        _fn(
            f"tui_{name}_draw_v1",
            C.c_int32,
            P,
            Rect,
            C.POINTER(ControlDesc),
            C.POINTER(state),
        ),
        _fn(
            f"tui_{name}_handle_v1",
            C.c_int32,
            C.POINTER(ControlDesc),
            C.POINTER(state),
            C.POINTER(Event),
            C.POINTER(C.c_int32),
        ),
    )


tui_button_draw_v1, tui_button_handle_v1 = _control_functions("button", ButtonState)
tui_checkbox_draw_v1, tui_checkbox_handle_v1 = _control_functions(
    "checkbox", CheckboxState
)
tui_radio_draw_v1 = _fn(
    "tui_radio_draw_v1",
    C.c_int32,
    P,
    Rect,
    C.POINTER(ControlDesc),
    C.POINTER(RadioState),
    C.c_uint32,
)
tui_radio_handle_v1 = _fn(
    "tui_radio_handle_v1",
    C.c_int32,
    C.POINTER(ControlDesc),
    C.POINTER(RadioState),
    C.c_uint32,
    C.POINTER(Event),
    C.POINTER(C.c_int32),
)


def _editor_functions(name: str) -> tuple[Any, Any, Any, Any, Any, Any, Any]:
    return (
        _fn(
            f"tui_{name}_create_v1",
            C.c_int32,
            C.POINTER(Allocator),
            C.c_uint64,
            Bytes,
            C.POINTER(P),
        ),
        _fn(f"tui_{name}_destroy_v1", None, P),
        _fn(f"tui_{name}_draw_v1", C.c_int32, P, P, Rect),
        _fn(
            f"tui_{name}_handle_v1",
            C.c_int32,
            P,
            C.POINTER(Event),
            C.POINTER(C.c_int32),
        ),
        _fn(f"tui_{name}_set_focus_v1", C.c_int32, P, C.c_uint8),
        _fn(
            f"tui_{name}_copy_value_v1",
            C.c_int32,
            P,
            C.POINTER(C.c_uint8),
            C.c_uint64,
            C.POINTER(C.c_uint64),
        ),
        _fn(f"tui_{name}_take_failure_v1", C.c_int32, P, C.POINTER(C.c_int32)),
    )


(
    tui_text_input_create_v1,
    tui_text_input_destroy_v1,
    tui_text_input_draw_v1,
    tui_text_input_handle_v1,
    tui_text_input_set_focus_v1,
    tui_text_input_copy_value_v1,
    tui_text_input_take_failure_v1,
) = _editor_functions("text_input")
(
    tui_text_area_create_v1,
    tui_text_area_destroy_v1,
    tui_text_area_draw_v1,
    tui_text_area_handle_v1,
    tui_text_area_set_focus_v1,
    tui_text_area_copy_value_v1,
    tui_text_area_take_failure_v1,
) = _editor_functions("text_area")
tui_text_input_set_selection_v1 = _fn(
    "tui_text_input_set_selection_v1", C.c_int32, P, C.c_uint64, C.c_uint64
)
tui_text_input_replace_selection_v1 = _fn(
    "tui_text_input_replace_selection_v1", C.c_int32, P, Bytes
)
tui_text_area_layout_v1 = _fn("tui_text_area_layout_v1", C.c_int32, P, Size)
tui_text_area_set_soft_wrap_v1 = _fn(
    "tui_text_area_set_soft_wrap_v1", C.c_int32, P, C.c_uint8
)


def _collection_functions(name: str, state: type[C.Structure]) -> tuple[Any, Any]:
    return (
        _fn(
            f"tui_{name}_draw_v1",
            C.c_int32,
            P,
            Rect,
            C.POINTER(CollectionDesc),
            C.POINTER(state),
            C.POINTER(RowsProvider),
        ),
        _fn(
            f"tui_{name}_handle_v1",
            C.c_int32,
            Rect,
            C.POINTER(state),
            C.POINTER(RowsProvider),
            C.POINTER(Event),
            C.POINTER(C.c_int32),
        ),
    )


tui_scrollback_draw_v1, tui_scrollback_handle_v1 = _collection_functions(
    "scrollback", ScrollState
)
tui_list_draw_v1, tui_list_handle_v1 = _collection_functions("list", ScrollState)
tui_tree_draw_v1, tui_tree_handle_v1 = _collection_functions("tree", TreeState)
tui_task_list_draw_v1, tui_task_list_handle_v1 = _collection_functions(
    "task_list", MenuState
)
tui_menu_draw_v1, tui_menu_handle_v1 = _collection_functions("menu", MenuState)
tui_table_draw_v1 = _fn(
    "tui_table_draw_v1",
    C.c_int32,
    P,
    Rect,
    C.POINTER(CollectionDesc),
    C.POINTER(ScrollState),
    C.POINTER(RowsProvider),
    C.POINTER(Column),
    C.c_uint32,
)
tui_table_handle_v1 = _fn(
    "tui_table_handle_v1",
    C.c_int32,
    Rect,
    C.POINTER(ScrollState),
    C.POINTER(RowsProvider),
    C.POINTER(Event),
    C.POINTER(C.c_int32),
)

tui_line_chart_create_v1 = _fn(
    "tui_line_chart_create_v1",
    C.c_int32,
    C.POINTER(Allocator),
    C.c_uint64,
    C.c_uint64,
    C.POINTER(P),
)
tui_line_chart_destroy_v1 = _fn("tui_line_chart_destroy_v1", None, P)
tui_line_chart_draw_v1 = _fn(
    "tui_line_chart_draw_v1", C.c_int32, P, P, Rect, C.POINTER(SamplesProvider), Role
)
tui_event_queue_create_v1 = _fn(
    "tui_event_queue_create_v1",
    C.c_int32,
    C.POINTER(Allocator),
    C.c_uint64,
    C.POINTER(P),
)
tui_event_queue_destroy_v1 = _fn("tui_event_queue_destroy_v1", None, P)
tui_event_queue_try_push_v1 = _fn(
    "tui_event_queue_try_push_v1", C.c_int32, P, C.POINTER(Event)
)
tui_event_queue_try_pop_v1 = _fn(
    "tui_event_queue_try_pop_v1",
    C.c_int32,
    P,
    C.POINTER(C.c_uint8),
    C.c_uint64,
    C.POINTER(Event),
)
tui_parser_create_v1 = _fn(
    "tui_parser_create_v1", C.c_int32, C.POINTER(Allocator), C.POINTER(P)
)
tui_parser_destroy_v1 = _fn("tui_parser_destroy_v1", None, P)
tui_parser_feed_v1 = _fn("tui_parser_feed_v1", C.c_int32, P, Bytes, P)
tui_parser_finish_v1 = _fn("tui_parser_finish_v1", C.c_int32, P, P)
tui_parser_abort_v1 = _fn("tui_parser_abort_v1", C.c_int32, P, P)
