# Contributing

Send security reports through the private process in
[`SECURITY.md`](SECURITY.md).

Use Zig `0.16.0`. Keep each change focused. Follow the ownership and capacity
rules of the code you change.

Keep tests focused on observable runtime contracts: fragmented I/O, state
transitions, bounded storage, partial failure, and resource cleanup. Do not add
tests for direct arithmetic, forwarding accessors, static fixtures, or the
internals of test dependencies. Use existing workflow tests when they already
protect the behavior. Validate untrusted inputs at their owning boundary; remove
an internal check only when its invariant follows from types or prior validation.

Before opening a pull request, run:

```sh
zig fmt --check build.zig build.zig.zon bench examples src tools test
zig build test -Dterminal-tests=true -Doptimize=Debug --test-timeout 60s -j2
zig build test -Dterminal-tests=true -Doptimize=ReleaseSafe --test-timeout 60s -j2
zig build compositions -Doptimize=ReleaseSafe
zig build unicode-check
zig build bench -- text_input 1000
zig build bench -- graphics_transfer 1000
```

Update `src/text/unicode_17.zig` with `zig build unicode-update`. Use safe sample
data in logs. Review the diff for secrets, and sign commits with a key verified
by GitHub.

Contributions are licensed under the repository's MIT license.
