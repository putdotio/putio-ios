import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { listFontResources } from "./verify-font-bundles.ts";

test("finds nested font resources with case-insensitive OTF and TTF extensions", async () => {
  const root = await mkdtemp(join(tmpdir(), "putio-font-bundle-"));
  try {
    await Promise.all([
      mkdir(join(root, "nested")),
      mkdir(join(root, "Watch", "Companion.app"), { recursive: true }),
    ]);
    await Promise.all([
      writeFile(join(root, "Brand.otf"), "font"),
      writeFile(join(root, "nested", "Unexpected.TTF"), "font"),
      writeFile(join(root, "nested", "ignored.txt"), "text"),
      writeFile(join(root, "Watch", "Companion.app", "Embedded.otf"), "font"),
    ]);

    assert.deepEqual(await listFontResources(root), ["Brand.otf", "nested/Unexpected.TTF"]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
