#!/usr/bin/env node

// Visual reference gallery driver.
//
// build and validate use @putdotio/vref's library API; serve goes through its
// CLI, because serve is not exported from the package. Both paths need vref
// 1.1.1 or newer — the bin in 1.1.0 exited 0 having done nothing under pnpm's
// symlinked layout (putdotio/vref#21).
//
// Either way this driver has to copy baselines and refresh the manifest first,
// so the work below is ours regardless of which entry point vref offers.
//
// Commands:
//   sync      copy committed baselines into .vref/screenshots/ and refresh the
//             manifest's mechanical fields, preserving curated text
//   build     sync, then write .vref/index.html
//   validate  check the manifest and that every referenced asset exists
//   serve     serve the gallery locally
//
// Run directly: Node strips the types, there is no build step.

import { execFileSync } from "node:child_process";
import { copyFile, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join, sep } from "node:path";
import process from "node:process";
import { buildGallery, validateGallery } from "@putdotio/vref";

import { resolveCapturedAt } from "./vref-manifest.ts";

const VREF_DIR = ".vref";
const MANIFEST = join(VREF_DIR, "manifest.json");
const OUTPUT = join(VREF_DIR, "index.html");

/**
 * The parts of a manifest entry this driver owns. Curated text (title, tags,
 * notes) is preserved verbatim and deliberately not modelled — declaring only
 * what we write keeps the contract honest about which fields are ours.
 */
interface ManifestEntry {
  id: string;
  file: string;
  group: string;
  platform: string;
  device: string;
  viewport: { width: number; height: number };
  sizeBytes: number;
  capturedAt: string;
  [preserved: string]: unknown;
}

interface Manifest {
  screenshots: ManifestEntry[];
  updatedAt: string;
  [preserved: string]: unknown;
}

interface Source {
  group: string;
  dir: string;
  prefix: string;
  subdir: string;
  device: string;
}

// Where each group's baselines come from, and the id prefix stripped from the
// filename. Screens come from the e2e walk; components render directly in unit
// tests, so they are not device-sized and carry their own viewport.
const SOURCES: Source[] = [
  {
    group: "Screens",
    dir: "PutioUITests/__Snapshots__/ScreenshotWalkUITests",
    prefix: "walk.dark-",
    subdir: "screens",
    device: "iPhone 17 Pro Max",
  },
  {
    group: "Components",
    dir: "PutioTests/__Snapshots__/ComponentSnapshotTests",
    prefix: "component.dark-",
    subdir: "components",
    device: "Rendered directly",
  },
];

async function main(): Promise<void> {
  const command = process.argv[2] ?? "build";

  switch (command) {
    case "sync":
      await sync();
      return;
    case "build": {
      await sync();
      const result = await buildGallery({ cwd: process.cwd(), manifestPath: MANIFEST, outputPath: OUTPUT });
      console.log(`wrote ${OUTPUT} (${result.screenshotCount} references, ${result.groupCount} groups)`);
      return;
    }
    case "validate": {
      // Syncs first, like build and serve: the assets validateGallery checks for
      // are the gitignored copies, so validating without regenerating them would
      // fail on every clean checkout.
      await sync();
      const result = await validateGallery({ cwd: process.cwd(), manifestPath: MANIFEST });
      console.log(`validated ${result.screenshotCount} references in ${result.groupCount} groups`);
      return;
    }
    case "serve": {
      await sync();
      await buildGallery({ cwd: process.cwd(), manifestPath: MANIFEST, outputPath: OUTPUT });
      // Unlike build and validate, serve is not part of vref's library exports,
      // so this one goes through the CLI. Safe as of vref 1.1.1, which fixed the
      // bin that previously exited 0 without doing anything under pnpm.
      execFileSync("pnpm", ["exec", "vref", "serve", "--dir", VREF_DIR], { stdio: "inherit" });
      return;
    }
    default:
      console.error("usage: node scripts/vref.ts [sync|build|validate|serve]");
      process.exitCode = 1;
  }
}

/**
 * Parse the manifest at the boundary, so everything downstream can rely on the
 * shape instead of re-checking it. A hand-edited manifest is the realistic
 * failure here, and it should name the problem rather than surface later as a
 * property read on undefined.
 */
async function readManifest(): Promise<Manifest> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(await readFile(MANIFEST, "utf8"));
  } catch (error) {
    // A raw SyntaxError never names the file it came from, which is the one
    // thing worth knowing when the manifest is hand-edited.
    throw new Error(`${MANIFEST} could not be read: ${(error as Error).message}`);
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`${MANIFEST} is not an object.`);
  }

  const manifest = parsed as Partial<Manifest>;

  if (!Array.isArray(manifest.screenshots)) {
    throw new Error(`${MANIFEST} has no "screenshots" array.`);
  }

  for (const [index, entry] of manifest.screenshots.entries()) {
    if (typeof entry?.id !== "string" || entry.id === "") {
      throw new Error(`${MANIFEST} screenshots[${index}] has no string "id".`);
    }
  }

  return manifest as Manifest;
}

