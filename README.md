# tui.zig

[![CI](https://github.com/more-yet/tui.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/more-yet/tui.zig/actions/workflows/ci.yml)

Terminal UI primitives for **Zig 0.17.0**, **x86_64-linux-gnu**, and **Linux 5.9+**.
Unicode data is version **17.0.0**. The public module has no package dependencies.

The library provides text layout, incremental rendering, input parsing, widgets,
editing, terminal control, and subprocesses. Applications own storage, state,
I/O scheduling, approval policy, and cleanup.

## Use the library

Add the package, then pin the chosen revision in `build.zig.zon`:

```sh
zig fetch --save=tui git+https://github.com/more-yet/tui.zig.git
```

In your build:

```zig
const tui_package = b.dependency("tui", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("tui", tui_package.module("tui"));
```

### Draw a text field

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

Drawing updates memory, not the terminal. Route focused input through
`field.handle(event)`; inspect `field.takeFailure()` for rejected edits.
Set `field.display_mode = .masked` to paint one mask per grapheme without
submitting plaintext to the renderer. The model still stores plaintext.

For the native terminal cursor, set `paint_caret = false`, query
`field.caretPosition(surface.size())`, translate with `surface.screenPoint()`,
then call `renderer.setCursor()`. Hide the terminal cursor when either query
returns null. Query again after edits or resize.

### Present output

Call `renderer.beginPresentation(capabilities)` once, then drive
`renderer.presentStep(work_budget)`:

| Result | Caller action |
| --- | --- |
| `.output` | Attempt a nonblocking write; acknowledge only accepted bytes with `consumePresentation(n)` |
| `.yielded` | Run other work before the next presentation turn |
| `.cleared` | Replay owned graphics if needed, then `invalidateOutputState()` |
| `.complete` | The frame is finished; drawing may resume |

Keep one output owner. Pending output stays stable until acknowledged. A partial
command must be drained before aborting. On `WouldBlock`, wait for write readiness
rather than spinning. Recreate surfaces and redraw after resize.

`terminal.Session` and `graphics.Sender` use the same pattern:
`outputStep()` returns a suffix, `consumeOutput(n)` acknowledges its accepted
prefix, and null means complete. [Graphics usage](GRAPHICS.md) covers uploads,
resource ownership, and replay.

### Storage and editing

- Keep borrowed storage alive, fixed, and disjoint for the owner's lifetime.
- `editor.FixedStorage(n)` reserves text, grapheme indexes, rows, and paste space.
  A non-wrapped single-line model can use one `VisualRow` via `editor.Storage`.
- `_ = try model.setSoftWrap(true)` requires `model.value().len + 1` row slots;
  edits enforce this bound while wrapping is enabled.
- Cursor offsets are UTF-8 bytes. Use `cursorPosition()` for logical display
  coordinates and `visualCursorPosition()` for wrapped coordinates.
- Recreate borrowed row iterators after edits or layout changes. Attached history
  is exclusively borrowed until detached.
- For dynamic renderer allocation, `RendererStorageRequirements.init()` returns
  element counts for every slice. Allocate using `RendererStorage.DamageRow`,
  `.GlyphEntry`, `.StyleEntry`, `Cell`, `usize`, and `u32` as declared by the
  storage fields. Size for maximum width and height, not just their product.

### Input and terminal lifecycle

- `terminal.queryGeometry(file)` returns `.cells` and optional `.pixels`. Runtime
  resize events carry this geometry and are also remeasurement hints: unchanged
  cell dimensions do not suppress a request. Multiple pending requests coalesce.
  Use `.cells` for renderer layout; pixel dimensions are null when unavailable.
  Set `runtime.Options.resize` directly to the borrowed `std.Io.File` to query.
- Use nonblocking terminal input/output. `runtime.Posix` validates both file flags
  and kernel `O_NONBLOCK` for input and caller poll sources.
- Use `stepWithSources()` when idle; use `pollWithSources()` to interleave runnable
  work. Allocate slots with `runtime.requiredPollSlots(sources.len)`.
- `inputState()` reports local buffered work and incomplete framing, including
  EOF work. It does not inspect the kernel queue or establish a fresh keypress.
  A null poll result does not mean all input is drained.
- Parser/runtime input slices are borrowed until the next operation. Use
  `input.OwnedEvent` when retaining an event.
- Paste has no idle timeout. Cancellation rejects once, then discards through the
  terminator. Reset the parser only when abandoning the old byte stream.
- Install `SignalSource` before workers. Leave the terminal session before
  `suspendProcess()`; re-enter and invalidate the renderer after continuation.
  Suspend/continue cancels incomplete input through `.input_failure`, preserving
  paste framing. Pass the rejection to an active editor as `.malformed`.
- Keep runtime at a fixed address while sharing notifiers. Publish shared state
  before waking; join notifier users before deinitializing runtime.
- Finish visual leave output and restore termios separately. Use
  `Session.emergencyRestore()` for bounded last-resort restoration after failure.

Select Kitty keyboard enhancements explicitly:

```zig
const keyboard: tui.terminal.KeyboardEnhancements = .{
    .event_types = true,
    .all_keys = true,
    .associated_text = true,
    .alternate_keys = true,
};
```

Set `SessionOptions.kitty_keyboard = keyboard` or call
`session.beginKittyKeyboard(keyboard)` after negotiation. Null leaves/disables
the session-owned stack frame. Reconfiguration pops that frame before pushing
its replacement; drain output normally. Associated text requires all-key reporting.
Enter/Tab/Backspace release events require event types and all-key reporting.
Terminals without these reports cannot distinguish held-key repeats reliably.

`input.Key` keeps primary identity in `code`, alternates in `shifted_codepoint`
and `base_layout_codepoint`, and generated UTF-8 in borrowed `text`. One report
produces one event. Editors prefer associated text on press/repeat and ignore
release text. Shortcuts remain matched against primary identity unless the caller
explicitly chooses an alternate. Copy retained events with `OwnedEvent`.

### Sensitive storage

Use explicit erasure after all borrows end:

- `Model.secureDeinit()` erases full text/index/row/paste capacities; finish or
  cancel staged paste first. Separately owned history is not erased.
- `History.secureClear()` and `InputHistory.secureClear()` erase full backing
  capacities and remain reusable. They require exclusive access.
- `Parser.secureDeinit()` refuses incomplete framing or queued outcomes.
- `Posix.secureDeinit()` refuses local input work and incomplete framing. Join
  notifier users first. It closes owned resources and erases its read buffer,
  but not timers, SignalSource, or kernel-queued input.
- `OwnedEvent.secureDeinit()` ends borrowed payload lifetimes and wipes the object.
- `Sender.secureDeinit()` requires idle output and erases only the sender.

Deinitialized objects must be initialized again before use. Erase other owned
buffers with `tui.secureZero(bytes)`. These operations neither erase terminal
history nor guarantee removal of external copies, registers, or swapped pages.

### Child processes

`subprocess.PtyProcess` owns one direct child's wait status and PTY master.
Call `spawnBeforeThreads()` before starting workers. A failed spawn can still
retain a child: check its state and finish cleanup.

Use exact-child `poll()` or `wait()` through the owner. PTY EOF is independent of
child exit and reaping. `killAndWait()` takes an absolute awake-clock deadline;
on failure, retain ownership and retry cleanup before `deinit()`. Do not install
an automatic-reaping signal disposition or use competing wildcard waits.

## Widget pattern

Keep state and layout in the application. Use a widget's default `draw()` or
paint directly with `Surface`; neither choice requires replacing navigation.
Keep one scroll state per independently scrolled view.

- **Geometry:** `Scrollbar.geometry(height)`, `Gauge.filledWidth(width)`,
  `Panel.contentRect(size)`, and `Table(Provider).bodyRect(size)` return cell
  geometry without drawing. Geometry is local to the supplied size.
- **Columns:** `ColumnLayout.init(columns, width)` iterates clipped `{ index, x,
  width }` placements. Zero-width columns are skipped; indices still refer to
  the original column slice. Use the same placements for headers, cells, and
  column hit-testing.
- **Selection:** `ScrollState.handle(event, count, bounds, header_rows)` provides
  keyboard, wheel, and row-click navigation without constructing a List or Table.
  Pass 0 header rows for lists and 1 for tables. Before custom drawing, call
  `normalize(count, body_height)`, then iterate `visibleRange(count, body_height)`.
- **Item geometry:** `try state.setItemGeometry(2, 1)` selects two-row items with
  one-row gaps. Top and selection remain item indices. `itemRect()` and `itemAt()`
  use body-local coordinates; gaps are not clickable. Default drawing wraps taller
  items and includes partially visible items. Navigation reveals a fully fitting
  selection, or top-aligns an item taller than the viewport. Keep scrollbar metrics
  in consistent units rather than mixing item indices and physical rows.
- **Logs:** `scroll.Viewport` provides scrolling, tail-following, and
  `visibleRange()`. It remains separate from selectable-row state.
- **Layout:** List, Table, and Scrollback use their declared `bounds` for layout
  and input. Update those bounds during application layout and draw into a surface
  of exactly that size, as TextArea requires after `layout(size)`. Drawing does
  not infer a new layout from the surface. Mouse events must use the bounds'
  coordinate space; route keyboard events only to the intended view.

For example, change a gauge's appearance without repeating its calculation:

```zig
const width = surface.size().width;
const filled = gauge.filledWidth(width);
try surface.fillAscii(.{ .x = 0, .y = 0, .width = width, .height = 1 }, '.', .{});
try surface.fillAscii(.{ .x = 0, .y = 0, .width = filled, .height = 1 }, '=', .{});
```

Default List/Table providers supply plain text. For per-cell styles or mixed
content, draw directly using the same state, visible range, and column layout.
No renderer callbacks or alternate state objects are needed.

For borrowed read-only text, use `Paragraph.rowCount(width)` and set
`Paragraph.first_row` before drawing. Both surface wrapping methods accept
`.{ .first_row = top, .alignment = .left }`. Public wrapping iterators also provide
`skipRows(n)` and `countRemaining()`; counting leaves the iterator unchanged.
They use the same wrapping engine, validate all input, and traverse skipped prefixes
without allocating an index. An offset beyond the content clears the viewport.

`focus.Registry` borrows a caller-owned `[]focus.Target` for registration and
hit-testing. `focus.Manager` selects the active ID. Dispatch events directly to
that target and use `widget.Update` to decide when to lay out and redraw.
The application owns scheduling; finish active presentation before drawing.

## Modules

| Namespace | Provides |
| --- | --- |
| `text` | Graphemes, widths, word/line breaks, wrapping |
| `render` | Grids, clipped surfaces, styles, cursors, Braille canvas |
| `graphics` | Kitty commands, sender, replies, placeholders |
| `input`, `runtime`, `terminal` | Parsing, polling, timers, signals, sessions, capabilities |
| `editor` | Single/multiline models, selection, actions, history |
| `widget`, `layout`, `scroll` | Controls, lists, tables, scrollback, geometry, row storage |
| `focus`, `command`, `overlay`, `theme` | Focus navigation, hit-testing, bindings, layers, styles |
| `subprocess` | PTY processes and child lifecycle |

Finite usage recipes live in `examples/composition/`:

```sh
zig build compositions
```

## Verification

All maintained tests live in this repository under `test/`:

- `core/`: input, Unicode, editing, rendering, and widget interactions.
- `system/`: isolated process, descriptor, signal, and suspend/resume tests.
- `terminal/`: output interpreted by a pinned terminal engine, plus private-PTY
  restoration. Enabled only with `-Dterminal-tests=true`.

```sh
zig fmt --check build.zig build.zig.zon bench examples src tools test
zig build test -Dterminal-tests=true -Doptimize=Debug --test-timeout 60s -j2
zig build test -Dterminal-tests=true -Doptimize=ReleaseSafe --test-timeout 60s -j2
zig build compositions -Doptimize=ReleaseSafe
zig build unicode-check
zig build bench -- text_input 1000
zig build bench -- graphics_transfer 1000
```

`test-unit`, `test-system`, and `test-terminal` select individual suites.
Process tests require devpts, pidfds, signalfd, and permission to install seccomp
filters. They do not use the host's interactive terminal.
See [terminal tests](test/terminal/README.md) and [benchmarks](bench/README.md).

Generated Unicode tables come from `tools/unicode/`; regenerate with
`zig build unicode-update`. License notices are in `LICENSE` and `LICENSES/`.
Report security issues using [SECURITY.md](SECURITY.md).
