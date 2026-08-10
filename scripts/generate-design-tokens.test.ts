import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  parseCoverageManifest,
  parseTokens,
  renderAssetCatalog,
  semanticColorRoles,
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

test("renders dark-only semantic colors into the asset catalog", async () => {
  const rawTokens = JSON.parse(
    await readFile(fileURLToPath(import.meta.resolve("@putdotio/design/tokens")), "utf8"),
  ) as unknown;
  const files = renderAssetCatalog(parseTokens(rawTokens));
  for (const role of semanticColorRoles) {
    const asset = JSON.parse(
      files[`${role.assetName}.colorset/Contents.json`] ?? "null",
    ) as { colors?: readonly { appearances?: readonly unknown[] }[] };
    assert.equal(asset.colors?.length, 1, role.assetName);
    assert.equal(asset.colors?.[0]?.appearances, undefined, role.assetName);
  }
});

test("rejects light-mode sources for dark-only semantic colors", async () => {
  const rawTokens = JSON.parse(
    await readFile(fileURLToPath(import.meta.resolve("@putdotio/design/tokens")), "utf8"),
  ) as unknown;
  const entries = parseTokens(rawTokens).map((entry) =>
    entry.name === "surface.dark.appBg"
      ? { ...entry, token: { ...entry.token, mode: "light" as const } }
      : entry,
  );
  assert.throws(
    () => renderAssetCatalog(entries),
    /dark-only semantic color surface\.dark\.appBg must use dark or global mode/,
  );
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

test("rejects aliased tokens that diverge from their generated target", async () => {
  const [rawTokens, rawCoverage] = await Promise.all([
    readFile(fileURLToPath(import.meta.resolve("@putdotio/design/tokens")), "utf8"),
    readFile(new URL("./design-token-coverage.json", import.meta.url), "utf8"),
  ]);
  const manifest = parseCoverageManifest(JSON.parse(rawCoverage) as unknown);
  const entries = parseTokens(JSON.parse(rawTokens) as unknown).map((entry) =>
    entry.name === "typography.fontSize.4xl"
      ? { ...entry, token: { ...entry.token, value: "72px" } }
      : entry,
  );
  assert.throws(
    () => validateCoverage(entries, manifest, manifest.sourcePackageVersion),
    /aliased token typography\.fontSize\.4xl diverges from generated token typography\.fontSize\.3xl/,
  );
});
