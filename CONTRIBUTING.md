# Contributing

Send security reports through the private process in
[`SECURITY.md`](SECURITY.md).

Use Zig `0.16.0`. Keep each change focused. Follow the ownership and capacity
rules of the code you change, and add a test when behavior changes.

Before opening a pull request, run:

```sh
zig fmt --check --exclude src/text/unicode_17.zig \
  build.zig bench examples src test tools
zig build test
zig build test -Doptimize=ReleaseSafe
zig build unicode-check
```

Update `src/text/unicode_17.zig` with `zig build unicode-update`. Use safe sample
data in tests and logs. Review the diff for secrets, and sign commits with a key
verified by GitHub.

Contributions are licensed under the repository's MIT license.
