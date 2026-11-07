# Kitty graphics

`tui.graphics` encodes Kitty commands into caller-driven output. Supply image
bytes or local-resource names, then write the generated commands to the terminal.

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

After completion, `try sender.secureDeinit()` erases the sender's storage. Delete
terminal images and erase borrowed source bytes separately when their use ends.

## Local resources and replies

- Keep files or shared memory alive until a correlated reply confirms consumption,
  even after sender output completes. Applications own timeout and cleanup policy.
- Terminals consume/unlink temporary-file and shared-memory transports.
- Use distinct nonzero probe IDs with `beginGraphicsQueries(probe_id)`.
- Reply slices borrow parser storage. Copy and sanitize diagnostics before the
  next parser operation if displaying or retaining them.
- Dimensions and crop offsets are pixels; placement rows/columns are cells.
  Delete-cell coordinates and nonzero frame numbers are one-based.
- For `.zlib`, supply an already-compressed stream. Compressed PNG also needs
  `data_size_bytes` containing its uncompressed size.
- Decode and validate untrusted images before transmission, and approve terminal-side
  access to local resources. The sender checks direct PNG dimensions from its IHDR.

## Placeholders and replay

Upload the image and create a virtual placement before using
`Surface.putKittyImage()`. Source row/column coordinates range from 0 through 296.
Keep image resources alive while their placeholder cells are displayed.

When presentation returns `.cleared`, replay owned images and placements,
call `renderer.invalidateOutputState()`, then resume text presentation.
On suspend or shutdown, drain/cancel active uploads and delete owned resources
within the application's cleanup deadline before leaving the session.
