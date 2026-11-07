# tui.zig

[![CI](https://github.com/more-yet/tui.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/more-yet/tui.zig/actions/workflows/ci.yml)

Terminal UI primitives for **Zig 0.17.0**, **x86_64-linux-gnu**, and **Linux 5.9+**.
Unicode data is version **17.0.0**. The library has no package dependencies.

Applications own storage, widget state, layout, and I/O scheduling. The library
provides text layout, rendering, input parsing, editing, widgets, and terminal control.

## Run an application

```sh
zig build interactive
```

[`examples/interactive.zig`](examples/interactive.zig) is a complete editor with
nonblocking output, resize, signals, suspend/resume, undo, wrapping, and mouse
selection. Ctrl-Q quits, Ctrl-G suspends, Ctrl-L repaints, and F2 toggles wrapping.
The workspace groups the document, line numbers, live state, and editing/session
commands. Wide terminals show storage, selection, undo history, viewport, and
previous-frame work counts alongside the text. Narrow terminals keep the editor
and compact status; `>` in the gutter marks wrapped continuations.
Very wide terminals keep a bounded reading width instead of stretching text lines.
Its caller-owned buffers hold 4096 text bytes and a grid up to 512 × 256 cells.
`zig build` installs the executable as `zig-out/bin/tui-interactive`.

The example routes events and schedules presentation directly. Reuse only the
parts you need: `input.Parser` without the runtime, `Surface` without widgets,
`Model.applyAction()` without default bindings, or geometry without navigation.

## Add the library

```sh
zig fetch --save=tui git+https://github.com/more-yet/tui.zig.git
```

Pin the chosen revision in `build.zig.zon`, then import the module in your build:

```zig
const tui_package = b.dependency("tui", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("tui", tui_package.module("tui"));
```

## Draw and present

```zig
const tui = @import("tui");

pub fn drawField() !void {
    var text_storage: tui.editor.FixedStorage(256) = .{};
    var model = try tui.editor.Model.initSingleLine(text_storage.slices(), "Ada");
    var field = tui.widget.TextInput.init(&model);
    field.focused = true;

    var grid: tui.render.FixedRendererStorage(40, 4, 64, 16) = .{};
    var renderer = try tui.render.Renderer.init(grid.slices(), .{ .width = 40, .height = 4 });
    defer renderer.deinit();

    var surface = renderer.surface(.{ .x = 1, .y = 1, .width = 30, .height = 1 });
    try field.draw(&surface);
}
```

Drawing updates the renderer's grid. To send it to a terminal, call
`renderer.beginPresentation(capabilities)` and drive `renderer.presentStep(work_budget)`
with a budget of at least 2:

| Result | Next action |
| --- | --- |
| `.output` | Write the bytes, then acknowledge the accepted prefix with `consumePresentation(n)` |
| `.yielded` | Run other work before continuing presentation |
| `.cleared` | Replay any graphics, call `invalidateOutputState()`, and continue |
| `.complete` | Draw the next frame when application state changes |

Use one output owner and nonblocking writes. On `WouldBlock`, wait for write
readiness. Drain a partially written command before aborting presentation. After
resize, call `renderer.resize()`, recreate surfaces, and redraw.

For a native terminal caret, set the field's `paint_caret = false`, obtain
`field.caretPosition(surface.size())`, translate it with `surface.screenPoint()`,
and pass it to `renderer.setCursor()`. Set its `visible = false` when either query returns null.

## Editing and storage

Route input to the focused field with `field.handle(event)`. Use
`field.takeFailure()` to report rejected edits. For multiline editing, use
`editor.Model.init()` and `widget.TextArea`; call `area.layout(size)` before drawing
into a surface of that size.

For custom bindings, translate keys to `editor.Action` and call
`model.applyAction(action)` directly. Pass paste framing and malformed input to
`model.handle(event)`. Report `EventResult.failure` at the application boundary.
Cancel staged paste with `model.cancelPaste()` when disabling a field or changing
its input target; widget drawing and caret queries leave paste state alone.

For mouse editing, translate screen cells through your field bounds and viewport:

```zig
const position: tui.editor.Position = .{
    .row = model.viewport.top_row + local_y,
    .column = model.viewport.left_column + local_x,
};
const offset = model.offsetAtVisualPosition(position); // Grapheme-safe UTF-8 offset.
_ = try model.setVisualCursor(position, extend_selection);
```

Hit-testing uses absolute visual rows. Both cells of a wide grapheme map to its
start; columns past a row map to its end. Missing rows return null from the query
and `InvalidBoundary` from the setter. The setter keeps the clicked side of a
soft-wrap boundary. The application owns pointer capture, drag lifetime, focus,
and whether to extend selection.

- Keep borrowed storage fixed, disjoint, and alive for its owner.
- `editor.FixedStorage(n)` reserves text, grapheme indexes, visual rows, and paste
  space. Use `editor.Storage` with one `VisualRow` for a compact unwrapped single-line field.
- Text is UTF-8. Multiline models store LF; wrapping accepts LF and CRLF. Expand
  tabs before passing text to drawing or editing APIs. Graphemes may occupy up to
  48 UTF-8 bytes.
- Cursor and selection offsets are UTF-8 bytes. `cursorPosition()` returns logical
  display coordinates; `visualCursorPosition()` returns wrapped coordinates.
- Enable wrapping with `try model.setSoftWrap(true)`. Supply at least
  `model.value().len + 1` visual-row slots while wrapping is enabled.
- Attach undo storage with `model.setHistory(&history)`. Group edits with
  `history.beginTransaction()` and `history.endTransaction()`. The model exclusively
  borrows attached history until `setHistory(null)`.
- Recreate borrowed row iterators after edits or layout changes. Editing rebuilds
  indexes in linear time, so size models for fields and composers.
- For dynamic renderer storage, `RendererStorageRequirements.init()` returns the
  element counts for each storage slice. Size it for maximum width and height,
  and allocate using the element types declared by `RendererStorage`.

For passwords, set `field.display_mode = .masked` before drawing sensitive text.
The field paints one mask per grapheme; the model still holds plaintext. After
use, finish or cancel staged paste and call `model.secureDeinit()`. Erase separately
owned histories with `secureClear()`, and other buffers with `tui.secureZero(bytes)`.

## Input and the event loop

`input.Parser.next(bytes)` returns a consumed byte count and an event, failure,
or request for more input. Advance by that count. Parser and runtime payloads
are borrowed until the next operation; copy retained events with `input.OwnedEvent`.
At EOF, drain `parser.endInput()` through `.done`.

`runtime.Posix` combines input, timers, signals, worker notifications, and caller
poll sources. Open input with `O_NONBLOCK`. The runtime reports readiness for
caller sources; the application performs their I/O.

- Use `stepWithSources()` while idle and `pollWithSources()` between runnable work.
  Allocate poll storage with `runtime.requiredPollSlots(sources.len)`.
- Use `inputState()` to inspect local buffered work and incomplete input framing.
  When it reports buffered work, continue servicing the runtime even after a null poll.
- Set timers using awake-clock deadlines from `runtime.now()`.
- Share `runtime.notifier()` with workers. Keep the runtime at a fixed address,
  publish shared state before waking it, and join notifier users before `deinit()`.
- Bracketed paste waits for its terminator. `cancelPending()` reports a failure
  and discards the remaining paste through that terminator. Use `reset()` when
  replacing the input stream.

### Terminal lifecycle

Create a `terminal.Session` from the terminal input file. Call `beginEnter()` to
enter raw mode, then write each `outputStep()` suffix and acknowledge it with
`consumeOutput(n)` until entry completes.

Set `runtime.Options.resize` to the terminal file. Resize events carry `.cells`
and optional `.pixels`; use `.cells` for layout. Requests coalesce, and unchanged
cell dimensions can still accompany new pixel geometry.

Install `SignalSource` before starting workers. For suspension, finish presentation,
leave the session, restore termios, and call `suspendProcess()`. After continuation,
re-enter the session and call `renderer.invalidateTerminal()`. Forward
`.input_failure` to an active editor as `.malformed` to cancel its staged input.

On exit, call `beginLeave()`, finish its output, and call `restoreTermios()` even
if output fails. `emergencyRestore()` provides best-effort cleanup through a
nonblocking output descriptor after an output failure.

### Keyboard reporting

After capability negotiation, enable Kitty keyboard reports through
`SessionOptions.kitty_keyboard` or `session.beginKittyKeyboard()`:

```zig
const keyboard: tui.terminal.KeyboardEnhancements = .{
    .event_types = true,
    .all_keys = true,
    .associated_text = true,
    .alternate_keys = true,
};
```

Drain session output after reconfiguration. Pass null to pop the session's keyboard
frame. Associated text requires all-key reporting; releases for Enter, Tab, and
Backspace require both event types and all-key reporting.

`input.Key.code` identifies the key, `shifted_codepoint` and `base_layout_codepoint`
carry alternate identities, and `text` contains generated UTF-8. Editors insert
associated text on press/repeat. Command bindings match the primary identity.

## Compose widgets

Keep one scroll state per independently scrolled view. Draw with a widget's
`draw()` method or use its geometry and navigation with your own `Surface` painting.

| Task | API |
| --- | --- |
| Panel contents | `Panel.contentRect(size)` |
| Custom progress bar | `Gauge.filledWidth(width)` |
| Scrollbar thumb | `Scrollbar.geometry(height)` |
| Table body | `Table(Provider).bodyRect(size)` |
| Shared column placement | `ColumnLayout.init(columns, width)` |
| Selectable rows | `ScrollState.handle()`, `normalize()`, `visibleRange()` |
| Multirow items | `ScrollState.setItemGeometry(height, gap)`, `itemRect()`, `itemAt()` |
| Logs and tail-following | `scroll.Viewport`, `scroll.LineRing`, `widget.Scrollback` |
| Read-only paragraphs | `Paragraph.rowCount(width)`, `Paragraph.first_row` |

List, Table, and Scrollback use their declared `bounds` for layout and input. Draw
into a surface of that size and route mouse coordinates in the bounds' coordinate
space. Pass 0 header rows to `ScrollState.handle()` for lists and 1 for tables.
After data or geometry changes, call `normalize(count, body_height)` to clamp
state, or `reveal(count, body_height)` when you want to keep selection visible.
List, Table, and Scrollback drawing leaves navigation state unchanged. Their
`handle()` methods supply optional default navigation; use `scroll.Viewport` or
your own offsets for other policies. Item selection and scroll positions are item
indices; scrollbar metrics should use consistent units.

Default List/Table providers supply plain text. For styled cells, use the same
visible range and column placements with `Surface.putStyledLine()` or
`putWrappedStyledText()`. Wrapping methods accept `first_row` and `alignment`;
skipping rows traverses the prefix without building an index.

Register targets in `focus.Registry`, select the active ID with `focus.Manager`,
and dispatch events to that target. Use `widget.Update` to schedule layout and redraw.
`command` supplies key bindings, `overlay` supplies stacking and hit-testing, and
`theme` supplies styles for widget states.

Composition examples are in `examples/composition/`. Run them with
`zig build compositions`. See [GRAPHICS.md](GRAPHICS.md) for Kitty image uploads
and placement.

## Child processes

`subprocess.PtyProcess` owns a child and its PTY master. Call `spawnBeforeThreads()`
before starting workers. Spawning and `wait()` block; use `poll()` in the UI loop.
PTY EOF and child exit are separate events.

Reap through the process owner. After a failed spawn, inspect `state()` and clean
up a retained child. `killAndWait()` uses an absolute awake-clock deadline; retain
ownership and retry cleanup on failure. Call `deinit()` after reaping. Keep the
SIGCHLD disposition and child waits under the application's control.

## Build and test

```sh
zig fmt --check build.zig build.zig.zon bench examples src tools test
zig build test
zig build test -Dterminal-tests=true -Doptimize=ReleaseSafe --test-timeout 60s -j2
zig build compositions -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
```

`test-unit`, `test-system`, and `test-terminal` select individual suites. Terminal
tests use a pinned Ghostty engine and private PTYs. Process tests use Linux
devpts, pidfds, signalfd, and seccomp.

Regenerate Unicode tables from `tools/unicode/` with `zig build unicode-update`;
use `zig build unicode-check` to compare them with the checked-in tables.

### Benchmarks

```sh
zig build bench -- text_input 10000
zig build bench -- nonblocking_pipe 1000
zig build bench -- 1000
```

The last command runs every scenario. Each emits JSON with median batch-average
picoseconds per operation, output bytes, and work counts. `ps_batch_max` is the
slowest batch average; individual maxima are reported separately where measured.
Compare runs on the same machine with the same scenario and iteration count.

License notices are in `LICENSE` and `LICENSES/`. Report security issues through
[GitHub private vulnerability reporting](https://github.com/more-yet/tui.zig/security/advisories/new).
