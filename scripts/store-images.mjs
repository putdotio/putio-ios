#!/usr/bin/env node

// Frames the raw store screenshots into finished App Store marketing images:
// brand-yellow field, bold caption, screenshot in a rounded black device that
// runs off the bottom edge — the treatment the Apple TV and Android TV listings
// already use.
//
// Input comes from `make store-screenshots` (gitignored, intermediate). Output
// is committed, so the images get reviewed as an image diff in the PR before
// #52 uploads them.
//
// Brand values are read from @putdotio/design rather than retyped, and the
// caption face is the same licensed GT America the app bundles, so these match
// the product instead of merely resembling it.
//
// Usage:
//   node scripts/store-images.mjs          # render into fastlane/screenshots/
//   node scripts/store-images.mjs --check  # verify inputs without rendering

import { existsSync } from "node:fs";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";
import { chromium } from "playwright";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCREENSHOTS_CONFIG = join(ROOT, "Config/StoreScreenshots.json");
const CAPTIONS_CONFIG = join(ROOT, "Config/StoreCaptions.json");
const TEMPLATE = join(ROOT, "scripts/store-images/template.html");
const RAW_DIR = join(ROOT, "dist/store-screenshots");
const OUTPUT_DIR = join(ROOT, "fastlane/screenshots");
const FONTS_DIR = join(ROOT, "Putio/Fonts");

// Proportional layout, so the same template holds for any device size Apple
// introduces. Each value declares which axis it scales against: widths against
// width, vertical rhythm against height. Scaling everything off one axis makes
// the device wider than the canvas on a tall phone.
const LAYOUT = {
  captionSize: ["width", 0.082],
  captionPaddingBlock: ["height", 0.042],
  captionPaddingInline: ["width", 0.09],
  deviceWidth: ["width", 0.8],
  deviceBezel: ["width", 0.014],
  deviceRadius: ["width", 0.075],
  screenRadius: ["width", 0.062],
};

async function main() {
  const checkOnly = process.argv.includes("--check");
  const config = JSON.parse(await readFile(SCREENSHOTS_CONFIG, "utf8"));
  const captions = JSON.parse(await readFile(CAPTIONS_CONFIG, "utf8"));
  const locale = "en-US";
  const strings = captions.locales?.[locale];

  if (!strings) {
    fail(`no captions for locale ${locale}`, "Add it to Config/StoreCaptions.json.");
  }

  const plan = await buildPlan(config, strings, locale);

  if (checkOnly) {
    for (const item of plan) {
      console.log(`${item.deviceId} slot ${item.slot}: "${item.caption}" over ${item.rawName}`);
    }
    console.log(`checked ${plan.length} store images`);
    return;
  }

  const css = await readFile(join(ROOT, "node_modules/@putdotio/design/dist/css/tokens.css"), "utf8");
  const fontFaces = await brandFontFaces();

  await rm(OUTPUT_DIR, { recursive: true, force: true });

  const browser = await chromium.launch();
  try {
    for (const item of plan) {
      await render(browser, item, css, fontFaces);
    }
  } finally {
    await browser.close();
  }

  console.log(`rendered ${plan.length} store images into fastlane/screenshots/`);
}

async function buildPlan(config, strings, locale) {
  const plan = [];

  for (const [deviceId, device] of Object.entries(config.devices)) {
    const rawDir = join(RAW_DIR, deviceId);

    if (!existsSync(rawDir)) {
      fail(
        `${deviceId}: no raw screenshots at dist/store-screenshots/${deviceId}/.`,
        "Run make store-screenshots first — this step frames its output, it does not capture.",
      );
    }

    for (const entry of [...device.screenshots].sort((a, b) => a.slot - b.slot)) {
      const caption = strings[entry.captionKey];

      if (!caption) {
        fail(
          `${deviceId} slot ${entry.slot}: no ${locale} caption for key "${entry.captionKey}".`,
          "Add it to Config/StoreCaptions.json, or point the slot at a key that exists.",
        );
      }

      const rawName = `${String(entry.slot).padStart(2, "0")}-${entry.id}.png`;
      const rawPath = join(rawDir, rawName);

      if (!existsSync(rawPath)) {
        fail(
          `${deviceId} slot ${entry.slot}: ${rawName} is missing from dist/store-screenshots/${deviceId}/.`,
          "Re-run make store-screenshots; the two configs may have drifted.",
        );
      }

      plan.push({
        deviceId,
        slot: entry.slot,
        id: entry.id,
        caption,
        rawName,
        rawPath,
        width: device.width,
        height: device.height,
        locale,
      });
    }
  }

  return plan;
}

