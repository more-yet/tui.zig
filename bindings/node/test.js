import test from "node:test";
import assert from "node:assert/strict";
import binding from "./index.js";

test("ABI version and owned handles", () => {
  assert.deepEqual(binding.abiVersion(), { major: 1, minor: 0, patch: 0 });
  const renderer = binding.rendererCreate({ width: 8, height: 2 });
  const input = binding.textInputCreate(32, "ready");
  const area = binding.textAreaCreate(64, "one\ntwo");
  const chart = binding.lineChartCreate(8, 8);
  const queue = binding.eventQueueCreate(4);
  const parser = binding.parserCreate();
  binding.parserDestroy(parser);
  binding.eventQueueDestroy(queue);
  binding.lineChartDestroy(chart);
  binding.textAreaDestroy(area);
  binding.textInputDestroy(input);
  binding.rendererDestroy(renderer);
});

test("rejects values that do not fit the C ABI", () => {
  assert.throws(() => binding.rendererCreate({ width: 65536, height: 1 }), /out of range/);
  assert.throws(
    () => binding.panelContentRect({ x: -1, y: 0, width: 1, height: 1 }),
    /non-negative safe integer/,
  );
  const renderer = binding.rendererCreate({ width: 4, height: 4 });
  try {
    binding.rendererBeginFrame(renderer);
    assert.throws(
      () => binding.rendererPutImage(
        renderer,
        { x: 0, y: 0, width: 1, height: 1 },
        { pixels: Buffer.alloc(3), width: 4294967296, height: 1, format: 0 },
        { imageId: 1, placementId: 1 },
      ),
      /out of range/,
    );
  } finally {
    binding.rendererDestroy(renderer);
  }
});

test("rejects operations on closed handles", () => {
  const renderer = binding.rendererCreate({ width: 4, height: 4 });
  binding.rendererDestroy(renderer);
  assert.throws(() => binding.rendererResize(renderer, { width: 4, height: 4 }), /closed/);
});
