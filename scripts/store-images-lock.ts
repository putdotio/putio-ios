#!/usr/bin/env node

// Ties each committed marketing image to the inputs it was rendered from, so a
// baseline cannot change underneath one silently. The drift is per-slot and
// invisible unless someone renders and diffs.
//
// Deliberately not a byte comparison against a fresh render: that would need
// Chromium on the runner and byte-stable output across its versions, so a
// Playwright bump would fail every image for no visual reason. Hashing inputs
// needs no browser, which is what lets this run in the Linux CI lane.
//
// Usage:
//   node scripts/store-images-lock.ts verify   # fail naming any stale image
//
// `mise run store-images` writes the lock; nothing else should.

import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCREENSHOTS_CONFIG = join(ROOT, "Config/StoreScreenshots.json");
const CAPTIONS_CONFIG = join(ROOT, "Config/StoreCaptions.json");
const TEMPLATE = join(ROOT, "scripts/store-images/template.html");
const DESIGN_TOKENS = join(ROOT, "node_modules/@putdotio/design/dist/css/tokens.css");

export const LOCK_PATH = join(ROOT, "Config/StoreImages.lock.json");
const OUTPUT_DIR = join(ROOT, "fastlane/screenshots");

/**
 * The only locale rendered today. A code constant, not derived from
 * StoreCaptions.json: a locale added there would otherwise produce lock entries
 * for images the renderer never writes, and both sides would agree on the same
 * phantom set. Rendering more locales is a code change.
 */
export const LOCALE = "en-US";

/** Hashes shared by every image: change one and the whole set is stale. */
interface LockInputs {
  storeScreenshots: string;
  storeCaptions: string;
  template: string;
  designTokens: string;
}

export interface Lock {
  $comment: string;
  inputs: LockInputs;
  /** Rendered image path under fastlane/screenshots -> the baseline behind it. */
  images: Record<string, { baseline: string; sha256: string }>;
}

export function storeImageName(deviceId: string, slot: number, id: string): string {
  return `${deviceId}-${String(slot).padStart(2, "0")}-${id}.jpg`;
}

function sha256(data: Buffer | string): string {
  return createHash("sha256").update(data).digest("hex");
}

/**
 * Hashes a config's meaning rather than its bytes. `$`-prefixed keys are prose
 * for maintainers, and hashing them would mark every image stale each time
 * someone improves a note.
 */
function semanticHash(source: string): string {
  const stripped = JSON.parse(source, (key, value) => (key.startsWith("$") ? undefined : value));
  return sha256(JSON.stringify(stripped));
}

/** Recomputes the lock from what is on disk right now. */
export async function computeLock(): Promise<Lock> {
  const screenshotsSource = await readFile(SCREENSHOTS_CONFIG, "utf8");
  const captionsSource = await readFile(CAPTIONS_CONFIG, "utf8");
  const config = JSON.parse(screenshotsSource);
  const captions = JSON.parse(captionsSource);

  if (!existsSync(DESIGN_TOKENS)) {
    throw new Error(
      "@putdotio/design is not installed, so the design tokens cannot be hashed. Run pnpm install.",
    );
  }

  const images: Lock["images"] = {};

  for (const [deviceId, device] of Object.entries(config.devices) as [string, {
    source: string;
    screenshots: { slot: number; id: string; baseline: string }[];
  }][]) {
    for (const entry of [...device.screenshots].sort((a, b) => a.slot - b.slot)) {
      const baseline = `${device.source}/${entry.baseline}`;
      const absolute = join(ROOT, baseline);

      if (!existsSync(absolute)) {
        throw new Error(
          `${deviceId} slot ${entry.slot}: baseline not found at ${baseline}. ` +
            "Update Config/StoreScreenshots.json, or re-record.",
        );
      }

      images[`${LOCALE}/${storeImageName(deviceId, entry.slot, entry.id)}`] = {
        baseline,
        sha256: sha256(await readFile(absolute)),
      };
    }
  }

  return {
    $comment:
      "Written by mise run store-images. Ties each committed marketing image to the baseline it was rendered from, so a baseline change without a re-render fails mise run verify-store-images instead of shipping stale artwork. Do not hand-edit.",
    inputs: {
      storeScreenshots: semanticHash(screenshotsSource),
      storeCaptions: semanticHash(captionsSource),
      template: sha256(await readFile(TEMPLATE)),
      designTokens: sha256(await readFile(DESIGN_TOKENS)),
    },
    images,
  };
}

async function verify(): Promise<void> {
  if (!existsSync(LOCK_PATH)) {
    console.error(
      "verify-store-images: Config/StoreImages.lock.json is missing.\n" +
        "  fix: Run mise run store-images and commit the result.",
    );
    process.exit(1);
  }

  const committed: Lock = JSON.parse(await readFile(LOCK_PATH, "utf8"));
  const current = await computeLock();
  const problems: string[] = [];

  for (const [name, hash] of Object.entries(current.inputs)) {
    if (committed.inputs?.[name as keyof LockInputs] !== hash) {
      problems.push(`${name} changed since the images were rendered — every image is stale`);
    }
  }

  for (const [image, entry] of Object.entries(current.images)) {
    // Existence, deliberately not content: nothing else here reads the
    // rendered files, but hashing them would fail the whole set after a
    // Playwright bump re-encoded identical-looking pixels.
    if (!existsSync(join(OUTPUT_DIR, image))) {
      problems.push(`${image} is missing from fastlane/screenshots/`);
    }

    const was = committed.images?.[image];
    if (!was) {
      problems.push(`${image} is declared by the config but absent from the lock`);
      continue;
    }
    if (was.baseline !== entry.baseline) {
      problems.push(`${image} now comes from ${entry.baseline}, was ${was.baseline}`);
      continue;
    }
    if (was.sha256 !== entry.sha256) {
      problems.push(`${image} is stale: ${entry.baseline} changed since it was rendered`);
    }
  }

  for (const image of Object.keys(committed.images ?? {})) {
    if (!current.images[image]) {
      problems.push(`${image} is in the lock but no longer declared by the config`);
    }
  }

  if (problems.length > 0) {
    console.error("verify-store-images: the committed marketing images no longer match their inputs:");
    for (const problem of problems) {
      console.error(`  ${problem}`);
    }
    console.error("  fix: Run mise run store-images, review the image diff, and commit both.");
    process.exit(1);
  }

  console.log(`verify-store-images: ${Object.keys(current.images).length} images match their inputs`);
}

// store-images.ts imports computeLock from here; without this guard its own
// `--check` would arrive as argv[2] and be rejected as an unknown command.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const command = process.argv[2];

  if (command === "verify") {
    await verify();
  } else {
    console.error(`store-images-lock: expected the 'verify' command, got '${command ?? "nothing"}'`);
    process.exit(2);
  }
}
