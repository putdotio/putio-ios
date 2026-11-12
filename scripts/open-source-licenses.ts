import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type Notice = {
  name: string;
  license: string;
  copyright: string;
  source?: string;
  licenseText: string;
};

export type LicenseConfig = {
  app: Notice;
  packages: Record<string, Notice>;
  testOnly: string[];
};

export type LicensedPackage = Notice & { version: string };

export type LicenseManifest = {
  app: Notice;
  packages: LicensedPackage[];
};

type ResolvedFile = {
  pins: { identity: string; state: { version?: string } }[];
};

export const configPath = "Config/OpenSourceLicenses.json";
export const outputPath = "Apps/iOS/Generated/OpenSourceLicenses.json";
const resolvedFiles = ["Packages/PutioCore/Package.resolved", "Tuist/Package.resolved"];
const appPackage = "PutioCore";

const httpsURL = (value: unknown, field: string): string => {
  if (typeof value !== "string" || !URL.canParse(value) || new URL(value).protocol !== "https:") {
    throw new Error(`${field} must be an https URL`);
  }
  return value;
};

const text = (value: unknown, field: string): string => {
  if (typeof value !== "string" || value.trim() === "") throw new Error(`${field} must be text`);
  return value;
};

export const parseNotice = (value: unknown, field: string): Notice => {
  if (typeof value !== "object" || value === null) throw new Error(`${field} must be an object`);
  const entry = value as Record<string, unknown>;
  const notice: Notice = {
    name: text(entry.name, `${field}.name`),
    license: text(entry.license, `${field}.license`),
    copyright: text(entry.copyright, `${field}.copyright`),
    licenseText: httpsURL(entry.licenseText, `${field}.licenseText`),
  };
  if (entry.source !== undefined) notice.source = httpsURL(entry.source, `${field}.source`);
  return notice;
};

export const parseConfig = (value: unknown): LicenseConfig => {
  if (typeof value !== "object" || value === null) throw new Error(`${configPath} must be an object`);
  const config = value as Record<string, unknown>;
  const packages = config.packages;
  if (typeof packages !== "object" || packages === null) throw new Error("packages must be an object");
  const testOnly = config.testOnly;
  if (!Array.isArray(testOnly) || !testOnly.every((item) => typeof item === "string")) {
    throw new Error("testOnly must list package identities");
  }
  return {
    app: parseNotice(config.app, "app"),
    packages: Object.fromEntries(
      Object.entries(packages).map(([identity, notice]) => [identity, parseNotice(notice, identity)]),
    ),
    testOnly,
  };
};

export const resolvedPins = (files: string[]): Map<string, string> => {
  const versions = new Map<string, string>();
  for (const file of files) {
    const resolved = JSON.parse(file) as ResolvedFile;
    for (const pin of resolved.pins) {
      if (pin.state.version === undefined) throw new Error(`${pin.identity} is not pinned to a version`);
      versions.set(pin.identity, pin.state.version);
    }
  }
  return versions;
};

export const binaryTargetVersion = (manifest: string, identity: string): string => {
  const url = /\burl:\s*"([^"]+)"/.exec(manifest)?.[1];
  const version = url === undefined ? undefined : /(\d+\.\d+\.\d+)/.exec(url)?.[1];
  if (version === undefined) throw new Error(`${identity} names no versioned binary target URL`);
  return version;
};

export const buildManifest = (config: LicenseConfig, resolved: Map<string, string>): LicenseManifest => {
  const problems: string[] = [];
  for (const identity of config.testOnly) {
    if (!resolved.has(identity)) problems.push(`${identity} is listed as test-only but is not resolved`);
    if (identity in config.packages) problems.push(`${identity} is both bundled and test-only`);
  }
  for (const identity of Object.keys(config.packages)) {
    if (!resolved.has(identity)) problems.push(`${identity} has a notice but is not resolved`);
  }
  const bundled = [...resolved.keys()].filter((identity) => !config.testOnly.includes(identity));
  for (const identity of bundled) {
    if (!(identity in config.packages)) problems.push(`${identity} is bundled but has no notice`);
  }
  if (problems.length > 0) {
    throw new Error(`${configPath} does not match the resolved packages\n${problems.join("\n")}`);
  }
  const packages = bundled
    .map((identity) => ({ ...config.packages[identity], version: resolved.get(identity) as string }))
    .sort((a, b) => a.name.localeCompare(b.name, "en", { sensitivity: "base" }));
  return { app: config.app, packages };
};

export const resolveRepository = async (root: string): Promise<Map<string, string>> => {
  const resolved = resolvedPins(
    await Promise.all(resolvedFiles.map((file) => readFile(join(root, file), "utf8"))),
  );
  const local = await readdir(join(root, "Packages"), { withFileTypes: true });
  for (const entry of local) {
    if (!entry.isDirectory() || entry.name === appPackage) continue;
    const manifest = await readFile(join(root, "Packages", entry.name, "Package.swift"), "utf8");
    resolved.set(entry.name, binaryTargetVersion(manifest, entry.name));
  }
  return resolved;
};

export const generate = async (root: string): Promise<LicenseManifest> => {
  const config = parseConfig(JSON.parse(await readFile(join(root, configPath), "utf8")));
  const manifest = buildManifest(config, await resolveRepository(root));
  await mkdir(dirname(join(root, outputPath)), { recursive: true });
  await writeFile(join(root, outputPath), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
};

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const manifest = await generate(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
    console.log(`${manifest.packages.length} bundled packages written to ${outputPath}`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
