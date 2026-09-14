import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

test("font checks allow absent and partial sets but reject corrupt installed files", async () => {
  const root = await mkdtemp(join(tmpdir(), "putio-font-check-"));
  try {
    await mkdir(join(root, "scripts"));
    await mkdir(join(root, "Config"));
    await copyFile(new URL("./sync-brand-fonts.ts", import.meta.url), join(root, "scripts/sync-brand-fonts.ts"));
    const bytes = Buffer.from("test font");
    const entry = { path: "fonts/test.otf", sha256: createHash("sha256").update(bytes).digest("hex") };
    await writeFile(join(root, "Config/BrandFonts.json"), JSON.stringify({
      baseUrl: "https://static.put.io",
      directory: "Resources/BrandFonts",
      files: { "gt-america-regular.otf": entry, "gt-america-bold.otf": entry },
    }));
    const check = () => spawnSync(process.execPath, [join(root, "scripts/sync-brand-fonts.ts"), "--check"], { encoding: "utf8" });
    assert.equal(check().status, 0, "absent directory is optional");
    const fonts = join(root, "Resources/BrandFonts");
    await mkdir(fonts, { recursive: true });
    assert.equal(check().status, 0, "empty directory is optional");
    await writeFile(join(fonts, "gt-america-regular.otf"), bytes);
    assert.equal(check().status, 0, "partial valid set is usable");
    await writeFile(join(fonts, "gt-america-bold.otf"), bytes);
    assert.equal(check().status, 0, "complete valid set passes");
    await writeFile(join(fonts, "gt-america-bold.otf"), "corrupt");
    const invalid = check();
    assert.equal(invalid.status, 1);
    assert.match(invalid.stderr, /checksum mismatch: gt-america-bold.otf/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
