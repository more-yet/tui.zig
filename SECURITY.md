# Security Policy

## Supported Versions

We provide security fixes for the latest `0.1.x` release and the `main` branch.
Supported releases target Zig 0.16.0 on x86_64 Linux GNU with Linux 5.9 or newer.

## Report a Security Issue

Send security reports through
[GitHub private vulnerability reporting](https://github.com/more-yet/tui.zig/security/advisories/new)
to keep the report and follow-up private.

Please include the version, platform, impact, steps to reproduce, and a small
example. Replace secrets and personal data with safe sample data.
Test with systems and data that you own or have permission to use.

We will review the report in private and publish details after a fix is ready.

## Masked Input Boundary

`widget.TextInput` masked mode prevents its masked drawing path from submitting
plaintext glyphs to renderer or presentation storage. It displays one fixed mask
for each Unicode grapheme, so text length, edits, selection, and caret position
remain observable.

Masking protects presentation. The caller-owned editor, staged paste, optional
undo history, parser buffers, application copies, `value()`, and `selectedText()`
may still expose plaintext. Applications must choose suitable history and storage
policies, avoid logging secrets, and erase sensitive buffers after their valid
lifetime. Enable masking before the first sensitive draw. Earlier terminal
output, logs, terminal echo, and application copies retain their original content.
