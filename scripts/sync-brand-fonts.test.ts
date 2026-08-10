import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  approvedFontURL,
  findUnlistedFontFiles,
  parseFontManifest,
  removeUnlistedFontFiles,
} from "./sync-brand-fonts.ts";

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

test("rejects absolute font paths and redirects outside the approved origin", () => {
  const value = manifest();
  value.files["gt-america-standard-regular.otf"].path = "https://example.com/regular.otf";
  assert.throws(() => parseFontManifest(value), /must stay on https:\/\/static\.put\.io/);
  assert.throws(
    () => approvedFontURL("https://cdn.example.com/redirected.otf"),
    /must stay on https:\/\/static\.put\.io/,
  );
});

test("classifies every unlisted OTF or TTF regardless of filename prefix", async () => {
  const directory = await mkdtemp(join(tmpdir(), "putio-font-test-"));
  try {
    await mkdir(join(directory, "nested"));
    await Promise.all([
      writeFile(join(directory, "OtherFont.otf"), "font"),
      writeFile(join(directory, "another.ttf"), "font"),
      writeFile(join(directory, "notes.txt"), "not a font"),
      writeFile(join(directory, "nested", "DeepFont.otf"), "font"),
    ]);
    const extras = [
      "OtherFont.otf",
      "another.ttf",
      "nested/DeepFont.otf",
    ];
    assert.deepEqual(await findUnlistedFontFiles(directory, new Set()), extras);
    assert.deepEqual(await removeUnlistedFontFiles(directory, new Set()), extras);
    assert.deepEqual(await findUnlistedFontFiles(directory, new Set()), []);
    assert.equal(await readFile(join(directory, "notes.txt"), "utf8"), "not a font");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
