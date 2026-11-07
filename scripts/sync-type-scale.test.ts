import assert from "node:assert/strict";
import test from "node:test";

import { formatNumber } from "./sync-type-scale.ts";

test("formatNumber matches Ruby's Float#to_s with integers trimmed", () => {
  const cases: ReadonlyArray<readonly [number, string]> = [
    [0.92, "0.92"],
    [-0.025, "-0.025"],
    [0.0, "0"],
    [-0.0, "0"],
    [1, "1"],
    [1.5, "1.5"],
    [0.0001, "0.0001"],
    [0.00001, "1.0e-05"],
    [-0.000015, "-1.5e-05"],
    [1e-100, "1.0e-100"],
    [123456789.125, "123456789.125"],
    [0.1 + 0.2, "0.30000000000000004"],
    [1e20, "100000000000000000000"],
  ];
  for (const [value, expected] of cases) assert.equal(formatNumber(value), expected, String(value));
});
