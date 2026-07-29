#!/usr/bin/env node

// Assembles raw App Store screenshots from the committed visual baselines.
//
// There is deliberately no capture step for iPhone. The regression walk is
// pinned to iPhone 17 Pro Max, and its 1320x2868 output is exactly Apple's
// required 6.9" size, so the store set is a *selection* over images CI already
// pixel-compares. A parallel capture lane would be free to drift from what is
// actually asserted, which is the failure mode worth avoiding.
//
// Output is gitignored and intermediate. #51 frames these into the finished
// marketing images that get committed and uploaded.
//
// Usage (run directly — Node strips the types, there is no build step):
//   node scripts/store-screenshots.ts          # assemble into dist/store-screenshots/
//   node scripts/store-screenshots.ts --check  # verify sources without writing

import { execFileSync } from "node:child_process";
import { copyFile, mkdir, readFile, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

// Anchored on the script so it can be run from anywhere, matching
// sync-brand-fonts.rb.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const CONFIG = join(ROOT, "Config/StoreScreenshots.json");
const OUTPUT_DIR = join(ROOT, "dist/store-screenshots");

interface ScreenshotEntry {
  slot: number;
  baseline: string;
  id: string;
  captionKey: string;
}

interface Device {
  width: number;
  height: number;
  source: string;
  screenshots: ScreenshotEntry[];
}

interface Config {
  devices: Record<string, Device>;
  /** Devices App Store Connect expects that this config does not cover yet. */
  $missing?: string;
}

async function main(): Promise<void> {
  const checkOnly = process.argv.includes("--check");
  const config = await readConfig();

  if (!checkOnly) {
    await rm(OUTPUT_DIR, { recursive: true, force: true });
  }

  let total = 0;

  for (const [deviceId, device] of Object.entries(config.devices)) {
    const destinationDir = join(OUTPUT_DIR, deviceId);
    if (!checkOnly) {
      await mkdir(destinationDir, { recursive: true });
    }

    const slots = [...device.screenshots].sort((a, b) => a.slot - b.slot);
    assertContiguousSlots(slots, deviceId);

    for (const entry of slots) {
      const source = join(ROOT, device.source, entry.baseline);

      if (!existsSync(source)) {
        fail(
          `${deviceId} slot ${entry.slot}: baseline not found at ${device.source}/${entry.baseline}.`,
          "A baseline was renamed or removed. Update Config/StoreScreenshots.json, or re-record with make screenshots-record.",
        );
      }

      // Apple rejects a set whose dimensions do not match the declared device,
      // and the pinned simulator is the only thing keeping these correct. If
      // someone repins it, this is where that surfaces — before an upload.
      const { width, height } = pixelSize(source, `${deviceId} slot ${entry.slot}`);
      if (width !== device.width || height !== device.height) {
        fail(
          `${deviceId} slot ${entry.slot}: ${entry.baseline} is ${width}x${height}, expected ${device.width}x${device.height}.`,
          "The capture device no longer matches the store size. Check scripts/simctl-iphone-device-id.sh, then re-record.",
        );
      }

      if (!checkOnly) {
        const name = `${String(entry.slot).padStart(2, "0")}-${entry.id}.png`;
        await copyFile(source, join(destinationDir, name));
      }

      total += 1;
    }

    console.log(
      `${deviceId}: ${slots.length} screenshots at ${device.width}x${device.height}` +
        (checkOnly ? " (verified)" : ` -> dist/store-screenshots/${deviceId}/`),
    );
  }

  if (config.$missing) {
    console.log(`note: ${config.$missing}`);
  }

  console.log(checkOnly ? `checked ${total} store screenshots` : `assembled ${total} store screenshots`);
}

/**
 * Parse the config once, at the boundary, so the loop above can index into it
 * without re-checking every field. A hand-edited slot with a missing `id` or a
 * device with no `width` used to surface as `undefined` inside a filename or a
 * dimension comparison; now it is named here.
 */
async function readConfig(): Promise<Config> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(await readFile(CONFIG, "utf8"));
  } catch (error) {
    // Otherwise a hand-edited trailing comma exits with a raw SyntaxError stack
    // that never names the file — the one thing the reader needs.
    fail(
      `Config/StoreScreenshots.json could not be read: ${(error as Error).message}`,
      "Fix the JSON, or restore the file from git.",
    );
  }

  if (!isPlainObject(parsed)) {
    fail("Config/StoreScreenshots.json is not an object.", "Restore it from git.");
  }

  const config = parsed as Partial<Config>;

  // Arrays are objects, so a `"devices": []` typo would pass a bare typeof
  // check and then produce an empty store set without complaint.
  if (!isPlainObject(config.devices)) {
    fail("Config/StoreScreenshots.json has no devices object.", "Add a devices block keyed by device id.");
  }

  const devices = Object.entries(config.devices as Record<string, unknown>);

  if (devices.length === 0) {
    fail("Config/StoreScreenshots.json declares no devices.", "Add at least one device; an empty set cannot become a listing.");
  }

  for (const [deviceId, candidate] of devices) {
    if (!isPlainObject(candidate)) {
      fail(`${deviceId}: must be an object describing the device.`, "Give it width, height, source and screenshots.");
    }

    const device = candidate as Partial<Device>;

    for (const field of ["width", "height"] as const) {
      if (!Number.isInteger(device[field])) {
        fail(`${deviceId}: "${field}" must be an integer.`, "Set it to the store size Apple expects for this device.");
      }
    }

    if (typeof device.source !== "string" || device.source === "") {
      fail(`${deviceId}: "source" must be the directory the baselines come from.`, "Point it at a __Snapshots__ directory.");
    }

    if (!Array.isArray(device.screenshots) || device.screenshots.length === 0) {
      fail(`${deviceId}: "screenshots" must be a non-empty array.`, "A device with no slots cannot produce a listing.");
    }

    for (const [index, entry] of device.screenshots.entries()) {
      if (!Number.isInteger(entry?.slot)) {
        fail(`${deviceId} screenshots[${index}]: "slot" must be an integer.`, "Slots are 1..n in display order.");
      }

      for (const field of ["baseline", "id", "captionKey"] as const) {
        if (typeof entry?.[field] !== "string" || entry[field] === "") {
          fail(`${deviceId} slot ${entry?.slot}: "${field}" must be a non-empty string.`, "Fill it in Config/StoreScreenshots.json.");
        }
      }
    }
  }

  return config as Config;
}