/**
 * Embed the licensed faces as data URLs. Chromium will not load a local file
 * through @font-face from a data: document, and a missing face would silently
 * fall back to a system font — producing store images whose typography is not
 * the product's. Better to refuse.
 */
async function brandFontFaces() {
  if (!existsSync(FONTS_DIR)) {
    fail(
      "brand fonts are not present.",
      "Run make fonts-setup. Store images must use GT America; a system-font fallback would ship the wrong typography.",
    );
  }

  const files = (await readdir(FONTS_DIR)).filter((name) => name.startsWith("gt-america-") && name.endsWith(".otf"));

  if (files.length === 0) {
    fail("no GT America faces found in Putio/Fonts.", "Run make fonts-setup.");
  }

  const weights = { regular: 400, medium: 500, bold: 700, black: 900 };
  const faces = [];

  for (const file of files) {
    const weightName = /gt-america-standard-([a-z]+)\.otf$/u.exec(file)?.[1];
    const weight = weights[weightName];
    if (!weight) {
      continue;
    }

    const data = await readFile(join(FONTS_DIR, file));
    faces.push(
      `@font-face { font-family: "GT America"; font-weight: ${weight}; font-style: normal; ` +
        `src: url(data:font/otf;base64,${data.toString("base64")}) format("opentype"); }`,
    );
  }

  return faces.join("\n");
}

async function render(browser, item, css, fontFaces) {
  const page = await browser.newPage({
    viewport: { width: item.width, height: item.height },
    deviceScaleFactor: 1,
  });

  const screenshot = await readFile(item.rawPath);
  const variables = Object.entries(LAYOUT)
    .map(([name, [axis, ratio]]) => {
      const basis = axis === "width" ? item.width : item.height;
      return `--${kebab(name)}: ${Math.round(ratio * basis)}px;`;
    })
    .join("\n");

  await page.goto(`file://${TEMPLATE}`);
  await page.evaluate(
    ({ css, fontFaces, variables, caption, image, width, height }) => {
      document.querySelector("#design-tokens").textContent = css;
      document.querySelector("#brand-fonts").textContent = fontFaces;
      document.documentElement.style.cssText = `${variables} --frame-width: ${width}px; --frame-height: ${height}px;`;
      document.querySelector("#caption").textContent = caption;
      document.querySelector("#screenshot").src = image;
    },
    {
      css,
      fontFaces,
      variables,
      caption: item.caption,
      image: `data:image/png;base64,${screenshot.toString("base64")}`,
      width: item.width,
      height: item.height,
    },
  );

  // Fonts and the embedded screenshot must be decoded before capture, or the
  // first image renders in a fallback face.
  await page.evaluate(() => document.fonts.ready);
  await page.evaluate(
    () =>
      new Promise((resolve) => {
        const img = document.querySelector("#screenshot");
        if (img.complete) {
          resolve();
          return;
        }
        img.addEventListener("load", resolve, { once: true });
      }),
  );

  const destination = join(OUTPUT_DIR, item.locale, `${String(item.slot).padStart(2, "0")}-${item.id}.jpg`);
  await mkdir(dirname(destination), { recursive: true });

  // JPEG, not PNG: Apple accepts both, and the framed output is ~5MB as JPEG
  // against ~15MB as PNG for images that get committed.
  const buffer = await page.screenshot({ type: "jpeg", quality: 92 });
  await writeFile(destination, buffer);
  await page.close();

  console.log(`  ${item.deviceId} slot ${item.slot}: "${item.caption}" -> ${item.locale}/${String(item.slot).padStart(2, "0")}-${item.id}.jpg`);
}

function kebab(value) {
  return value.replace(/[A-Z]/gu, (character) => `-${character.toLowerCase()}`);
}

function fail(message, remedy) {
  console.error(`store-images: ${message}\n  fix: ${remedy}`);
  process.exit(1);
}

await main();
