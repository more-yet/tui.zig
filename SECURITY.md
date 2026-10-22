# Security Policy

## Supported Versions

We provide security fixes for the latest `0.1.x` release and the `main` branch.
Supported releases target Zig 0.17.0 on x86_64 Linux GNU with Linux 5.9 or newer.

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

## Explicit disposal

`secureDeinit()` ends the lifetime of a model, parser, runtime, owned event, or
graphics sender and performs non-elidable memory erasure. Reinitialize before
reuse. Pending parser framing, staged editor paste, local runtime input, and
active sender output must be resolved first; refusal leaves the object intact.
End borrowed event/output lifetimes and join runtime notifier users before disposal.

Models erase all supplied storage slices but not separately owned history.
History `secureClear()` methods erase full capacities and permit reuse under
exclusive access. Runtime disposal closes owned resources before erasure; it does
not erase borrowed timers, signal sources, or input still queued in the kernel.
Sender disposal does not cancel an upload, delete terminal images, or erase source
data. Finish cancellation output and terminal-resource cleanup separately.

Use `tui.secureZero(bytes)` for other caller-owned buffers after their lifetimes.
No live renderer erasure API is provided: release its users and erase its complete
storage separately if plaintext was rendered. Erasure does not recover data already
sent to a terminal or remove external copies, registers, or swapped pages.
