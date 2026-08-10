import { execFile } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { dirname, extname, join, relative, resolve } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";

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

export const listFontResources = async (root: string): Promise<string[]> => {
  const resources: string[] = [];

  const visit = async (directory: string): Promise<void> => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory() && extname(entry.name).toLowerCase() !== ".app") {
        await visit(path);
      } else if ([".otf", ".ttf"].includes(extname(entry.name).toLowerCase())) {
        resources.push(relative(root, path));
      }
    }
  };

  await visit(root);
  return resources.sort();
};

const verifyApp = async (
  label: string,
  relativePath: string,
  platform: Platform,
): Promise<void> => {
  const app = join(repositoryRoot, relativePath);
  const actualFiles = await listFontResources(app);
  const expected = expectedNames(platform);
  if (actualFiles.join("\n") !== expected.join("\n")) {
    throw new Error(
      `${label} font resources differ\nexpected:\n${expected.join("\n")}\nactual:\n${actualFiles.join("\n")}`,
    );
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
    throw new Error(
      `${label} UIAppFonts differs\nexpected:\n${expected.join("\n")}\nactual:\n${registered.join("\n")}`,
    );
  }
};

const main = async (): Promise<void> => {
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
};

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main();
}
