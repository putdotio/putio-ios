import assert from "node:assert/strict";
import test from "node:test";

import { formatFixed, parseHsl, swiftName } from "./sync-design-tokens.ts";

test("formatFixed rounds like Ruby's format(\"%.3f\")", () => {
  const cases: Array<[number, string]> = [
    [0.0845, "0.084"],
    [0.1235, "0.124"],
    [0.0005, "0.001"],
    [0.0625, "0.062"],
    [0.06250000000000004, "0.063"],
    [0.0014999999999999998, "0.002"],
    [0.9995, "1.000"],
    [12.3455, "12.346"],
    [-0, "-0.000"],
    [-1e-7, "-0.000"],
  ];
  for (const [value, expected] of cases) {
    assert.equal(formatFixed(value, 3), expected, String(value));
  }
});

test("parseHsl matches the Ruby generator's components", () => {
  assert.deepEqual(parseHsl("hsl(151, 35%, 13%)"), { red: "0.084", green: "0.176", blue: "0.132", alpha: "1.000" });
  assert.deepEqual(parseHsl("hsla(1.2.3, .5%, 5.%, 0.25)"), {
    red: "0.050",
    green: "0.050",
    blue: "0.050",
    alpha: "0.250",
  });
  assert.deepEqual(parseHsl("hsl( 85 ,76.0% ,92.3% )"), { red: "0.933", green: "0.982", blue: "0.864", alpha: "1.000" });
  assert.deepEqual(parseHsl("hsla(359.5, 12.5%, 50%, 0.0625)"), {
    red: "0.562",
    green: "0.438",
    blue: "0.439",
    alpha: "0.062",
  });
  assert.deepEqual(parseHsl("hsl(360, 100%, 50%)"), { red: "1.000", green: "0.000", blue: "0.000", alpha: "1.000" });
  assert.throws(() => parseHsl("rgb(0,0,0)"), { message: 'Unparseable color value: "rgb(0,0,0)"' });
});

test("swiftName camel-cases keys and prefixes numeric ones", () => {
  assert.equal(swiftName("bg"), "bg");
  assert.equal(swiftName("component-bg-hover"), "componentBgHover");
  assert.equal(swiftName("3"), "step3");
  assert.equal(swiftName("foreground-MUTED"), "foregroundMuted");
  assert.equal(swiftName("a--b"), "aB");
});