/**
 * Apple presents screenshots in order, so a gap or duplicate silently reorders
 * the listing. Cheaper to reject here than to notice it on the product page.
 */
function assertContiguousSlots(slots: ScreenshotEntry[], deviceId: string): void {
  const expected = slots.map((_, index) => index + 1);
  const actual = slots.map((entry) => entry.slot);

  if (actual.join(",") !== expected.join(",")) {
    fail(
      `${deviceId}: slots must be 1..${slots.length} with no gaps or duplicates, got ${actual.join(", ")}.`,
      "Fix the slot numbers in Config/StoreScreenshots.json.",
    );
  }
}

function pixelSize(path: string, label: string): { width: number; height: number } {
  // sips ships with macOS and this repo is macOS-only. Both failure modes are
  // handled explicitly: without this, an unreadable file throws a raw stack, and
  // an unparsed one yields NaNxNaN reported against the size check — whose
  // remedy talks about the simulator and would send someone the wrong way.
  let output: string;
  try {
    output = execFileSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", path], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    fail(
      `${label}: could not read image dimensions from ${path} (${(error as Error).message.trim()}).`,
      "Confirm the file is a readable PNG. If it is not an image, it does not belong in the baseline directory.",
    );
  }

  const width = Number(/pixelWidth:\s*(\d+)/u.exec(output)?.[1]);
  const height = Number(/pixelHeight:\s*(\d+)/u.exec(output)?.[1]);

  if (!Number.isInteger(width) || !Number.isInteger(height)) {
    fail(
      `${label}: could not parse image dimensions from sips output for ${path}.`,
      "sips reported an unexpected format. Run `sips -g pixelWidth -g pixelHeight <file>` to see what it returned.",
    );
  }

  return { width, height };
}

/**
 * A JSON object, excluding arrays and null — both of which `typeof` calls
 * "object", and both of which would otherwise slip through a shape check and
 * fail later somewhere less informative.
 */
function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Returns `never` so the type checker knows control does not continue past a
 * fail() — which is what lets the callers above use the values they just
 * validated without a redundant non-null assertion.
 */
function fail(message: string, remedy: string): never {
  console.error(`store-screenshots: ${message}\n  fix: ${remedy}`);
  process.exit(1);
}

await main();
