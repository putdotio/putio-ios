import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  parseCoverageManifest,
  parseTokens,
  renderAssetCatalog,
  validateCoverage,
} from "./generate-design-tokens.ts";

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

test("resolves the token artifact through the package public export", () => {
  const resolved = import.meta.resolve("@putdotio/design/tokens");
  assert.match(resolved, /tokens\.flat\.json$/);
});

test("renders semantic adaptive colors into the asset catalog", async () => {
  const rawTokens = JSON.parse(
    await readFile(fileURLToPath(import.meta.resolve("@putdotio/design/tokens")), "utf8"),
  ) as unknown;
  const files = renderAssetCatalog(parseTokens(rawTokens));
  const background = JSON.parse(
    files["PutioBackground.colorset/Contents.json"] ?? "null",
  ) as { colors?: readonly { appearances?: readonly unknown[] }[] };
  assert.equal(background.colors?.length, 2);
  assert.equal(background.colors?.[1]?.appearances?.length, 1);
});

test("rejects newly published tokens until coverage is classified", async () => {
  const [rawTokens, rawCoverage] = await Promise.all([
    readFile(fileURLToPath(import.meta.resolve("@putdotio/design/tokens")), "utf8"),
    readFile(new URL("./design-token-coverage.json", import.meta.url), "utf8"),
  ]);
  const manifest = parseCoverageManifest(JSON.parse(rawCoverage) as unknown);
  const entries = [
    ...parseTokens(JSON.parse(rawTokens) as unknown),
    ...parseTokens({
      "future.native.metric": token("dimension", "global", "12px", "--future-native-metric"),
    }),
  ];
  assert.throws(
    () => validateCoverage(entries, manifest, manifest.sourcePackageVersion),
    /unclassified design tokens: future\.native\.metric/,
  );
});
