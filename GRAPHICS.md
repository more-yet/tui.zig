# Kitty graphics protocol

`tui.graphics` provides bounded, allocation-free client-side encoding for the
Kitty graphics protocol. The wire contract is pinned to the protocol at Kitty
commit [`87ab3e98`](https://github.com/kovidgoyal/kitty/blob/87ab3e98f4d399337777e4329960d7cd09101e99/docs/graphics-protocol.rst),
recorded as revision `2026-09-16`. Ghostty commit
[`d4c88d8`](https://github.com/ghostty-org/ghostty/tree/d4c88d8069912b653d707191388ca98e24751f12/src/terminal/kitty)
was used as an implementation cross-check. Kitty's specification is the
wire authority.

The client encoder transmits caller-owned payloads, parses replies, and
integrates placeholders and replay checkpoints with the text renderer. The
terminal owns image decoding, compositing, and image storage.

## Ownership and limits

- `graphics.Sender` borrows command payload bytes or a local-resource name from
  `begin` until completion or until a cancellation delete is fully accepted.
  Keep that storage alive and immutable during the borrow.
- Output returned by `outputStep` remains stable until its accepted prefix is
  acknowledged with `consumeOutput`. This records transport acceptance;
  correlated terminal replies confirm execution.
- A file, temporary file, or shared-memory object may need to remain available
  after sender completion. Keep it alive until the correlated terminal reply
  confirms that the terminal read it. Temporary-file and POSIX shared-memory
  media are consumed/unlinked by a conforming terminal.
- The sender owns one active operation and a fixed output buffer. It performs no
  I/O or allocation. Direct input is split into at most 3,072 source bytes and
  4,096 base64 bytes per APC. Local names have a hard 2,048-byte decoded limit;
  caller limits may reduce it.
- `max_pixels` bounds known dimensions. The terminal's decoder limits and
  filesystem permissions govern its processing of PNG, zlib, and local payloads.
- RGB/RGBA dimensions and placement geometry are pixels. `columns`, `rows`,
  relative offsets, and placeholder coordinates are terminal cells. Delete-cell
  coordinates are one-based. Frame numbers are one-based when nonzero.
- `compression = .zlib` means the caller supplies an already-compressed RFC 1950
  stream. Compressed PNG also requires `data_size_bytes` (`S`) containing the
  uncompressed PNG size.
- Reply diagnostics and unknown fields borrow the parser event. Copy and sanitize
  diagnostics before the next parser operation if they must be retained.

Image IDs, image numbers, placement IDs, probe IDs, replay descriptions,
deadlines, and local-resource cleanup all belong to the application. `i` and
`I` are mutually exclusive in commands. An image number asks the terminal to
allocate an image ID; use the returned ID for later commands.

## Nonblocking send loop

```zig
var sender = tui.graphics.Sender.init(.{});
try sender.begin(.{ .transmit = .{ .transmission = .{
    .format = .rgba,
    .width_pixels = width,
    .height_pixels = height,
    .identifiers = .{ .image_id = image_id },
} } }, .{ .direct = rgba_bytes }, .errors_only);

while (try sender.outputStep()) |pending| {
    // Make at most one nonblocking write attempt in this scheduler turn.
    const accepted = writeOnce(tty_fd, pending) catch |err| switch (err) {
        error.WouldBlock, error.Interrupted => continue,
        else => return err,
    };
    if (accepted == 0) return error.NoWriteProgress;
    try sender.consumeOutput(accepted);
}
```

Finish a chunked upload before starting another graphics command. The caller
owns retry policy: repeating animation append/edit operations can duplicate
effects. `cancel(delete)` drains an already exposed APC and then sends exactly
one caller-selected delete command, which aborts an incomplete upload.

Enable graphics negotiation with a correlated probe:

```zig
const query = try negotiator.beginGraphicsQueries(application_probe_id);
```

Use a distinct nonzero probe ID for each negotiation epoch. A correlated `OK`
proves that the basic probe executed. An error
preserves its diagnostic, Device Attributes arriving first means unsupported,
and timeout/cancellation leaves unfinished observations unknown. Verify each
selected medium and advanced feature through its own command replies and tests.

## Unicode placeholders and renderer replay

`Surface.putKittyImage` emits fully explicit U+10EEEE placeholder graphemes. It
uses the canonical 297-entry Unicode 6.0 coordinate table, exact low-24-bit
foreground image IDs, high-byte diacritics, and exact underline-color placement
IDs. Source rows and columns range from 0 through 296. As with other surface
drawing, intern-capacity failure can leave a partial desired update; overwrite
the region before retrying.

The renderer stores placeholders as ordinary glyph/style cells in its text grids.
The application owns image resources. After an invalid terminal shadow,
presentation follows this order:

1. write and completely acknowledge the destructive clear;
2. receive `Presentation.cleared`;
3. replay application-owned image resources and placements;
4. call `Renderer.invalidateOutputState()` after external graphics output;
5. resume text presentation.

Use conservative replay after clear, resize, resume, or recovery. Before suspend
or quit, stop new work, drain or cancel an active upload, delete only resources
owned by the application within its cleanup deadline, and then leave the
session. `Session.emergencyRestore(output_fd)` terminates a partial control
string, restores termios, and attempts one bounded leave write after a fatal
transport error.

## Local transport demo

Select the demo's graphics transport explicitly:

```sh
zig build demo -- --graphics=direct
zig build demo -- --graphics=file
zig build demo -- --graphics=temporary-file
zig build demo -- --graphics=shared-memory
```

The demo creates its local fixture exclusively with mode 0600 and releases it
on return, including initialization and runtime errors. It waits up to 250 ms
for a correlated local-upload reply. Confirmed temporary-file and shared-memory
uploads replay from retained bytes; file uploads reuse their owned file. A
rejected or timed-out initial upload stops that showcase and reports the error
while text input stays responsive. The showcase covers static RGBA and PNG,
precompressed zlib RGB, transparency, crop/scale/offset/layers, upload reuse,
virtual placeholders, relative placement, animation upload/edit/compose/control,
frame deletion, placement-only deletion, cleanup, and replay.

The graphics demo reserves a five-row footer when the terminal is at least
20 columns by 12 rows. Text and editor viewports stop above it. Every replay
explicitly positions the cursor in that footer and deletes the demo-owned image
IDs before uploading again. The shared layout determines the image origin.
The layered swatch, placeholders, and relative placement remain within
the footer. On smaller terminals, the demo deletes its images and shows a size
hint; growing the terminal replays them. Text-only runs use the full editor area.

## Automated verification

```sh
zig build test -Dterminal-tests=true --test-timeout 60s
```

Contract tests cover reserved layout, partial writes, and correlated replies.
The native terminal oracle decodes RGBA, PNG, and zlib RGB; assertions inspect
image pixels, crop/offset/scale/layer fields, virtual and relative placements,
animation editing and deterministic frame deadlines, and image deletion.

End-to-end scenarios run the demo with each transport in its own controlling
PTY. They exercise shrink/hide/grow, genuine suspension and foreground resume,
normal exit, oversized-window rejection, and a withheld upload reply. Tests
inspect both screens' image storage, local files, termios, terminal modes, child
status, and descriptor release. The [test guide](test/terminal/README.md) describes
the test-only dependency and resource bounds.
