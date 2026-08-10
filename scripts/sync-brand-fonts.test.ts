import assert from "node:assert/strict";
import test from "node:test";

import { parseFontManifest } from "./sync-brand-fonts.ts";

const manifest = () => ({
  baseUrl: "https://static.put.io",
  directory: "Resources/BrandFonts",
  files: {
    "gt-america-standard-regular.otf": {
      path: "fonts/gt-america/regular.otf",
      sha256: "a".repeat(64),
      platforms: ["ios", "watchos", "tvos"],
    },
    "gt-america-standard-medium.otf": {
      path: "fonts/gt-america/medium.otf",
      sha256: "b".repeat(64),
      platforms: ["ios", "watchos", "tvos"],
    },
    "gt-america-standard-bold.otf": {
      path: "fonts/gt-america/bold.otf",
      sha256: "c".repeat(64),
      platforms: ["ios", "watchos", "tvos"],
    },
    "gt-america-standard-black.otf": {
      path: "fonts/gt-america/black.otf",
      sha256: "d".repeat(64),
      platforms: ["ios", "watchos", "tvos"],
    },
    "berkeley-mono-variable.otf": {
      path: "fonts/berkeley-mono/variable.otf",
      sha256: "e".repeat(64),
      platforms: ["ios", "watchos"],
    },
  },
});

test("accepts the complete checksummed three-shell font contract", () => {
  const parsed = parseFontManifest(manifest());
  assert.deepEqual(parsed.files["berkeley-mono-variable.otf"]?.platforms, ["ios", "watchos"]);
});

test("rejects Berkeley Mono on tvOS", () => {
  const value = manifest();
  value.files["berkeley-mono-variable.otf"].platforms.push("tvos");
  assert.throws(() => parseFontManifest(value), /invalid platform scope/);
});

test("rejects font downloads outside the approved origin", () => {
  const value = manifest();
  value.baseUrl = "https://example.com";
  assert.throws(() => parseFontManifest(value), /approved https:\/\/static\.put\.io origin/);
});
