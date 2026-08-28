import copy
import ctypes as C
import unittest

from tui_zig import EventQueue, LineChart, Parser, Renderer, TextArea, TextInput, raw
from tui_zig.showcase import App, fnv1a, render_headless


class ApiTests(unittest.TestCase):
    def test_abi_layouts(self):
        self.assertEqual(
            (1, 0), (raw.tui_abi_version_v1().major, raw.tui_abi_version_v1().minor)
        )
        self.assertEqual(24, C.sizeof(raw.Allocator))
        self.assertEqual(48, C.sizeof(raw.Event))
        self.assertEqual(88, C.sizeof(raw.Role))
        self.assertEqual(40, C.sizeof(raw.ProviderRow))

    def test_owned_handles(self):
        resources = (
            Renderer(80, 24),
            TextInput(64, "value"),
            TextArea(256, "first\nsecond"),
            LineChart(64, 80 * 24),
            EventQueue(64),
            Parser(),
        )
        for resource in reversed(resources):
            resource.close()
            resource.close()

    def test_handles_cannot_be_copied(self):
        renderer = Renderer(8, 2)
        try:
            with self.assertRaises(TypeError):
                copy.copy(renderer)
            with self.assertRaises(TypeError):
                copy.deepcopy(renderer)
        finally:
            renderer.close()

    def test_constructor_ranges(self):
        for width, height in ((-1, 1), (1 << 16, 1), (1, -1), (1, 1 << 16)):
            with self.assertRaises(ValueError):
                Renderer(width, height)
        with self.assertRaises(ValueError):
            TextInput(-1)
        with self.assertRaises(ValueError):
            TextArea(1 << 64)
        with self.assertRaises(ValueError):
            LineChart(-1, 1)
        with self.assertRaises(ValueError):
            EventQueue(1 << 64)

    def test_canonical_showcase(self):
        app = App()
        try:
            app.exercise()
            output = render_headless(app)
            self.assertEqual(8008, len(output))
            self.assertEqual(0x3EF79199AC9F474C, fnv1a(output))
        finally:
            app.close()


if __name__ == "__main__":
    unittest.main()
