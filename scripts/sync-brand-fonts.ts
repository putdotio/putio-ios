#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

const MAX_REDIRECTS = 3;
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const MANIFEST_PATH = join(ROOT, "Config", "BrandFonts.json");
const BUNDLED_FONT_PATTERN = /^(?:gt-america|berkeley-mono)-.*\.otf$/i;

interface FontEntry {
  path: string;
  sha256: string;
}

interface Manifest {
  baseUrl: string;
  directory: string;
  files: Record<string, FontEntry>;
}

class Abort extends Error {}

function fail(message: string): never {
  throw new Abort(message);
}

function stringField(record: Record<string, unknown>, key: string, where: string): string {
  const value = record[key];
  if (typeof value !== "string") throw new Error(`${where}: expected string "${key}"`);
  return value;
}

function asRecord(value: unknown, where: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${where}: expected an object`);
  return value as Record<string, unknown>;
}

function readManifest(): Manifest {
  const raw = asRecord(JSON.parse(readFileSync(MANIFEST_PATH, "utf8")), MANIFEST_PATH);
  const files: Record<string, FontEntry> = {};
  for (const [name, entry] of Object.entries(asRecord(raw.files, `${MANIFEST_PATH} files`))) {
    const fields = asRecord(entry, `${MANIFEST_PATH} files.${name}`);
    files[name] = {
      path: stringField(fields, "path", `${MANIFEST_PATH} files.${name}`),
      sha256: stringField(fields, "sha256", `${MANIFEST_PATH} files.${name}`),
    };
  }
  return {
    baseUrl: stringField(raw, "baseUrl", MANIFEST_PATH),
    directory: stringField(raw, "directory", MANIFEST_PATH),
    files,
  };
}

function sha256Hex(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

const NETWORK_ERROR_NAMES: Record<string, string> = {
  ECONNREFUSED: "Errno::ECONNREFUSED",
  ENOTFOUND: "Socket::ResolutionError",
  EAI_AGAIN: "Socket::ResolutionError",
  UND_ERR_CONNECT_TIMEOUT: "Net::OpenTimeout",
};

function networkErrorName(error: unknown): string {
  const cause = error instanceof Error && error.cause instanceof Error ? error.cause : error;
  if (!(cause instanceof Error)) return String(cause);
  const code = (cause as NodeJS.ErrnoException).code;
  if (code === undefined) return cause.message;
  return NETWORK_ERROR_NAMES[code] ?? code;
}

class BrandFontSync {
  readonly #checkOnly: boolean;
  readonly #baseUrl: string;
  readonly #directoryLabel: string;
  readonly #directory: string;
  readonly #files: Record<string, FontEntry>;

  constructor(checkOnly: boolean) {
    const manifest = readManifest();
    this.#checkOnly = checkOnly;
    this.#baseUrl = manifest.baseUrl;
    this.#directoryLabel = manifest.directory;
    this.#directory = join(ROOT, manifest.directory);
    this.#files = manifest.files;
  }

  async run(): Promise<void> {
    if (this.#checkOnly) this.#check();
    else await this.#sync();
  }

  #check(): void {
    const names = Object.keys(this.#files);
    const stale = names.filter((name) => !this.#current(name, this.#entry(name).sha256));
    const mismatched = stale.filter((name) => existsSync(this.#fontPath(name)));
    const unlisted = this.#unlistedFontFiles();

    if (mismatched.length > 0 || unlisted.length > 0) {
      const details: string[] = [];
      if (mismatched.length > 0) details.push(`  mismatched: ${mismatched.join(", ")}`);
      if (unlisted.length > 0) details.push(`  unlisted: ${unlisted.join(", ")}`);
      fail(
        [
          `sync-brand-fonts: ${this.#directoryLabel} contradicts Config/BrandFonts.json.`,
          ...details,
          `  fix: rm -rf ${this.#directoryLabel} && mise run fonts-setup`,
        ].join("\n"),
      );
    }

    if (stale.length === 0) {
      console.log(`sync-brand-fonts: ${names.length} brand fonts present and matching the manifest.`);
      return;
    }

    const present = names.filter((name) => !stale.includes(name));
    if (present.length === 0) {
      console.log("sync-brand-fonts: no brand fonts present; run `mise run fonts-setup` to download them.");
      return;
    }

    fail(
      [
        `sync-brand-fonts: ${this.#directoryLabel} has ${present.length} of ${names.length} brand fonts.`,
        `  missing: ${[...stale].sort().join(", ")}`,
        "  fix: mise run fonts-setup",
      ].join("\n"),
    );
  }

  async #sync(): Promise<void> {
    mkdirSync(this.#directory, { recursive: true });

    for (const [name, entry] of Object.entries(this.#files)) {
      if (this.#current(name, entry.sha256)) {
        console.log(`sync-brand-fonts: ${name} already current`);
        continue;
      }
      await this.#download(name, entry);
    }

    const unlisted = this.#unlistedFontFiles();
    if (unlisted.length > 0) {
      fail(
        [
          `sync-brand-fonts: ${this.#directoryLabel} contains fonts that are not in the manifest.`,
          `  unlisted: ${unlisted.join(", ")}`,
          `  fix: rm -rf ${this.#directoryLabel} && mise run fonts-setup`,
        ].join("\n"),
      );
    }

    console.log(`sync-brand-fonts: ${Object.keys(this.#files).length} brand fonts ready in ${this.#directoryLabel}.`);
  }

  async #download(name: string, entry: FontEntry): Promise<void> {
    const url = `${this.#baseUrl}/${entry.path}`;
    const body = await this.#fetch(url);
    const actual = sha256Hex(body);
    const expected = entry.sha256;

    if (actual !== expected) {
      fail(
        [
          `sync-brand-fonts: ${name} does not match the manifest.`,
          `  url:      ${url}`,
          `  expected: ${expected}`,
          `  actual:   ${actual}`,
          "The hosted font changed. Confirm the new file is intended, update its",
          "sha256 in Config/BrandFonts.json, then re-record baselines with",
          "`mise run screenshots-record`.",
          "",
        ].join("\n"),
      );
    }

    writeFileSync(this.#fontPath(name), body);
    console.log(`sync-brand-fonts: downloaded ${name} (${body.byteLength} bytes)`);
  }

  async #fetch(url: string, redirectsLeft = MAX_REDIRECTS): Promise<Buffer> {
    let response: Response;
    try {
      response = await fetch(url, { redirect: "manual" });
    } catch (error) {
      fail(`sync-brand-fonts: could not reach ${url} (${networkErrorName(error)}). Check your network.`);
    }

    if (response.status >= 200 && response.status < 300) return Buffer.from(await response.arrayBuffer());

    if (response.status >= 300 && response.status < 400) {
      if (redirectsLeft === 0) fail(`sync-brand-fonts: too many redirects fetching ${url}`);
      const location = response.headers.get("location");
      if (location === null) fail(`sync-brand-fonts: ${url} redirected without a Location header`);
      return this.#fetch(new URL(location, url).toString(), redirectsLeft - 1);
    }

    fail(`sync-brand-fonts: ${url} returned ${response.status} ${response.statusText}`);
  }

  #entry(name: string): FontEntry {
    const entry = this.#files[name];
    if (entry === undefined) throw new Error(`sync-brand-fonts: ${name} is not in the manifest`);
    return entry;
  }

  #current(name: string, sha: string): boolean {
    const path = this.#fontPath(name);
    return existsSync(path) && sha256Hex(readFileSync(path)) === sha;
  }

  #fontPath(name: string): string {
    return join(this.#directory, name);
  }

  #unlistedFontFiles(): string[] {
    if (!existsSync(this.#directory) || !statSync(this.#directory).isDirectory()) return [];
    return readdirSync(this.#directory)
      .filter((name) => BUNDLED_FONT_PATTERN.test(name))
      .filter((name) => !Object.hasOwn(this.#files, name))
      .sort();
  }
}

try {
  await new BrandFontSync(process.argv.slice(2).includes("--check")).run();
} catch (error) {
  if (!(error instanceof Abort)) throw error;
  process.stderr.write(error.message.endsWith("\n") ? error.message : `${error.message}\n`);
  process.exitCode = 1;
}