/**
 * Copy the committed baselines into `.vref/screenshots/` and refresh the
 * manifest's mechanical fields against them.
 *
 * The copies are gitignored and regenerated from the committed baselines every
 * run, so they cannot drift. Everything derivable from the baseline itself is
 * rewritten — file, group, platform, device, viewport, sizeBytes — and curated
 * text — title, tags, notes — lives in the committed manifest and is preserved.
 * A baseline with no manifest entry is reported rather than silently added with a
 * placeholder title.
 *
 * capturedAt is set once, when an entry is first created, and preserved after
 * that. It used to be recomputed from git on every run, which meant every squash
 * merge that touched a baseline left the manifest stale on main — #75 exists
 * solely to have refreshed it. @putdotio/vref requires the field, so it stays;
 * only its ownership moves, from derived to curated like the text around it.
 */
async function sync(): Promise<void> {
  const manifest = await readManifest();
  const byId = new Map(manifest.screenshots.map((entry) => [entry.id, entry]));
  const seen = new Set<string>();

  await rm(join(VREF_DIR, "screenshots"), { recursive: true, force: true });

  for (const source of SOURCES) {
    const names = listBaselines(source.dir);

    for (const name of names) {
      const id = `${source.subdir}-${name.slice(source.prefix.length, -".png".length)}`;
      const sourcePath = join(source.dir, name);
      const relative = join("screenshots", source.subdir, `${id}.png`);
      const destination = join(VREF_DIR, relative);

      await mkdir(dirname(destination), { recursive: true });
      await copyFile(sourcePath, destination);

      const entry = byId.get(id);
      if (!entry) {
        throw new Error(
          `no manifest entry for baseline ${sourcePath} (expected id "${id}"). ` +
            `Add one to ${MANIFEST} with a title, tags and notes, then rerun.`,
        );
      }

      const { size } = await stat(destination);
      const { width, height } = pixelSize(destination);

      // Manifest paths are POSIX by contract, and join() uses the platform
      // separator, so convert rather than assume. (`split("/").join("/")` — what
      // this used to do — is a no-op that only looks like normalization.)
      entry.file = relative.split(sep).join("/");
      entry.group = source.group;
      entry.platform = "iOS";
      entry.device = source.device;
      entry.viewport = { width, height };
      entry.sizeBytes = size;

      // Filled in once, for an entry that arrives without one, and left alone
      // after that. Recomputing it on every run is what made a squash merge
      // dirty the manifest.
      //
      // Validated rather than trusted, because preserving a value means
      // preserving a bad one, and updatedAt is the newest capturedAt — so one bad
      // entry moves the whole gallery's timestamp. scripts/vref-manifest.ts
      // explains why Date.parse cannot be the gate.
      entry.capturedAt = resolveCapturedAt(
        entry.capturedAt,
        () => lastCommitDate(sourcePath),
        (value) =>
          `${MANIFEST} entry "${id}" has an invalid capturedAt (${value}). ` +
          "Use an ISO 8601 UTC timestamp such as 2026-07-29T09:29:31.000Z, " +
          "or remove the field to have it filled in.",
      );

      seen.add(id);
    }
  }

  const orphans = manifest.screenshots.filter((entry) => !seen.has(entry.id)).map((entry) => entry.id);
  if (orphans.length > 0) {
    throw new Error(
      `manifest entries have no baseline: ${orphans.join(", ")}. ` +
        `Remove them from ${MANIFEST}, or re-record with mise run screenshots-record.`,
    );
  }

  manifest.updatedAt = newestCaptureDate(manifest.screenshots);
  await writeFile(MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`synced ${seen.size} baselines into ${VREF_DIR}/screenshots/`);
}

function listBaselines(dir: string): string[] {
  return execFileSync("git", ["ls-files", dir], { encoding: "utf8" })
    .split("\n")
    .filter((line) => line.endsWith(".png"))
    .map((line) => line.slice(dir.length + 1))
    .sort();
}

function pixelSize(path: string): { width: number; height: number } {
  // sips ships with macOS and this repo is macOS-only; avoids adding an image
  // dependency just to read two integers.
  const output = execFileSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", path], {
    encoding: "utf8",
  });
  const width = Number(/pixelWidth:\s*(\d+)/u.exec(output)?.[1]);
  const height = Number(/pixelHeight:\s*(\d+)/u.exec(output)?.[1]);

  if (!Number.isInteger(width) || !Number.isInteger(height)) {
    throw new Error(`could not read pixel dimensions from ${path}`);
  }

  return { width, height };
}

/**
 * A first `capturedAt` for a baseline that has just been added, taken from git
 * rather than the filesystem: mtime changes on every checkout.
 *
 * Author date (%aI), not committer date (%cI), so a rebase does not move it.
 * That is not sufficient on its own — a squash merge writes a new commit with a
 * new author date — which is why the caller now keeps the first value instead of
 * recomputing.
 *
 * A baseline recorded but not yet committed has no git date, and the value is
 * permanent once written, so falling back to the epoch would stamp 1970 forever.
 * The current time is the honest answer: recording is what just happened.
 */
function lastCommitDate(path: string): string {
  const output = execFileSync("git", ["log", "-1", "--format=%aI", "--", path], {
    encoding: "utf8",
  }).trim();

  return output === "" ? new Date().toISOString() : new Date(output).toISOString();
}

function newestCaptureDate(screenshots: ManifestEntry[]): string {
  const newest = screenshots
    .map((entry) => Date.parse(entry.capturedAt))
    .filter((value) => Number.isFinite(value))
    .sort((a, b) => b - a)[0];

  return new Date(newest ?? 0).toISOString();
}

await main();
