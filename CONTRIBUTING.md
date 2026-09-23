# Contributing

Send security reports through the private process in
[`SECURITY.md`](SECURITY.md).

Use Zig `0.16.0`. Keep each change focused. Follow the ownership and capacity
rules of the code you change.

Before opening a pull request, run:

```sh
zig fmt --check --exclude src/text/unicode_17.zig \
  build.zig build.zig.zon bench examples src tools test
zig build test -Dterminal-tests=true -Doptimize=Debug --test-timeout 60s -j2
zig build test -Dterminal-tests=true -Doptimize=ReleaseSafe --test-timeout 60s -j2
zig build example -Doptimize=ReleaseSafe
zig build compositions -Doptimize=ReleaseSafe
zig build unicode-check
zig build bench -- app_cycle 1000
zig build bench -- graphics_transfer 1000
```

Update `src/text/unicode_17.zig` with `zig build unicode-update`. Use safe sample
data in logs. Review the diff for secrets, and sign commits with a key verified
by GitHub.

Contributions are licensed under the repository's MIT license.
