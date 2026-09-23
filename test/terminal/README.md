# End-to-end terminal tests

```sh
zig build test -Dterminal-tests=true -Doptimize=Debug --test-timeout 60s -j2
zig build test -Dterminal-tests=true -Doptimize=ReleaseSafe --test-timeout 60s -j2
# Run only the terminal suite:
zig build test-terminal -Dterminal-tests=true --test-timeout 60s -j2
```

The suite runs unattended on the supported Linux target with devpts, pidfds,
`signalfd`, `/tmp`, and `/dev/shm`. Each scenario owns a private controlling PTY,
job-control parent, demo process, terminal engine, and local fixture files.

## Dependency

`build.zig.zon` pins Ghostty revision
[`f9a3f24a56bf05f70894e1a084809d4fffadf420`](https://github.com/ghostty-org/ghostty/tree/f9a3f24a56bf05f70894e1a084809d4fffadf420)
and its Zig content hash. `-Dterminal-tests=true` enables the lazy test dependency;
the public library and normal builds stay dependency-free.

The native `ghostty-vt` module provides VT parsing, screen state, image decoding
and storage, placements, and animation state. Its pinned Wuffs dependency
provides PNG decoding and pixel operations. The build enables formatter,
render-state, and Kitty graphics features. SIMD is disabled for a smaller build.

Assertions operate on terminal state and decoded image pixels. Desktop font
rasterization and GPU compositing belong to the terminal application's renderer.

## Coverage

- `render.zig`: UTF-8/VT fragmentation, RGB styles, wide-cell repair, cursor
  state, primary/alternate screens, terminal modes, capability negotiation,
  resized repaint, and graphics positioning around text presentation. A private
  PTY test checks emergency restoration of raw mode and partial control strings.
- `graphics.zig`: the demo's encoded image commands executed by Ghostty, with
  crop/offset/scale/layer assertions, animation-frame edits, deterministic
  playback timestamps, and storage release.
- `graphics_checks.zig`: shared decoded-pixel, placement, and storage assertions.
- `pty.zig`: fifteen fresh-process scenarios executing the real demo:
  - `edit_resize`: Kitty and ANSI keys, Unicode deletion, multiline paste,
    focus/mouse events, editor scrolling, resize, and Ctrl+Q.
  - `escape`, `interrupt`, `terminate`: Escape expiry and cooperative signal exits.
  - `suspend_resume`: actual `SIGTSTP` stop, restored termios and screen modes,
    foreground resume, re-entry, editing, and exit.
  - `oversize`: capacity rejection and terminal restoration.
  - `silent`: negotiation timeout followed by ordinary text input and exit.
  - `forced_cleanup`: stopped processes, forced termination, and reaping.
  - `graphics_direct`, `graphics_file`, `graphics_temporary_file`, and
    `graphics_shared_memory`: transport consumption, decoded pixels, placement,
    shrink/hide/grow, suspend/resume replay, deletion, and exit cleanup.
  - `graphics_oversize`: orderly graphics/resource cleanup on capacity rejection.
  - `graphics_reply_timeout`: a withheld local-upload acknowledgement, bounded
    failure reporting, cleanup, and continued text input.
  - `graphics_write_failure`: a zero file-size resource limit forces fixture
    initialization to fail; the test checks file rollback and terminal state.

## Process and resource ownership

`fixture.zig` establishes job control before exec: it creates the demo in a
separate foreground process group within its private session. This gives Linux
the parent/group relationship needed to deliver a genuine job-control stop. It
reports the stop only after an exact-child `waitpid` observes `SIGTSTP`, then
foregrounds and continues the same child when the test releases the resume gate.

The fixture owns the demo's normal wait status. The harness owns the fixture's
wait status through `tui.subprocess.PtyProcess`. A pidfd pins the demo's identity;
parent-death signaling and subreaper adoption provide forced-cleanup ownership.
`SIGCHLD` wakes the harness; exact-child waits reconcile authoritative status.

Every cooperative exit checks original termios fields, primary-screen content,
cursor visibility, paste/focus/mouse/synchronized-output modes, keyboard stacks,
and empty image storage on both screens. Local-file checks distinguish producer
ownership from terminal consumption. The harness checks reaping independently
from EOF and verifies that deinit closes the PTY master.

Each operation/cleanup deadline is five seconds; the fixture also has a
15-second idle deadline. The harness accepts at most 1 MiB of demo output and
reads at most sixteen 4 KiB chunks per turn. Oracle replies are bounded to 4 KiB,
stored images to 1 MiB, and fixture payloads to the demo's small static images.
The in-memory tests additionally split control strings and UTF-8 at every byte.

## Upstream qualification

The selected upstream temporary-file containment test passes in both native and
C-API variants from the dependency checkout under this workspace (69 tests,
including aggregate import tests). Its earlier full-suite run under `/tmp`
reported two failures because the fixture fell inside the implementation's
general `/tmp` allowance. The targeted rerun confirms that path-dependent
diagnosis; full upstream-suite qualification remains a separate check.
