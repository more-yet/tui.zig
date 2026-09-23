# tui.zig

[![CI](https://github.com/more-yet/tui.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/more-yet/tui.zig/actions/workflows/ci.yml)

`tui.zig` is a text-first Linux terminal UI library for Zig. It provides Unicode
text, incremental rendering, input parsing, layouts, widgets, terminal control,
and subprocesses while leaving application state, storage, I/O, and event-loop
policy to the caller.

## Features

- Unicode 17 grapheme, width, line-break, and wrapping support
- Incremental rendering with bounded resumable presentation and explicit output acknowledgement
- Pull-based keyboard, mouse, paste, focus, and terminal-reply parsing
- Bounded Kitty graphics encoding, replies, Unicode placeholders, and replay checkpoints
- Layouts, controls, masked and plain editors, focus, commands, themes, and overlays
- Bounded editor and input history with complete-entry eviction
- Provider-backed lists and tables, menus, stateless scrollbars, and Braille canvases
- Bounded Linux poll turns, timers, `signalfd` signals, wakeups, and explicit resize events
- Subprocess and PTY support with explicit paths and arguments
- Caller-supplied storage and explicit capacity limits on bounded subsystems

## Requirements

- Package version: `0.1.0`
- Zig version: `0.16.0`
- Target: `x86_64-linux-gnu`
- Linux kernel: 5.9 or newer
- Unicode data: `17.0.0`

The package exposes a dependency-free native Zig module.

## Install

Add the package to `build.zig.zon`:

```sh
zig fetch --save=tui git+https://github.com/more-yet/tui.zig.git#v0.1.0
```

Pin a release tag for reproducible consumer builds.

Import its module from `build.zig`:

```zig
const tui_package = b.dependency("tui", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("tui", tui_package.module("tui"));
```

## Demo

```sh
zig build demo
```

The interactive demo exercises nonblocking session transitions, capability
negotiation, resize and suspend handling, text input, multiline editing, focus,
and incremental drawing. Use `Tab` or `Alt+Left`/`Alt+Right` to switch focus, and
`Ctrl+Q` or `Esc` to quit.

The default demo presents text input and an editor. Enable the Kitty graphics showcase and
choose its transport explicitly with `--graphics=direct`, `--graphics=file`,
`--graphics=temporary-file`, or `--graphics=shared-memory`. See
[`GRAPHICS.md`](GRAPHICS.md) for transport ownership, replay, and automated tests.

## Widget Recipes

`TextInput` paints its caller-owned editor as one `*` per Unicode grapheme:

```zig
var password = tui.widget.TextInput.init(&password_model);
password.display_mode = .masked;
```

`Scrollbar` is a stateless visual indicator. The application or viewport remains
the only owner of scroll position:

```zig
const bar = tui.widget.Scrollbar{
    .total_rows = rows.len,
    .visible_rows = body_height,
    .top_row = viewport.top,
};
try bar.draw(&bar_surface);
```

Compiled recipes in `examples/composition/` demonstrate application-owned forms,
responsive table columns, a fixed warning beside scrolling output, and
deadline-driven progress. Run their finite headless smoke program with:

```sh
zig build compositions
```

## Modules

| Module | Contract |
| --- | --- |
| `tui.text` | Unicode width, graphemes, line breaks, layout, and wrapping |
| `tui.render` | Dense desired/presented grids, clipped surfaces, damage, resumable presentation, cursors, and Braille canvases |
| `tui.graphics` | Bounded Kitty commands, sender, replies, and Unicode placeholders |
| `tui.terminal` | Resumable Linux session transitions, capabilities, size queries, and emergency restoration |
| `tui.input` | Pull-based terminal input parser and borrowed events |
| `tui.runtime` | Bounded Linux poll turns, timers, signals, wakeups, caller sources, and resize events |
| `tui.subprocess` | Linux subprocesses and PTYs with explicit lifecycle state |
| `tui.scroll` | Line decoding, fixed-size line storage, and scrolling |
| `tui.editor` | Multiline text, selection, bounded history, actions, and visual rows |
| `tui.layout` | Insets, constraints, placement, flex splits, and grids |
| `tui.widget` | Labels, controls, editors, lists, tables, menus, and scrollback |
| `tui.focus` | Focus order, navigation, hit testing, and event routing |
| `tui.command` | Key bindings and key-sequence matching |
| `tui.app` | Layout and drawing preparation scheduling |
| `tui.theme` | Semantic colors and styles |
| `tui.overlay` | Overlays, modals, and hit-test data |

Wrapping iterators borrow their input for the iterator and returned-line
lifetimes. Styled wrapping also borrows its span descriptors. Each span is
validated as an independent UTF-8 and grapheme segment. Line-break opportunities
come from Unicode text boundaries; styled spans retain their separate storage.

## Interactive I/O Contract

- Open the controlling terminal for nonblocking input and output. `runtime.Posix`
  validates both `std.Io.File.flags.nonblocking` and kernel `O_NONBLOCK` for its
  input and every caller-provided poll source.
- `stepWithSources` waits for one event. `pollWithSources` performs one bounded,
  non-waiting turn and may return `null`; use it to interleave CPU work with input,
  timers, signals, and output readiness.
- With no buffered work, timer, or parser deadline, blocking runtime steps wait
  indefinitely. Positive timeouts come from the earliest explicit timer or
  incomplete-input deadline. Use non-waiting turns while CPU work is ready.
- Keep one output owner. `Session.outputStep()` returns a stable nonempty suffix or
  `null` when its transition is complete. Call `Renderer.beginPresentation()`
  once, then drive `presentStep()`. Attempt at most one nonblocking write and
  acknowledge only its accepted prefix with `consumeOutput` or
  `consumePresentation`.
- `graphics.Sender` follows the same stable-suffix contract. Finish a chunked
  upload before any other graphics command and retain payload/local-resource
  storage for the documented lifetime.
- Renderer capabilities are captured by `beginPresentation()`. Negotiation may
  continue concurrently; updated capabilities apply to the next presentation.
- `app.Driver.pending()` describes layout/drawing preparation only.
  `try Driver.prepare(...)` performs that pending work and returns no
  presentation status.
- Renderer queries describe presentation work. An already-active presentation
  must complete, or be safely aborted at a command boundary, before preparing a
  newer frame. The renderer owns presentation completion.
- Restore termios independently from visual leave output. `emergencyRestore`
  terminates partial control strings, restores termios, and attempts one bounded
  leave write using stack storage, preserving errno and session state.
- Interrupted raw syscalls are reported to the caller. Retry and deadline policy
  belongs to the application.
- A worker publishes synchronized application state before calling
  `Notifier.wake()`. Notifications coalesce, so the owner consumes authoritative
  state rather than counting wakes. Keep the runtime at a fixed address and stop
  or join every notifier user before `deinit`. Notifiers borrow runtime storage
  for their entire lifetime, including error handling.

See `examples/demo.zig` for a caller-owned scheduler that combines these rules.

### Capabilities and editing

`beginQueries()` starts text-capability negotiation.
`beginGraphicsQueries(probe_id)` explicitly opts into a correlated graphics
probe before the Device Attributes barrier. For a partial write, retain the
returned unsent suffix, attempt at most one
nonblocking write per turn, and apply caller-owned deadline and cancellation
policy. Cancellation preserves observations completed during that epoch and
resets only still-pending features.

Editor models own text and editing operations; text widgets own interaction
policy and painting. Cursor byte offsets, logical display positions, and wrapped
visual positions are distinct: use `cursorOffset()`, `cursorPosition()`, and
`visualCursorPosition()` respectively. Mutate cursor and selection state only
through checked model methods rather than by writing index fields.

Cached visual rows are borrowed derived state. They support viewport-bounded
drawing in wrapped and unwrapped modes. Recreate iterators after edits,
width-profile changes, wrap changes, or viewport-width changes.
`visibleRowWindow` and `visibleCaretWindow` return borrowed indexed views with
the same invalidation rules. Storage capacities are caller-owned and fixed.

## Child-Process Lifecycle

- Each `PtyProcess` exclusively owns one direct child's wait status. Route all
  exact-pid `poll`, `wait`, and cleanup calls through that owner.
- PTY stream state and process state are independent. EOF disables PTY read
  interest, but the application retains child ownership and status interest until
  the child is reaped.
- Reconcile every child once immediately after startup, then use `SIGCHLD` as a
  wake hint. Standard signals and signalfd records coalesce, so one notification
  schedules a bounded sweep of every owned child's authoritative state; it is not
  a child or status count.
- Install the child-signal policy before children and workers are started so they
  inherit a blocked `SIGCHLD` mask. Keep a waitable disposition: `SIG_IGN` and
  `SA_NOCLDWAIT` prevent status collection, while `SA_NOCLDSTOP` suppresses
  stop/continue notifications. Spawning rejects an automatic-reaping disposition
  with `IncompatibleSignalPolicy` before acquiring any child or PTY resources.
- A pidfd provides exit readiness and deadline-bounded cleanup. `SIGCHLD` covers
  stop and continuation as well as exit. Reconcile child status whenever either
  source becomes ready, in whichever order they arrive.
- During shutdown, stop users of the notification source, finish child cleanup
  and reaping, release PTY resources, and only then restore signal disposition
  and mask state.
- `killAndWait` waits on a pidfd against an absolute awake-clock deadline.
  A timeout, interruption, unsupported pidfd, or descriptor/resource failure can
  leave child ownership outstanding; retry or otherwise discharge it before
  `deinit`.
- Process-group signaling reaches descendants. Wait-status ownership follows
  direct parentage and explicit subreaper adoption.
- Before exec, the child closes inherited descriptors above stderr except its
  close-on-exec setup-report pipe. If Linux `close_range` is unavailable or denied,
  spawning fails with `ChildSetupFailed`; it never executes with leaked descriptors.

## Design and Safety

- Applications own widget state, text buffers, focus data, storage, output
  scheduling, threads, and event-loop policy.
- The renderer keeps exactly one dense row-major desired grid and one dense
  row-major presented grid. Damage tiles bound presentation scans. One non-owning
  last-fill proof accelerates identical fills.
- Surfaces borrow a renderer, preserve nested clipping and translation, and must
  be recreated after resize. Drawing is rejected during active presentation.
- Pending presentation commands are stable until acknowledged. Presented cells
  and terminal state commit only after the complete command is accepted; abort
  is rejected after a command prefix has been accepted.
- History descriptors are validated when initialized and when attached to a
  model. Their caller-owned slices remain fixed, disjoint, and exclusively
  borrowed until detached.
- Text enters editor internals through checked UTF-8 and displayability boundaries.
- Parser sequences, paste chunks, cells, styles, lines, and overlays have explicit
  limits.
- Runtime options reject invalid descriptors, empty signal sets, and zero parser
  deadlines.
- Resize events come from signals or an explicit `Notifier.requestResize()` call.
- PTY helpers manage process groups, descriptors, and bounded child cleanup.
- Internal assertions protect invariants after public validation has succeeded.
- Algorithms bound application work; Linux scheduling determines dispatch latency.

## Checks

```sh
zig fmt --check --exclude src/text/unicode_17.zig \
  build.zig build.zig.zon bench examples src tools test
zig build test
zig build test-terminal -Dterminal-tests=true --test-timeout 60s
zig build unicode-check
zig build example -Doptimize=ReleaseSafe
zig build compositions -Doptimize=ReleaseSafe
zig build bench -- app_cycle 1000
zig build bench -- graphics_transfer 1000
```

Benchmarks use ReleaseFast and print one JSON object per scenario.

`test` runs the dependency-free contract suite and isolated Linux process tests.
Use `test-unit` for in-process contracts or `test-system` for the six private-PTY
subprocess scenarios. The process tests use scenario-local seccomp filters to verify
fail-closed descriptor isolation; they require seccomp filter installation to be
permitted and do not modify the host terminal or test runner's signal policy.
`-Dterminal-tests=true` adds
end-to-end tests that launch the real demo in private PTYs and feed its output
through pinned native Zig `libghostty-vt`. The oracle decodes text and images;
tests assert pixels, placements, all four graphics transports, resize/replay,
genuine job-control suspend/resume, terminal restoration, and resource cleanup.
The same suite runs unattended in Debug and ReleaseSafe CI.

The opt-in test dependency includes Ghostty's pinned Wuffs image decoder. The
public `tui` module and normal builds remain dependency-free. Each test owns its
processes, PTY, signals, and fixture files. See the
[terminal test guide](test/terminal/README.md) for commands, coverage, and bounds.

Security reports follow the [Security Policy](SECURITY.md). The project is MIT
licensed and includes the upstream Unicode data license.
