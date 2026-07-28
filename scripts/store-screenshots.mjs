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
// Usage:
//   node scripts/store-screenshots.mjs          # assemble into dist/store-screenshots/
//   node scripts/store-screenshots.mjs --check  # verify sources without writing

import { execFileSync } from "node:child_process";
import { copyFile, mkdir, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";
import { readFile } from "node:fs/promises";

// Anchored on the script so it can be run from anywhere, matching
// sync-brand-fonts.rb.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const CONFIG = join(ROOT, "Config/StoreScreenshots.json");
const OUTPUT_DIR = join(ROOT, "dist/store-screenshots");

async function main() {
  const checkOnly = process.argv.includes("--check");
  const config = JSON.parse(await readFile(CONFIG, "utf8"));

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

  for (const note of missingDeviceNotes(config)) {
    console.log(note);
  }

  console.log(checkOnly ? `checked ${total} store screenshots` : `assembled ${total} store screenshots`);
}

/**
 * Apple presents screenshots in order, so a gap or duplicate silently reorders
 * the listing. Cheaper to reject here than to notice it on the product page.
 */
function assertContiguousSlots(slots, deviceId) {
  const expected = slots.map((_, index) => index + 1);
  const actual = slots.map((entry) => entry.slot);

  if (actual.join(",") !== expected.join(",")) {
    fail(
      `${deviceId}: slots must be 1..${slots.length} with no gaps or duplicates, got ${actual.join(", ")}.`,
      "Fix the slot numbers in Config/StoreScreenshots.json.",
    );
  }
}

/** Devices App Store Connect expects that this config does not cover yet. */
function missingDeviceNotes(config) {
  return config.$missing ? [`note: ${config.$missing}`] : [];
}

function pixelSize(path, label) {
  // sips ships with macOS and this repo is macOS-only. Both failure modes are
  // handled explicitly: without this, an unreadable file throws a raw stack, and
  // an unparsed one yields NaNxNaN reported against the size check — whose
  // remedy talks about the simulator and would send someone the wrong way.
  let output;
  try {
    output = execFileSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", path], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    fail(
      `${label}: could not read image dimensions from ${path} (${error.message.trim()}).`,
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

function fail(message, remedy) {
  console.error(`store-screenshots: ${message}\n  fix: ${remedy}`);
  process.exit(1);
}

await main();
