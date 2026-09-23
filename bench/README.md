# Benchmarks

Run a fixed scenario with:

```sh
zig build bench -- dense_same_style 1000
```

The benchmark emits one JSON object per scenario. CPU-only renderer scenarios use
`std.Io.Writer.Discarding`; `nonblocking_pipe` instead drives renderer output
through a nonblocking pipe, polls write readiness with `tui.runtime.Posix`, and
accepts at most 17 bytes per write. Transport workloads are finite and have a
30-second per-batch deadline.

Focused performance scenarios include:

- `identical_full_fill`: repeated unchanged styled full-screen fills.
- `dense_same_style`: a full screen of changing, same-style ASCII text.
- `intern_churn`: more unique glyph/style insertions over time than either
  intern table can retain.
- `text_area_deep_soft_wrap`: a width-8 soft-wrapped editor viewport positioned
  near the final cached rows, with a selection on the final visual row.
- `text_area_deep_unwrapped`: a horizontally scrolled viewport at the end of a
  1536-column unwrapped row; painting starts at the indexed visible window.
- `nonblocking_pipe`: dense updates using the demo's poll/write/acknowledge
  scheduling pattern.
- `resize` / `resize_large`: blank 119/120 × 40 and 239/240 × 80 dense-grid
  reset workloads. The reference budgets are 25 µs and 100 µs respectively;
  populated resize must be compared as a separate fixture because it also
  reclaims interned references.
- `wrap_ascii` / `wrap_unicode`: punctuation-rich ASCII and grapheme-heavy
  Unicode through the borrowed plain-text wrapper.
- `wrapped_styled_ascii` / `wrapped_styled_unicode`: equivalent renderer
  workloads split across short styled spans, including empty spans.
- `graphics_transfer`: bounded Kitty direct-transfer encoding of one 3,072-byte
  source chunk, reporting source bytes, encoded bytes, output steps, and a
  byte-sum checksum. The checksum walk is part of the timed workload so the
  generated control and base64 bytes remain observable to the optimizer.

`output_chunks`, `write_attempts`, `accepted_bytes`, and `yielded_turns` expose
output granularity and scheduler work in addition to frame statistics. CPU-only
scenarios acknowledge each complete generated chunk immediately, so their write
attempt count equals their output chunk count.

`operation_ps_max` and `presentation_call_ps_max` are populated for intern-table
churn and nonblocking transport, where release/eviction and presentation-call
tails matter. Other scenarios report batch timings and set these fields to `null`.

`allocator_calls` and `allocated_bytes` are `null`, denoting unmeasured allocator
activity. Caller-owned storage provides the structural allocation boundary.

`ps_median` is the median batch-average picoseconds per operation.
`ps_batch_max` is the slowest **batch average**. Individual-operation maxima use
the separate `operation_ps_max` and `presentation_call_ps_max` fields.

For comparisons, use the same machine, Zig version, optimization mode, terminal
capabilities, dimensions, scenario, and iteration count. Timing is informational;
compare behavior and deterministic operation counts instead of shared-runner timing
thresholds.

`work_units` measures bounded presentation work. Drawing, initialization, and
reference bookkeeping are accounted for by their enclosing scenario timings.
