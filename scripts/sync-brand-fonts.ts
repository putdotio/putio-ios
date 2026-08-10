import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type Platform = "ios" | "watchos" | "tvos";

type FontEntry = {
  path: string;
  sha256: string;
  platforms: readonly Platform[];
};

type FontManifest = {
  baseUrl: string;
  directory: string;
  files: Readonly<Record<string, FontEntry>>;
};

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const manifestPath = join(repositoryRoot, "Config", "BrandFonts.json");
const bundledFontPattern = /^(?:gt-america|berkeley-mono)-.*\.otf$/i;
const fontBinaryPattern = /\.(?:otf|ttf)$/i;
const approvedOrigin = "https://static.put.io";
const expectedPlatforms = new Map<string, readonly Platform[]>([
  ["gt-america-standard-regular.otf", ["ios", "watchos", "tvos"]],
  ["gt-america-standard-medium.otf", ["ios", "watchos", "tvos"]],
  ["gt-america-standard-bold.otf", ["ios", "watchos", "tvos"]],
  ["gt-america-standard-black.otf", ["ios", "watchos", "tvos"]],
  ["berkeley-mono-variable.otf", ["ios", "watchos"]],
]);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isPlatform = (value: unknown): value is Platform =>
  value === "ios" || value === "watchos" || value === "tvos";

export const approvedFontURL = (path: string): URL => {
  const url = new URL(path, `${approvedOrigin}/`);
  if (
    url.origin !== approvedOrigin ||
    url.protocol !== "https:" ||
    url.username !== "" ||
    url.password !== ""
  ) {
    throw new Error(`brand font URL must stay on ${approvedOrigin}: ${path}`);
  }
  return url;
};

export const parseFontManifest = (value: unknown): FontManifest => {
  if (!isRecord(value) || typeof value.baseUrl !== "string" || typeof value.directory !== "string") {
    throw new Error("BrandFonts.json must define baseUrl and directory");
  }
  if (!isRecord(value.files) || Object.keys(value.files).length === 0) {
    throw new Error("BrandFonts.json must define at least one font");
  }
  if (value.baseUrl !== approvedOrigin) {
    throw new Error("BrandFonts.json must use the approved https://static.put.io origin");
  }
  if (value.directory !== "Resources/BrandFonts") {
    throw new Error("BrandFonts.json must use the ignored Resources/BrandFonts directory");
  }
  const actualNames = Object.keys(value.files).sort();
  const requiredNames = [...expectedPlatforms.keys()].sort();
  if (actualNames.join("\n") !== requiredNames.join("\n")) {
    throw new Error("BrandFonts.json must classify the complete native font set");
  }

  const files: Record<string, FontEntry> = {};
  for (const [name, rawEntry] of Object.entries(value.files)) {
    if (!bundledFontPattern.test(name) || basename(name) !== name || !isRecord(rawEntry)) {
      throw new Error(`invalid brand font entry: ${name}`);
    }
    const platforms = rawEntry.platforms;
    if (
      typeof rawEntry.path !== "string" ||
      !/^[a-f0-9]{64}$/.test(String(rawEntry.sha256)) ||
      !Array.isArray(platforms) ||
      platforms.length === 0 ||
      platforms.some((platform) => !isPlatform(platform)) ||
      rawEntry.path.startsWith("/") ||
      rawEntry.path.split("/").includes("..")
    ) {
      throw new Error(`invalid brand font metadata: ${name}`);
    }
    approvedFontURL(rawEntry.path);
    const expected = expectedPlatforms.get(name) ?? [];
    const actual = platforms.map(String).sort();
    if (actual.join("\n") !== [...expected].sort().join("\n")) {
      throw new Error(`invalid platform scope for ${name}`);
    }
    files[name] = {
      path: rawEntry.path,
      sha256: String(rawEntry.sha256),
      platforms: platforms.filter(isPlatform),
    };
  }

  return { baseUrl: value.baseUrl, directory: value.directory, files };
};

const sha256 = (bytes: Uint8Array): string => createHash("sha256").update(bytes).digest("hex");

const readIfPresent = async (path: string): Promise<Uint8Array | undefined> => {
  try {
    return await readFile(path);
  } catch (error) {
    if (isRecord(error) && error.code === "ENOENT") return undefined;
    throw error;
  }
};

const loadManifest = async (): Promise<FontManifest> =>
  parseFontManifest(JSON.parse(await readFile(manifestPath, "utf8")) as unknown);

