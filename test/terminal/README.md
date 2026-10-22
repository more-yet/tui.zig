# Terminal tests

```sh
zig build test-terminal -Dterminal-tests=true --test-timeout 60s -j2
```

Tests feed library output directly into the `ghostty-vt` terminal engine from a
pinned Ghostty prerelease. It is used only for tests; the public library has no
dependency on it.

- `render.zig`: fragmented UTF-8/VT output, styles, wide-cell repair, cursor
  placement, resize, capability replies, and normal/emergency restoration on private PTYs.
- `graphics.zig`: fragmented RGBA upload, crop/scale/layer placement, cursor
  preservation, cancellation, image deletion, and storage release.
- `oracle.zig`: shared terminal setup with 4 KiB reply storage and a 1 MiB image limit.

These tests require Linux with devpts. Process and signal tests live separately
in `test/system/` and run with `zig build test-system`.
