# Kitty graphics

`tui.graphics` encodes Kitty commands without I/O, allocation, image decoding,
or compression. Its wire target is recorded in `kitty.specification_source`.

## Upload

```zig
var sender = tui.graphics.Sender.init(.{});
try sender.begin(.{ .transmit = .{ .transmission = .{
    .width_pixels = 1,
    .height_pixels = 1,
    .identifiers = .{ .image_id = 1 },
} } }, .{ .direct = &.{ 255, 0, 0, 255 } }, .all);
```

For each scheduler turn, call `sender.outputStep()`. Write the returned suffix
once, then acknowledge only accepted bytes with `sender.consumeOutput(n)`.
On `WouldBlock`, wait for write readiness. Null means transport completion;
a correlated terminal reply confirms execution.

Keep payload or local-name bytes unchanged until completion, including
cancellation output. `cancel(delete)` drains an exposed command and sends the
chosen delete; keep driving output until complete. Finish a chunked upload before
starting another graphics command. Retrying animation edits can duplicate effects.

After completion and after all output borrows end, `try sender.secureDeinit()`
erases the sender's full storage. It refuses active output and does not cancel
uploads, delete terminal images, or wipe borrowed source bytes. Clear those bytes
yourself only after their separate terminal/resource lifetime ends.

## Local resources and replies

- Keep files or shared memory alive until a correlated reply confirms consumption,
  even after sender output completes. Applications own timeout and cleanup policy.
- Terminals consume/unlink temporary-file and shared-memory transports.
- Use distinct nonzero probe IDs with `beginGraphicsQueries(probe_id)`.
  A successful probe does not certify every transport or advanced feature.
- Reply slices borrow parser storage. Copy and sanitize diagnostics before the
  next parser operation if displaying or retaining them.
- Dimensions and crop offsets are pixels; placement rows/columns are cells.
  Delete-cell coordinates and nonzero frame numbers are one-based.
- For `.zlib`, supply an already-compressed stream. Compressed PNG also needs
  `data_size_bytes` containing its uncompressed size.

## Placeholders and replay

Upload the image and create a virtual placement before using
`Surface.putKittyImage()`. Source row/column coordinates range from 0 through 296.
The renderer stores placeholder cells, not image resources.

When presentation returns `.cleared`, replay owned images and placements,
call `renderer.invalidateOutputState()`, then resume text presentation.
On suspend or shutdown, drain/cancel active uploads and delete owned resources
within the application's cleanup deadline before leaving the session.

## Checks

`test/core/graphics.zig` checks chunking, base64 padding, and partial-output
acknowledgement. `test/terminal/graphics.zig` decodes emitted RGBA commands and
checks placement, cursor preservation, cancellation, deletion, and storage release:

```sh
zig build test -Dterminal-tests=true --test-timeout 60s -j2
```