export const findUnlistedFontFiles = async (
  directory: string,
  listed: ReadonlySet<string>,
): Promise<string[]> => {
  try {
    const visit = async (current: string, prefix = ""): Promise<string[]> => {
      const entries = await readdir(current, { withFileTypes: true });
      const paths = await Promise.all(
        entries.map(async (entry): Promise<string[]> => {
          const relativePath = join(prefix, entry.name);
          if (entry.isDirectory()) return visit(join(current, entry.name), relativePath);
          return fontBinaryPattern.test(entry.name) && !listed.has(relativePath)
            ? [relativePath]
            : [];
        }),
      );
      return paths.flat();
    };
    return (await visit(directory)).sort();
  } catch (error) {
    if (isRecord(error) && error.code === "ENOENT") return [];
    throw error;
  }
};

export const removeUnlistedFontFiles = async (
  directory: string,
  listed: ReadonlySet<string>,
): Promise<string[]> => {
  const extras = await findUnlistedFontFiles(directory, listed);
  for (const name of extras) await rm(join(directory, name), { force: true });
  return extras;
};

const inspect = async (manifest: FontManifest) => {
  const directory = join(repositoryRoot, manifest.directory);
  const missing: string[] = [];
  const mismatched: string[] = [];

  for (const [name, entry] of Object.entries(manifest.files)) {
    const bytes = await readIfPresent(join(directory, name));
    if (!bytes) missing.push(name);
    else if (sha256(bytes) !== entry.sha256) mismatched.push(name);
  }

  return {
    directory,
    missing,
    mismatched,
    unlisted: await findUnlistedFontFiles(directory, new Set(Object.keys(manifest.files))),
  };
};

const check = async (manifest: FontManifest): Promise<void> => {
  const report = await inspect(manifest);
  const problems = [
    report.missing.length > 0 ? `missing: ${report.missing.join(", ")}` : "",
    report.mismatched.length > 0 ? `mismatched: ${report.mismatched.join(", ")}` : "",
    report.unlisted.length > 0 ? `unlisted: ${report.unlisted.join(", ")}` : "",
  ].filter(Boolean);

  if (problems.length > 0) {
    throw new Error(
      `brand fonts do not match Config/BrandFonts.json\n${problems.map((line) => `  ${line}`).join("\n")}\n  fix: mise run fonts-setup`,
    );
  }

  console.log(`${Object.keys(manifest.files).length} brand fonts match Config/BrandFonts.json`);
};

const download = async (url: URL, redirectsRemaining = 3): Promise<Uint8Array> => {
  approvedFontURL(url.href);
  const response = await fetch(url, { redirect: "manual" });
  if (response.status >= 300 && response.status < 400) {
    if (redirectsRemaining === 0) throw new Error(`too many redirects fetching ${url.href}`);
    const location = response.headers.get("location");
    if (!location) throw new Error(`${url.href} redirected without a Location header`);
    return download(approvedFontURL(new URL(location, url).href), redirectsRemaining - 1);
  }
  if (!response.ok) throw new Error(`${url.href} returned ${response.status} ${response.statusText}`);
  return new Uint8Array(await response.arrayBuffer());
};

const sync = async (manifest: FontManifest): Promise<void> => {
  const directory = join(repositoryRoot, manifest.directory);
  await mkdir(directory, { recursive: true });

  const extras = await removeUnlistedFontFiles(directory, new Set(Object.keys(manifest.files)));
  for (const name of extras) {
    console.log(`removed unlisted font ${name}`);
  }

  for (const [name, entry] of Object.entries(manifest.files)) {
    const path = join(directory, name);
    const existing = await readIfPresent(path);
    if (existing && sha256(existing) === entry.sha256) continue;

    const bytes = await download(approvedFontURL(entry.path));
    const actual = sha256(bytes);
    if (actual !== entry.sha256) {
      throw new Error(`${name} checksum mismatch: expected ${entry.sha256}, received ${actual}`);
    }

    const temporary = `${path}.download`;
    await writeFile(temporary, bytes, { mode: 0o644 });
    await rename(temporary, path);
    console.log(`downloaded ${name}`);
  }

  const report = await inspect(manifest);
  if (report.unlisted.length > 0) {
    throw new Error(`unlisted brand fonts: ${report.unlisted.join(", ")}`);
  }
  await check(manifest);
};

const main = async (): Promise<void> => {
  const manifest = await loadManifest();
  if (process.argv.includes("--check")) await check(manifest);
  else await sync(manifest);
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(async (error: unknown) => {
    const manifest = await loadManifest().catch(() => undefined);
    if (manifest) {
      const directory = join(repositoryRoot, manifest.directory);
      for (const name of Object.keys(manifest.files)) {
        await rm(join(directory, `${name}.download`), { force: true });
      }
    }
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
