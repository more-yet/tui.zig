from __future__ import annotations

import ctypes as C
from collections.abc import Callable

from . import raw


class TuiError(RuntimeError):
    def __init__(self, result: int):
        self.result = result
        super().__init__(f"tui error {result}")


def check(result: int) -> None:
    if result != raw.OK:
        raise TuiError(result)


_libc = C.CDLL(None)
_libc.posix_memalign.argtypes = [C.POINTER(C.c_void_p), C.c_size_t, C.c_size_t]
_libc.posix_memalign.restype = C.c_int
_libc.free.argtypes = [C.c_void_p]


@raw.AllocateFn
def _allocate(_context: int, size: int, alignment: int) -> int | None:
    try:
        memory = C.c_void_p()
        alignment = max(alignment, C.sizeof(C.c_void_p))
        if _libc.posix_memalign(C.byref(memory), alignment, max(size, 1)) != 0:
            return None
        return memory.value
    except BaseException:  # noqa: BLE001
        return None


@raw.DeallocateFn
def _deallocate(_context: int, memory: int, _size: int, _alignment: int) -> None:
    try:
        _libc.free(memory)
    except BaseException:  # noqa: BLE001
        return


ALLOCATOR = raw.Allocator(None, _allocate, _deallocate)


def _unsigned(value: int, maximum: int, name: str) -> int:
    if not isinstance(value, int) or not 0 <= value <= maximum:
        raise ValueError(f"{name} must be between 0 and {maximum}")
    return value


def encoded(value: str | bytes) -> tuple[raw.Bytes, object]:
    data = value.encode() if isinstance(value, str) else value
    storage = (C.c_uint8 * len(data)).from_buffer_copy(data)
    return raw.Bytes(C.cast(storage, C.POINTER(C.c_uint8)), len(data)), storage


class Handle:
    _destroy: Callable[[C.c_void_p], None]

    def __init__(self, pointer: C.c_void_p):
        self.pointer = pointer

    def close(self) -> None:
        pointer = self.pointer
        self.pointer = C.c_void_p()
        if pointer:
            self._destroy(pointer)

    def __copy__(self):
        raise TypeError("tui handles cannot be copied")

    def __deepcopy__(self, _memo):
        raise TypeError("tui handles cannot be copied")

    def __enter__(self):
        return self

    def __exit__(self, _kind, _value, _traceback):
        self.close()


class Renderer(Handle):
    _destroy = raw.tui_renderer_destroy_v1

    def __init__(self, width: int, height: int):
        width = _unsigned(width, (1 << 16) - 1, "width")
        height = _unsigned(height, (1 << 16) - 1, "height")
        pointer = C.c_void_p()
        check(
            raw.tui_renderer_create_v1(
                C.byref(ALLOCATOR), raw.Size(width, height), None, C.byref(pointer)
            )
        )
        super().__init__(pointer)


class TextInput(Handle):
    _destroy = raw.tui_text_input_destroy_v1

    def __init__(self, capacity: int, initial: str = ""):
        capacity = _unsigned(capacity, (1 << 64) - 1, "capacity")
        pointer = C.c_void_p()
        value, _storage = encoded(initial)
        check(
            raw.tui_text_input_create_v1(
                C.byref(ALLOCATOR), capacity, value, C.byref(pointer)
            )
        )
        super().__init__(pointer)


class TextArea(Handle):
    _destroy = raw.tui_text_area_destroy_v1

    def __init__(self, capacity: int, initial: str = ""):
        capacity = _unsigned(capacity, (1 << 64) - 1, "capacity")
        pointer = C.c_void_p()
        value, _storage = encoded(initial)
        check(
            raw.tui_text_area_create_v1(
                C.byref(ALLOCATOR), capacity, value, C.byref(pointer)
            )
        )
        super().__init__(pointer)


class LineChart(Handle):
    _destroy = raw.tui_line_chart_destroy_v1

    def __init__(self, sample_capacity: int, cell_capacity: int):
        sample_capacity = _unsigned(sample_capacity, (1 << 64) - 1, "sample_capacity")
        cell_capacity = _unsigned(cell_capacity, (1 << 64) - 1, "cell_capacity")
        pointer = C.c_void_p()
        check(
            raw.tui_line_chart_create_v1(
                C.byref(ALLOCATOR), sample_capacity, cell_capacity, C.byref(pointer)
            )
        )
        super().__init__(pointer)


class EventQueue(Handle):
    _destroy = raw.tui_event_queue_destroy_v1

    def __init__(self, capacity: int):
        capacity = _unsigned(capacity, (1 << 64) - 1, "capacity")
        pointer = C.c_void_p()
        check(
            raw.tui_event_queue_create_v1(
                C.byref(ALLOCATOR), capacity, C.byref(pointer)
            )
        )
        super().__init__(pointer)


class Parser(Handle):
    _destroy = raw.tui_parser_destroy_v1

    def __init__(self):
        pointer = C.c_void_p()
        check(raw.tui_parser_create_v1(C.byref(ALLOCATOR), C.byref(pointer)))
        super().__init__(pointer)
