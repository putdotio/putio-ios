#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { gunzipSync } from "node:zlib";
import process from "node:process";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const MANIFEST_PATH = join(ROOT, "Config", "PhosphorIcons.json");
const LOCK_PATH = join(ROOT, "Config", "PhosphorIcons.lock.json");
const ASSET_ROOT = join(ROOT, "Putio", "Assets.xcassets", "Phosphor");
const LICENSE_PATH = join(ROOT, "ThirdParty", "PhosphorIcons", "LICENSE");
const ALLOWED_WEIGHTS = ["regular", "fill"];
const SF_SYMBOL_PATTERN = /\bUIImage\s*\(\s*systemName\s*:/;
const SF_SYMBOL_ALLOWED_FILES = ["Putio/Features/MediaPlayers/AudioPlayerViewController.swift"];
const ICON_NAME_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

interface PackageMetadata {
  name: string;
  version: string;
  tarball: string;
  integrity: string;
}

interface Icon {
  name: string;
  weight: string;
}

interface LockedIcon {
  name: string;
  weight: string;
  asset_name: string;
  source_path: string;
  sha256: string;
}

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

class SyncError extends Error {}

function sha256(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

function formattedJson(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function relative(path: string): string {
  return path.startsWith(`${ROOT}/`) ? path.slice(ROOT.length + 1) : path;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sortedKeys(value: Record<string, unknown>): string[] {
  return Object.keys(value).sort();
}

function sourcePath(icon: Icon): string {
  const filename = icon.weight === "regular" ? `${icon.name}.svg` : `${icon.name}-${icon.weight}.svg`;
  return `package/assets/${icon.weight}/${filename}`;
}

function assetName(icon: Icon): string {
  return `${icon.name}-${icon.weight}`;
}

function groupContents(): Json {
  return {
    info: { author: "xcode", version: 1 },
    properties: { "provides-namespace": true },
  };
}

function imagesetContents(filename: string): Json {
  return {
    images: [{ filename, idiom: "universal" }],
    info: { author: "xcode", version: 1 },
    properties: {
      "preserves-vector-representation": true,
      "template-rendering-intent": "template",
    },
  };
}

function visibleEntries(directory: string): string[] {
  try {
    return readdirSync(directory)
      .filter((name) => !name.startsWith("."))
      .sort();
  } catch {
    return [];
  }
}

function imagesets(directory: string): string[] {
  return visibleEntries(directory)
    .filter((name) => name.endsWith(".imageset"))
    .map((name) => join(directory, name));
}

function swiftFiles(directory: string): string[] {
  const files: string[] = [];
  for (const name of visibleEntries(directory)) {
    const path = join(directory, name);
    const stats = statSync(path, { throwIfNoEntry: false });
    if (!stats) {
      continue;
    }
    if (stats.isDirectory()) {
      files.push(...swiftFiles(path));
    } else if (name.endsWith(".swift")) {
      files.push(path);
    }
  }
  return files;
}

function isFile(path: string): boolean {
  return statSync(path, { throwIfNoEntry: false })?.isFile() ?? false;
}

function isDirectory(path: string): boolean {
  return statSync(path, { throwIfNoEntry: false })?.isDirectory() ?? false;
}

function readJson(path: string, errors: string[]): unknown {
  let source: string;
  try {
    source = readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      errors.push(`Missing ${relative(path)}`);
      return undefined;
    }
    throw error;
  }
  try {
    return JSON.parse(source);
  } catch {
    errors.push(`Invalid JSON in ${relative(path)}`);
    return undefined;
  }
}

function tarString(block: Buffer, start: number, length: number): string {
  const field = block.subarray(start, start + length);
  const end = field.indexOf(0);
  return field.subarray(0, end === -1 ? field.length : end).toString("utf8");
}

export function archiveEntries(archive: Buffer): Map<string, Buffer> {
  const tar = gunzipSync(archive);
  const entries = new Map<string, Buffer>();
  let offset = 0;
  while (offset + 512 <= tar.length) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) {
      break;
    }
    const name = tarString(header, 0, 100);
    const size = Number.parseInt(tarString(header, 124, 12).trim() || "0", 8);
    const type = String.fromCharCode(header[156] ?? 0);
    const magic = tarString(header, 257, 6);
    const prefix = magic.startsWith("ustar") ? tarString(header, 345, 155) : "";
    const fullName = prefix === "" ? name : `${prefix}/${name}`;
    const dataStart = offset + 512;
    if (type === "0" || type === "\0") {
      entries.set(fullName, Buffer.from(tar.subarray(dataStart, dataStart + size)));
    }
    offset = dataStart + Math.ceil(size / 512) * 512;
  }
  return entries;
}

export function generatedSvg(source: Buffer): Buffer {
  const svg = source
    .toString("latin1")
    .replace("<svg ", '<svg width="16" height="16" ')
    .replaceAll("currentColor", "#000000")
    .replace(/[ \t\n\v\f\r\0]+$/, "");
  return Buffer.from(`${svg}\n`, "latin1");
}

function validateManifest(manifest: unknown): { pkg: PackageMetadata; icons: Icon[] } {
  if (!isRecord(manifest) || !("package" in manifest)) {
    throw new SyncError("key not found: \"package\"");
  }
  if (!("icons" in manifest)) {
    throw new SyncError("key not found: \"icons\"");
  }
  const pkg = manifest.package;
  const icons = manifest.icons;
  const expectedPackageKeys = ["name", "version", "tarball", "integrity"];
  if (!isRecord(pkg) || !isDeepStrictEqual(sortedKeys(pkg), [...expectedPackageKeys].sort())) {
    throw new SyncError(`Phosphor package metadata must contain ${expectedPackageKeys.join(", ")}`);
  }

  let tarball: URL | undefined;
  try {
    tarball = new URL(String(pkg.tarball));
  } catch {
    tarball = undefined;
  }
  if (tarball?.protocol !== "https:" || tarball.hostname !== "registry.npmjs.org") {
    throw new SyncError("Phosphor tarball must use the npm registry over HTTPS");
  }

  if (typeof pkg.integrity !== "string" || !pkg.integrity.startsWith("sha512-")) {
    throw new SyncError("Phosphor package integrity must be a sha512 Subresource Integrity value");
  }

  if (!Array.isArray(icons)) {
    throw new SyncError("Phosphor icons must be a list");
  }

  const seen = new Map<string, number>();
  for (const icon of icons as unknown[]) {
    if (!isRecord(icon) || !isDeepStrictEqual(sortedKeys(icon), ["name", "weight"])) {
      throw new SyncError("Every Phosphor icon must contain only name and weight");
    }
    if (typeof icon.name !== "string" || !ICON_NAME_PATTERN.test(icon.name)) {
      throw new SyncError(`Invalid Phosphor icon name: ${JSON.stringify(icon.name)}`);
    }
    if (typeof icon.weight !== "string" || !ALLOWED_WEIGHTS.includes(icon.weight)) {
      throw new SyncError(`Unsupported Phosphor icon weight: ${JSON.stringify(icon.weight)}`);
    }
    const identity = `${icon.name} ${icon.weight}`;
    seen.set(identity, (seen.get(identity) ?? 0) + 1);
  }

  for (const [identity, count] of seen) {
    if (count > 1) {
      throw new SyncError(`Duplicate Phosphor icon: ${identity}`);
    }
  }

  return { pkg: pkg as unknown as PackageMetadata, icons: icons as Icon[] };
}

class PhosphorIconSync {
  readonly pkg: PackageMetadata;
  readonly icons: Icon[];

  constructor() {
    const { pkg, icons } = validateManifest(JSON.parse(readFileSync(MANIFEST_PATH, "utf8")));
    this.pkg = pkg;
    this.icons = icons;
  }

  lockedPackage(): Json {
    return { name: this.pkg.name, version: this.pkg.version, integrity: this.pkg.integrity };
  }

  async sync(): Promise<void> {
    const archive = await this.downloadArchive();
    this.verifyArchiveIntegrity(archive);
    const entries = archiveEntries(archive);

    mkdirSync(ASSET_ROOT, { recursive: true });
    writeFileSync(join(ASSET_ROOT, "Contents.json"), formattedJson(groupContents()));

    const generatedIcons = this.icons.map((icon) => {
      const path = sourcePath(icon);
      const source = entries.get(path);
      if (!source) {
        throw new SyncError(`Missing ${path} in ${this.pkg.name} ${this.pkg.version}`);
      }
      return this.writeIcon(icon, source, path);
    });

    this.removeUnlistedAssets(generatedIcons.map((icon) => icon.asset_name));

    const license = entries.get("package/LICENSE");
    if (!license) {
      throw new SyncError("key not found: \"package/LICENSE\"");
    }
    mkdirSync(dirname(LICENSE_PATH), { recursive: true });
    writeFileSync(LICENSE_PATH, license);

    const lock = {
      package: this.lockedPackage(),
      license_sha256: sha256(license),
      icons: generatedIcons,
    };
    writeFileSync(LOCK_PATH, formattedJson(lock));

    this.check();
  }

  check(): void {
    const errors: string[] = [];
    const lock = readJson(LOCK_PATH, errors);
    this.checkGroupContents(errors);
    this.checkLicense(lock, errors);
    this.checkIcons(lock, errors);
    this.checkSourcePolicy(errors);

    if (errors.length > 0) {
      console.error(errors.map((error) => `- ${error}`).join("\n"));
      console.error("Run mise run icons-sync to regenerate the pinned Phosphor assets.");
      process.exit(1);
    }

    console.log(`Verified ${this.icons.length} pinned Phosphor icon assets.`);
  }

  async downloadArchive(): Promise<Buffer> {
    const response = await fetch(this.pkg.tarball, { redirect: "manual" });
    if (response.status < 200 || response.status > 299) {
      throw new SyncError(`Unable to download Phosphor package: HTTP ${response.status}`);
    }
    return Buffer.from(await response.arrayBuffer());
  }

  verifyArchiveIntegrity(archive: Buffer): void {
    const actual = `sha512-${createHash("sha512").update(archive).digest("base64")}`;
    if (actual !== this.pkg.integrity) {
      throw new SyncError("Phosphor package integrity mismatch");
    }
  }

  writeIcon(icon: Icon, source: Buffer, path: string): LockedIcon {
    const name = assetName(icon);
    const directory = join(ASSET_ROOT, `${name}.imageset`);
    const filename = `${name}.svg`;
    const svg = generatedSvg(source);

    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, filename), svg);
    writeFileSync(join(directory, "Contents.json"), formattedJson(imagesetContents(filename)));

    return {
      name: icon.name,
      weight: icon.weight,
      asset_name: name,
      source_path: path,
      sha256: sha256(svg),
    };
  }

  removeUnlistedAssets(assetNames: string[]): void {
    const expected = new Set(assetNames.map((name) => join(ASSET_ROOT, `${name}.imageset`)));
    for (const directory of imagesets(ASSET_ROOT)) {
      if (!expected.has(directory)) {
        rmSync(directory, { recursive: true, force: true });
      }
    }
  }

  checkGroupContents(errors: string[]): void {
    const actual = readJson(join(ASSET_ROOT, "Contents.json"), errors);
    if (actual !== undefined && actual !== null && actual !== false && !isDeepStrictEqual(actual, groupContents())) {
      errors.push("Phosphor asset group metadata is stale");
    }
  }

  checkLicense(lock: unknown, errors: string[]): void {
    if (!isFile(LICENSE_PATH)) {
      errors.push("Missing Phosphor MIT license");
      return;
    }
    if (!isRecord(lock)) {
      return;
    }
    if (sha256(readFileSync(LICENSE_PATH)) !== lock.license_sha256) {
      errors.push("Phosphor license checksum does not match the lock file");
    }
  }

  checkIcons(lock: unknown, errors: string[]): void {
    if (!isRecord(lock)) {
      return;
    }

    if (!isDeepStrictEqual(lock.package, this.lockedPackage())) {
      errors.push("Phosphor lock package metadata is stale");
    }

    const lockedIcons: unknown[] = Array.isArray(lock.icons) ? lock.icons : lock.icons == null ? [] : [lock.icons];
    const lockedEntries = lockedIcons.map((icon) => (isRecord(icon) ? icon : {}));
    const expectedAssetNames = this.icons.map(assetName);
    const lockedAssetNames = lockedEntries.map((icon) => icon.asset_name ?? null);
    if (!isDeepStrictEqual(lockedAssetNames, expectedAssetNames)) {
      errors.push("Phosphor lock icon list is stale");
    }

    for (const icon of this.icons) {
      const name = assetName(icon);
      const locked = lockedEntries.find((candidate) => candidate.asset_name === name);
      if (!locked) {
        errors.push(`Missing lock entry for ${name}`);
        continue;
      }

      if (locked.source_path !== sourcePath(icon)) {
        errors.push(`Unexpected source path for ${name}`);
      }

      const directory = join(ASSET_ROOT, `${name}.imageset`);
      const filename = `${name}.svg`;
      const svgPath = join(directory, filename);

      if (!isFile(svgPath)) {
        errors.push(`Missing generated SVG for ${name}`);
        continue;
      }
      if (sha256(readFileSync(svgPath)) !== locked.sha256) {
        errors.push(`Generated SVG checksum mismatch for ${name}`);
      }

      const contents = readJson(join(directory, "Contents.json"), errors);
      if (contents !== undefined && contents !== null && contents !== false && !isDeepStrictEqual(contents, imagesetContents(filename))) {
        errors.push(`Asset metadata is stale for ${name}`);
      }
    }

    const actualAssetNames = imagesets(ASSET_ROOT)
      .map((path) => basename(path, ".imageset"))
      .sort();
    if (!isDeepStrictEqual(actualAssetNames, [...expectedAssetNames].sort())) {
      errors.push("Phosphor asset catalog contains unlisted image sets");
    }
  }

  checkSourcePolicy(errors: string[]): void {
    const symbolFiles = swiftFiles(join(ROOT, "Putio"))
      .filter((path) => SF_SYMBOL_PATTERN.test(readFileSync(path, "utf8")))
      .filter((path) => !SF_SYMBOL_ALLOWED_FILES.includes(relative(path)));
    if (symbolFiles.length > 0) {
      errors.push(`SF Symbols are not allowed: ${symbolFiles.map(relative).join(", ")}`);
    }

    const assetsRoot = join(ROOT, "Putio", "Assets.xcassets");
    const legacyAssets = imagesets(assetsRoot).filter((path) => {
      const name = basename(path, ".imageset");
      return (name.startsWith("icon") && name !== "iconOffline") || ["chevronLeft", "eye"].includes(name);
    });
    const tabbarAssets = join(assetsRoot, "tabbarIcons");
    if (isDirectory(tabbarAssets)) {
      legacyAssets.push(tabbarAssets);
    }
    if (legacyAssets.length > 0) {
      errors.push(`Legacy icon catalogs are not allowed: ${legacyAssets.map(relative).join(", ")}`);
    }
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  try {
    if (args.length === 0) {
      await new PhosphorIconSync().sync();
    } else if (args.length === 1 && args[0] === "--check") {
      new PhosphorIconSync().check();
    } else {
      console.error("Usage: node scripts/sync-phosphor-icons.ts [--check]");
      process.exit(2);
    }
  } catch (error) {
    if (error instanceof SyncError) {
      console.error(`sync-phosphor-icons: ${error.message}`);
      process.exit(1);
    }
    throw error;
  }
}
