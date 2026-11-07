#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export type Entry = readonly [title: string, license: string];

type Pin = Readonly<{ identity: string; location: string; state: Readonly<{ revision: string }> }>;
type Artifact = Readonly<{ path: string; source?: Readonly<{ url?: string }> }>;
type CastIndexItem = Readonly<{ name: string; offset: number; size: number }>;

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RESOLVED_PATH = join(ROOT, "Putio.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved");
const PLIST_PATH = join(ROOT, "Putio", "Features", "Settings", "About", "Acknowledgements.plist");

const APP_PACKAGES: Readonly<Record<string, string>> = {
  "intercom-ios-sp": "Intercom",
  keychainaccess: "KeychainAccess",
  "posthog-ios": "PostHog",
  "putio-sdk-swift": "PutioSDK",
  "realm-core": "Realm Core",
  "realm-swift": "RealmSwift",
  "sentry-cocoa": "Sentry",
};
const TEST_PACKAGES: readonly string[] = ["swift-custom-dump", "swift-issue-reporting", "swift-snapshot-testing", "swift-syntax"];

const LOCAL_LICENSES: Readonly<Record<string, string>> = {
  "Phosphor Icons": "ThirdParty/PhosphorIcons/LICENSE",
  StatefulViewController: "ThirdParty/StatefulViewController/LICENSE",
};

const CAST_PACKAGE = join(ROOT, "ThirdParty", "GoogleCast", "Package.swift");
const CAST_TERMS: Entry = ["Google Cast SDK", "https://developers.google.com/terms/"];

const LICENSE_NAMES = ["LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE"];

function fail(message: string): never {
  process.stderr.write(`sync-acknowledgements: ${message}\n`);
  process.exit(1);
}

function isDirectory(path: string): boolean {
  return statSync(path, { throwIfNoEntry: false })?.isDirectory() ?? false;
}

function isFile(path: string): boolean {
  return statSync(path, { throwIfNoEntry: false })?.isFile() ?? false;
}

function required<T>(value: T | undefined | null, key: string): T {
  if (value === undefined || value === null) throw new Error(`key not found: "${key}"`);
  return value;
}

export function normalize(text: string): string {
  return text
    .replaceAll("\r\n", "\n")
    .replace(/[ \t]+(?=\n|$)/g, "")
    .replace(/^\n+/, "")
    .replace(/[\0\t\n\v\f\r ]+$/, "");
}

