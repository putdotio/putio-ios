import assert from "node:assert/strict";
import test from "node:test";

import { parseTokens } from "./generate-design-tokens.ts";

const token = (
  type: string,
  mode: string,
  value: string | number,
  cssName: string,
) => ({ cssName, type, mode, value, originalValue: value });

test("rejects malformed token records at the package boundary", () => {
  assert.throws(
    () => parseTokens({ "color.brand": token("mystery", "global", "#fff", "--brand") }),
    /unsupported type/,
  );
});

test("preserves TV mode and viewport basis for platform-scoped generation", () => {
  const [entry] = parseTokens({
    "tv.overscan.x": {
      ...token("number", "tv", 0.04, "--tv-overscan-x"),
      basis: "viewport-width",
    },
  });
  assert.equal(entry?.token.mode, "tv");
  assert.equal(entry?.token.basis, "viewport-width");
});
