// Run with `mise run verify-scripts-tests`.

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { median, parseMetrics, summarize } from "./perf-metrics.ts";

describe("median", () => {
  // N=10 is the default, so every median is of an even count.
  test("averages the middle pair of an even count", () => {
    assert.equal(median([4, 1, 3, 2]), 2.5);
  });
});

describe("summarize", () => {
  // The shape `xcrun xcresulttool get test-results metrics --compact` prints.
  const sample = JSON.stringify([
    {
      testIdentifier: "PerformanceUITests/testOpenLargeImage()",
      testRuns: [
        {
          device: { deviceId: "id", deviceName: "iPhone 17 Pro Max" },
          testPlanConfiguration: { configurationId: "1", configurationName: "Test Scheme Action" },
          metrics: [
            { displayName: "Duration (ImageOpen)", unitOfMeasurement: "s", measurements: [0.2, 0.25, 0.21, 0.9] },
            { displayName: "Memory Peak Physical", unitOfMeasurement: "kB", measurements: [204800, 215040] },
          ],
        },
      ],
    },
  ]);

  test("reports durations in ms and memory in MB, one row per metric", () => {
    const [duration, memory] = summarize(parseMetrics(sample));

    assert.equal(duration?.test, "testOpenLargeImage");
    assert.equal(duration?.unit, "ms");
    assert.equal(duration?.n, 4);
    assert.ok(Math.abs(duration!.median - 230) < 1e-9);
    assert.ok(Math.abs(duration!.min - 200) < 1e-9);
    assert.ok(Math.abs(duration!.max - 900) < 1e-9);

    assert.equal(memory?.unit, "MB");
    assert.equal(memory?.median, 205);
  });

  test("keeps the spread off a single outlier", () => {
    const [duration] = summarize(parseMetrics(sample));
    // Deviations from 230 ms: 30, 20, 20, 670.
    assert.ok(Math.abs(duration!.mad - 25) < 1e-9);
  });
});
