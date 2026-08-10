import { createHash } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type FontEntry = {
  path: string;
  sha256: string;
};

type FontManifest = {
  baseUrl: string;
  directory: string;
  files: Record<string, FontEntry>;
};

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const manifest = JSON.parse(
  await readFile(join(root, "Config/BrandFonts.json"), "utf8"),
) as FontManifest;
const directory = join(root, manifest.directory);

if (manifest.baseUrl !== "https://static.put.io") {
  throw new Error("Config/BrandFonts.json must use https://static.put.io");
}
if (manifest.directory !== "Resources/BrandFonts") {
  throw new Error("Config/BrandFonts.json must use Resources/BrandFonts");
}

const digest = (bytes: Uint8Array): string =>
  createHash("sha256").update(bytes).digest("hex");

const localDigest = async (path: string): Promise<string | undefined> => {
  try {
    return digest(await readFile(path));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
};

const verify = async (): Promise<void> => {
  const problems: string[] = [];
  for (const [name, entry] of Object.entries(manifest.files)) {
    const actual = await localDigest(join(directory, name));
    if (!actual) problems.push(`missing: ${name}`);
    else if (actual !== entry.sha256) problems.push(`checksum mismatch: ${name}`);
  }
  if (problems.length > 0) {
    throw new Error(
      `brand fonts do not match Config/BrandFonts.json\n${problems.join("\n")}\nrun mise run fonts-setup`,
    );
  }
  console.log(`${Object.keys(manifest.files).length} brand fonts match Config/BrandFonts.json`);
};

const sync = async (): Promise<void> => {
  await mkdir(directory, { recursive: true });
  for (const [name, entry] of Object.entries(manifest.files)) {
    const destination = join(directory, name);
    if ((await localDigest(destination)) === entry.sha256) continue;

    const url = new URL(entry.path, `${manifest.baseUrl}/`);
    if (url.origin !== manifest.baseUrl) {
      throw new Error(`font URL must stay on ${manifest.baseUrl}: ${entry.path}`);
    }
    const response = await fetch(url);
    if (!response.ok) throw new Error(`${url.href} returned ${response.status}`);
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (digest(bytes) !== entry.sha256) {
      throw new Error(`${name} does not match its pinned checksum`);
    }

    const temporary = `${destination}.download`;
    await writeFile(temporary, bytes);
    await rename(temporary, destination);
    console.log(`downloaded ${name}`);
  }
  await verify();
};

try {
  if (process.argv.includes("--check")) await verify();
  else await sync();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