function escape(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

export function render(entries: readonly Entry[]): string {
  const items = entries
    .map(
      ([title, license]) =>
        `\t<dict>\n\t\t<key>license</key>\n\t\t<string>${escape(license)}</string>\n` +
        `\t\t<key>title</key>\n\t\t<string>${escape(title)}</string>\n\t</dict>\n`,
    )
    .join("")
    .replace(/\r?\n$|\r$/, "");
  return (
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
    '<plist version="1.0">\n' +
    "<array>\n" +
    `${items}\n` +
    "</array>\n" +
    "</plist>\n"
  );
}

export function sortEntries(entries: readonly Entry[]): Entry[] {
  return [...entries].sort(([a], [b]) => Buffer.compare(Buffer.from(a.toLowerCase()), Buffer.from(b.toLowerCase())));
}

let sourcePackageDirsCache: string[] | undefined;

function sourcePackageDirs(): string[] {
  if (sourcePackageDirsCache) return sourcePackageDirsCache;
  const override = process.env["PUTIO_SOURCE_PACKAGES"];
  if (override !== undefined) {
    sourcePackageDirsCache = [override];
    return sourcePackageDirsCache;
  }
  const derivedData = join(process.env["HOME"] ?? homedir(), "Library", "Developer", "Xcode", "DerivedData");
  let names: string[] = [];
  try {
    names = readdirSync(derivedData);
  } catch {
    names = [];
  }
  sourcePackageDirsCache = names
    .filter((name) => name.startsWith("Putio-"))
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map((name) => join(derivedData, name, "SourcePackages"))
    .filter((path) => existsSync(path));
  return sourcePackageDirsCache;
}

function gitHead(path: string): string {
  const result = spawnSync("git", ["-C", path, "rev-parse", "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  return (result.stdout ?? "").trim();
}

function licenseIn(dir: string): string {
  const path = LICENSE_NAMES.map((name) => join(dir, name)).find(isFile) ?? fail(`no license file in ${dir}`);
  return normalize(readFileSync(path, "utf8"));
}

function checkoutFor(pin: Pin): string {
  const name = basename(required(pin.location, "location"), ".git");
  const revision = required(required(pin.state, "state").revision, "revision");
  const checkout = sourcePackageDirs()
    .map((dir) => join(dir, "checkouts", name))
    .find((path) => isDirectory(path) && gitHead(path) === revision);
  return checkout ?? fail(`no checkout of ${name} at ${revision.slice(0, 7)}; resolve packages first (mise run bootstrap)`);
}

function packageEntries(): Entry[] {
  const pins = required((JSON.parse(readFileSync(RESOLVED_PATH, "utf8")) as { pins?: Pin[] }).pins, "pins");
  const known = new Set([...Object.keys(APP_PACKAGES), ...TEST_PACKAGES]);
  const unknown = pins.map((pin) => required(pin.identity, "identity")).filter((identity) => !known.has(identity));
  if (unknown.length > 0) fail(`classify ${unknown.join(", ")} in APP_PACKAGES or TEST_PACKAGES`);

  return pins.flatMap((pin): Entry[] => {
    const title = Object.hasOwn(APP_PACKAGES, pin.identity) ? APP_PACKAGES[pin.identity] : undefined;
    if (!title) return [];
    return [[title, licenseIn(checkoutFor(pin))]];
  });
}

function localEntries(): Entry[] {
  return Object.entries(LOCAL_LICENSES).map(([title, path]): Entry => [title, normalize(readFileSync(join(ROOT, path), "utf8"))]);
}

function castArtifact(url: string): string {
  const artifacts = sourcePackageDirs().flatMap((dir): Artifact[] => {
    const state = join(dir, "workspace-state.json");
    if (!isFile(state)) return [];
    const parsed = JSON.parse(readFileSync(state, "utf8")) as { object?: { artifacts?: Artifact[] } } | null;
    return parsed?.object?.artifacts ?? [];
  });
  const artifact = artifacts.find((candidate) => candidate?.source?.url === url && isDirectory(required(candidate.path, "path")));
  return artifact?.path ?? fail(`no Google Cast artifact from ${url}; resolve packages first (mise run bootstrap)`);
}

function castEntries(): Entry[] {
  const url = /url: "([^"]+)"/.exec(readFileSync(CAST_PACKAGE, "utf8"))?.[1] ?? fail(`no binary URL in ${CAST_PACKAGE}`);
  const licenses = join(dirname(castArtifact(url)), "OpenSourceLicenses");
  const text = readFileSync(join(licenses, "oss_licenses.bin"));
  const index = spawnSync("plutil", ["-convert", "json", "-o", "-", join(licenses, "oss_licenses_index.plist")], {
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  });
  if (index.status !== 0) fail(`cannot read the Google Cast license index in ${licenses}`);

  const embedded = (JSON.parse(index.stdout) as CastIndexItem[]).map((item): Entry => {
    const offset = required(item.offset, "offset");
    const size = required(item.size, "size");
    const license = text.subarray(offset, offset + size).toString("utf8");
    return [`Google Cast SDK: ${required(item.name, "name")}`, normalize(license)];
  });
  return [CAST_TERMS, ...embedded];
}

export function main(argv: readonly string[]): void {
  const checkOnly = argv.includes("--check");
  const entries = sortEntries([...packageEntries(), ...localEntries(), ...castEntries()]);
  const plist = render(entries);
  if (checkOnly) {
    const current = existsSync(PLIST_PATH) ? readFileSync(PLIST_PATH) : Buffer.alloc(0);
    if (!current.equals(Buffer.from(plist, "utf8"))) {
      fail("Acknowledgements.plist is out of sync with the shipped libraries. Run: mise run acknowledgements-sync");
    }
    process.stdout.write(`Verified ${entries.length} acknowledgements.\n`);
  } else {
    writeFileSync(PLIST_PATH, plist);
    process.stdout.write(`Generated Acknowledgements.plist (${entries.length} libraries).\n`);
  }
}

if (import.meta.main) {
  main(process.argv.slice(2));
}
