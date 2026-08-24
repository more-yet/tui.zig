# tui.zig

[![CI](https://github.com/more-yet/tui.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/more-yet/tui.zig/actions/workflows/ci.yml)

`tui.zig` is a terminal UI library for Zig. It includes Unicode text,
incremental drawing, input parsing, layouts, widgets, terminal control,
subprocesses, and headless tests. Your app owns its state and chooses how to run
its event loop.

## Features

- Unicode 17 grapheme, width, line-break, and wrapping support
- Incremental rendering with styles, clipping, damage tracking, and cursors
- Streaming keyboard, mouse, paste, focus, and terminal reply parsing
- Layouts, widgets, grapheme-safe text selection, optional soft wrapping, focus,
  commands, themes, and overlays
- Optional bounded editor history, Unicode word actions, input history,
  completion, and search controllers
- Provider-backed lists, tables, trees, task lists, menus, and Braille charts
- Kitty, iTerm2, and Sixel images with a Unicode fallback
- Optional POSIX runtime with polling, timers, signals, and resize events
- POSIX subprocess and PTY support with explicit paths and arguments
- Headless rendering and input tests
- Clear storage limits so applications can control memory use
- A versioned C ABI with static and shared libraries

## Status

- Current version: `1.0.0-rc.1`
- Zig version: `0.16.0`
- Main platform: x86_64 Linux GNU
- Preview platforms: Linux musl and macOS targets
- Unicode data: `17.0.0`
- License: MIT with the upstream Unicode data license
- Security reports: [Security Policy](SECURITY.md)

## Compatibility

The documented declarations exported by the `tui` modules and the `_v1`
declarations in `tui.h` are the public APIs. During `1.x`, public types,
functions, ownership rules, named errors, and versioned C symbols stay
compatible. Breaking API changes start a new major version.

## Install

Add the package to `build.zig.zon`, for example with:

```sh
zig fetch --save=tui git+https://github.com/more-yet/tui.zig.git
```

Import its module from `build.zig`:

```zig
const tui_package = b.dependency("tui", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("tui", tui_package.module("tui"));
```

## C ABI

`zig build` installs `zig-out/include/tui.h`, `zig-out/lib/libtui.a`, and the
platform shared library. The v1 ABI covers the renderer, widgets, editors,
provider-backed collections, charts, input parser, and bounded event queue.

All exported symbols end in `_v1`. Owned objects use matching create/destroy
functions. UTF-8 and provider data are borrowed only for the documented call;
event queue pushes copy at most 256 payload bytes. Renderer image pixels remain
borrowed until successful presentation.
Language-specific bindings can be layered over this ABI and released independently.

```sh
zig build test-c-abi
```

## Headless App

Use the headless runner to exercise the same application callbacks in memory:

```zig
const std = @import("std");
const tui = @import("tui");

const App = struct {
    pub fn draw(_: *@This(), surface: *tui.render.Surface) !void {
        const label = tui.widget.Label{ .text = "hello" };
        try label.draw(surface);
    }
};

test "app" {
    var screen = try tui.testing.Headless.init(
        std.testing.allocator,
        .{ .width = 12, .height = 1 },
        .{},
    );
    defer screen.deinit();

    var application: App = .{};
    _ = try screen.render(&application, .{});
    try screen.expectRow(0, "hello");
}
```

## Examples

Run the basic terminal demo:

```sh
zig build demo
```

Run a command in the process console:

```sh
zig build process-console -- /bin/ls -la
```

Run the coding-assistant example:

```sh
zig build assistant-demo
```

Validate Kitty image presentation and removal in a compatible terminal:

```sh
zig build kitty-image-smoke
```

The examples use the same public modules and callbacks as normal applications.

## Modules

| Module | Contract |
| --- | --- |
| `tui.text` | Unicode text width, graphemes, line breaks, layout, and wrapping |
| `tui.render` | Incremental frames, clipped surfaces, styles, cursors, cells, images, and Braille canvases |
| `tui.terminal` | POSIX sessions, capabilities, images, links, clipboard, bell, and notifications |
| `tui.input` | Streaming terminal input parser and events |
| `tui.transport` | Fixed-size single-producer, single-consumer queue |
| `tui.runtime` | Optional POSIX polling, timers, signals, wakeups, and resize events |
| `tui.subprocess` | POSIX subprocesses and PTYs |
| `tui.scroll` | Line decoding, fixed-size line storage, and scrolling |
| `tui.editor` | Multiline text, cursors, selection, history, controllers, viewports, and optional soft wrapping |
| `tui.layout` | Insets, constraints, placement, flex splits, and grids |
| `tui.widget` | Labels, controls, editors, scrollback, provider collections, trees, tasks, and charts |
| `tui.focus` | Focus order, navigation, hit testing, and event routing |
| `tui.command` | Key bindings and key-sequence matching |
| `tui.app` | Layout, drawing, presentation, and quit scheduling |
| `tui.theme` | Semantic colors and styles |
| `tui.overlay` | Overlays, modals, and hit-test data |
| `tui.testing` | Headless rendering, input, and cell checks |

## How It Works

- Your application owns widget state, text buffers, focus data, and event-loop
  policy.
- The renderer keeps the desired frame and writes only changed terminal cells.
- The input parser accepts byte chunks and emits complete events.
- Callback data is borrowed for the callback. Copy data that you need later.
- The optional POSIX runtime connects input, timers, signals, resize events, and
  application file descriptors.
- The process API uses an explicit executable path and argument list.
- Headless tests use the same drawing and input paths as terminal applications.

## Safety

- Text, input, and terminal replies are checked for valid UTF-8, control
  characters, and size limits.
- Render cells, parser sequences, paste chunks, styles, glyphs, lines, and
  overlays use clear capacity limits.
- Capability profiles let the application choose terminal features such as
  links, clipboard writes, and notifications.
- Clipboard write policies include the application's maximum OSC 52 input size.
- `scroll.LineDecoder` turns process or network chunks into checked lines for
  scrollback.
- Editors validate text and grapheme boundaries before applying a replacement.
- Image capabilities are explicit; automatic Kitty probing is opt-in and
  unrecognized terminals use the bounded Unicode fallback.
- Process helpers manage PTY setup, process groups, descriptors, and child
  cleanup.

## Checks

```sh
zig build test
zig build test-c-abi
zig build unicode-check
zig build example
zig build bench
```

Benchmarks run in ReleaseFast mode and print JSON results.
