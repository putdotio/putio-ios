import { execFile } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

import { parseFontManifest, type Platform } from "./sync-brand-fonts.ts";

const execFileAsync = promisify(execFile);
const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const manifest = parseFontManifest(
  JSON.parse(await readFile(join(repositoryRoot, "Config/BrandFonts.json"), "utf8")) as unknown,
);

const expectedNames = (platform: Platform): string[] =>
  Object.entries(manifest.files)
    .filter(([, entry]) => entry.platforms.includes(platform))
    .map(([name]) => name)
    .sort();

const verifyApp = async (
  label: string,
  relativePath: string,
  platform: Platform,
): Promise<void> => {
  const app = join(repositoryRoot, relativePath);
  const actualFiles = (await readdir(app)).filter((name) => name.endsWith(".otf")).sort();
  const expected = expectedNames(platform);
  if (actualFiles.join("\n") !== expected.join("\n")) {
    throw new Error(`${label} font resources differ\nexpected: ${expected}\nactual: ${actualFiles}`);
  }

  const { stdout } = await execFileAsync("plutil", [
    "-extract",
    "UIAppFonts",
    "json",
    "-o",
    "-",
    join(app, "Info.plist"),
  ]);
  const parsed: unknown = JSON.parse(stdout);
  if (!Array.isArray(parsed) || parsed.some((name) => typeof name !== "string")) {
    throw new Error(`${label} UIAppFonts is not a string array`);
  }
  const registered = parsed.map(String).sort();
  if (registered.join("\n") !== expected.join("\n")) {
    throw new Error(`${label} UIAppFonts differs\nexpected: ${expected}\nactual: ${registered}`);
  }
};

await verifyApp(
  "iOS",
  "build/DerivedData/Build/Products/Debug-iphonesimulator/Putio.app",
  "ios",
);
await verifyApp(
  "embedded watchOS",
  "build/DerivedData/Build/Products/Debug-iphonesimulator/Putio.app/Watch/PutioWatch.app",
  "watchos",
);
await verifyApp(
  "watchOS",
  "build/DerivedData/Build/Products/Debug-watchsimulator/PutioWatch.app",
  "watchos",
);
await verifyApp(
  "tvOS",
  "build/DerivedData/Build/Products/Debug-appletvsimulator/PutioTV.app",
  "tvos",
);

console.log("iOS, embedded watchOS, standalone watchOS, and tvOS font bundles match the manifest");
