#!/usr/bin/env node

// Frames the raw store screenshots into finished App Store marketing images:
// brand-yellow field, bold caption, screenshot in a rounded black device that
// runs off the bottom edge — the treatment the Apple TV and Android TV listings
// already use.
//
// Input comes from `mise run store-screenshots` (gitignored, intermediate). Output
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
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
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

// The weight the caption is set in; template.html must agree.
const CAPTION_WEIGHT = 900;

// Proportional layout, so the same template holds for any device size Apple
// introduces. Each value declares which axis it scales against: widths against
// width, vertical rhythm against height. Scaling everything off one axis makes
// the device wider than the canvas on a tall phone.
const LAYOUT = {
  captionSize: ["width", 0.082],
  captionPaddingBlock: ["height", 0.042],
  captionPaddingInline: ["width", 0.09],
  // The caption row is a fixed height rather than auto, so a one-line caption
  // and a two-line one place the device at exactly the same y. Sized for the
  // top padding plus two lines: 373px against the 366px GT America Black
  // actually occupies at this size — its ascent and descent make the line box
  // taller than the 1.1 line height, so this cannot be derived from the two
  // ratios above. A third line overflows, which render() refuses rather than
  // clipping.
  captionBlock: ["height", 0.13],
  // Wide enough that the bottom-aligned device reaches up close under the
  // caption. At 0.8 it is only 2234px tall on a 2868px canvas and leaves ~294px
  // of dead yellow between the two.
  deviceWidth: ["width", 0.86],
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

  // An empty plan is always a config mistake, never an intent to publish zero
  // screenshots. Without this the swap below deletes the committed set and then
  // fails, because nothing ever created the staging directory.
  if (plan.length === 0) {
    fail(
      "the plan is empty — no device declares any screenshots.",
      "Check the devices block in Config/StoreScreenshots.json. Refusing rather than replacing the committed set with nothing.",
    );
  }

  // Every render prerequisite is validated in both modes, so --check is a real
  // preflight rather than a partial one that passes and then fails on render.
  const css = await designTokens();
  const fontFaces = await brandFontFaces();
  assertBrowserInstalled();

  if (!existsSync(TEMPLATE)) {
    fail(
      `the render template is missing at ${TEMPLATE}.`,
      "Restore scripts/store-images/template.html — without it every render fails at page.goto.",
    );
  }

  if (checkOnly) {
    for (const item of plan) {
      console.log(`${item.deviceId} slot ${item.slot}: "${item.caption}" over ${item.rawName}`);
    }
    console.log(`checked ${plan.length} store images`);
    return;
  }

  // Render into a staging directory and swap on success. Wiping the committed
  // set up front would leave a half-written listing behind if the browser died
  // mid-loop, and the missing images would look intentional in a diff.
  const staging = `${OUTPUT_DIR}.staging`;
  await rm(staging, { recursive: true, force: true });

  const browser = await chromium.launch();
  try {
    for (const item of plan) {
      await render(browser, item, css, fontFaces, staging);
    }
  } catch (error) {
    await rm(staging, { recursive: true, force: true });
    throw error;
  } finally {
    await browser.close();
  }

  // Move the committed set aside rather than deleting it: a rename that fails
  // after an rm would leave the listing path gone with the new images stranded
  // under .staging, which is worse than the mid-loop failure staging prevents.
  const previous = `${OUTPUT_DIR}.previous`;
  await rm(previous, { recursive: true, force: true });

  if (existsSync(OUTPUT_DIR)) {
    await rename(OUTPUT_DIR, previous);
  }

  try {
    await rename(staging, OUTPUT_DIR);
  } catch (error) {
    if (existsSync(previous)) {
      await rename(previous, OUTPUT_DIR);
    }
    throw error;
  }

  await rm(previous, { recursive: true, force: true });

  console.log(`rendered ${plan.length} store images into fastlane/screenshots/`);
}

/**
 * The playwright package does not bring a browser with it here: pnpm 10+ blocks
 * postinstall scripts unless the package is allowlisted, so a clean
 * `pnpm install` leaves nothing for chromium.launch() to start. `make
 * store-images` installs it, but a direct node invocation would otherwise fail
 * deep inside Playwright with a stack rather than a remedy.
 */
function assertBrowserInstalled() {
  let executable;
  try {
    executable = chromium.executablePath();
  } catch {
    executable = "";
  }

  if (!executable || !existsSync(executable)) {
    fail(
      "Playwright has no Chromium to drive.",
      "Run pnpm exec playwright install chromium — or use mise run store-images, which does it for you.",
    );
  }
}

async function designTokens() {
  const path = join(ROOT, "node_modules/@putdotio/design/dist/css/tokens.css");

  if (!existsSync(path)) {
    fail(
      "@putdotio/design is not installed, so brand tokens are unavailable.",
      "Run pnpm install. Rendering without tokens would produce off-brand images.",
    );
  }

  return readFile(path, "utf8");
}

async function buildPlan(config, strings, locale) {
  const plan = [];

  for (const [deviceId, device] of Object.entries(config.devices)) {
    const rawDir = join(RAW_DIR, deviceId);

    if (!existsSync(rawDir)) {
      fail(
        `${deviceId}: no raw screenshots at dist/store-screenshots/${deviceId}/.`,
        "Run mise run store-screenshots first — this step frames its output, it does not capture.",
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
          "Re-run mise run store-screenshots; the two configs may have drifted.",
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
        // Per-device ratio overrides for the LAYOUT table. The ratios below were
        // tuned on a 0.46-aspect phone, and two of them fight on a 0.75-aspect
        // tablet: captionSize scales with width so the text grows, captionBlock
        // scales with height so its box shrinks. Rather than rebalance the axes
        // and re-render every committed iPhone image over it, a device declares
        // the ratios its shape needs.
        layout: device.layout,
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
      "Run mise run fonts-setup. Store images must use GT America; a system-font fallback would ship the wrong typography.",
    );
  }

  const files = (await readdir(FONTS_DIR)).filter((name) => name.startsWith("gt-america-") && name.endsWith(".otf"));

  if (files.length === 0) {
    fail("no GT America faces found in Putio/Fonts.", "Run mise run fonts-setup.");
  }

  const weights = { regular: 400, medium: 500, bold: 700, black: 900 };
  const faces = [];
  const loaded = new Set();

  for (const file of files) {
    const weightName = /gt-america-standard-([a-z]+)\.otf$/u.exec(file)?.[1];
    const weight = weights[weightName];
    if (!weight) {
      continue;
    }

    const data = await readFile(join(FONTS_DIR, file));
    loaded.add(weight);
    faces.push(
      `@font-face { font-family: "GT America"; font-weight: ${weight}; font-style: normal; ` +
        `src: url(data:font/otf;base64,${data.toString("base64")}) format("opentype"); }`,
    );
  }

  // Files existing is not the same as usable faces existing: a rename or a new
  // naming scheme would leave this empty, and an empty @font-face block falls
  // back to a system font — the exact outcome this function exists to prevent.
  if (faces.length === 0) {
    fail(
      `found ${files.length} GT America file(s) in Putio/Fonts but none matched gt-america-standard-<weight>.otf.`,
      "Run mise run fonts-setup. If the upstream naming changed, update the weight map in this script.",
    );
  }

  // Having *a* face is not enough. The template sets captions in 900, so a
  // partial install holding only, say, the regular weight would render every
  // caption in a system font while this function reported success.
  if (!loaded.has(CAPTION_WEIGHT)) {
    fail(
      `GT America ${CAPTION_WEIGHT} (black) is missing from Putio/Fonts; found ${[...loaded].sort().join(", ") || "nothing usable"}.`,
      "Run mise run fonts-setup. Captions are set in the black weight, so a partial install would silently fall back.",
    );
  }

  return faces.join("\n");
}

async function render(browser, item, css, fontFaces, outputDir) {
  const page = await browser.newPage({
    viewport: { width: item.width, height: item.height },
    deviceScaleFactor: 1,
  });

  const screenshot = await readFile(item.rawPath);
  const variables = Object.entries(LAYOUT)
    .map(([name, [axis, ratio]]) => {
      const basis = axis === "width" ? item.width : item.height;
      const resolved = item.layout?.[name] ?? ratio;
      return `--${kebab(name)}: ${Math.round(resolved * basis)}px;`;
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
  //
  // `fonts.ready` settling is not the same as the faces having loaded: it
  // resolves once every attempt has finished, failures included, so a corrupt
  // OTF would paint the caption in the template's system-ui fallback and still
  // report success. Ask the font set what actually happened.
  const fontProblem = await page.evaluate(async (weight) => {
    await document.fonts.ready;
    const faces = [...document.fonts].filter((face) => face.family === "GT America");
    const errored = faces.filter((face) => face.status === "error").map((face) => face.weight);

    if (errored.length > 0) {
      return `Chromium could not parse these GT America faces: ${errored.join(", ")}`;
    }

    // Unused weights stay "unloaded" and that is fine — only the caption weight
    // has to be live, because it is the only one the template paints with.
    const caption = faces.find((face) => Number(face.weight) === weight);
    if (!caption) {
      return `no GT America face was declared at weight ${weight}`;
    }
    if (caption.status !== "loaded") {
      return `the GT America ${weight} face is "${caption.status}" after fonts.ready`;
    }

    return null;
  }, CAPTION_WEIGHT);

  if (fontProblem) {
    // Thrown, not fail()ed, for the same reason as the caption check below.
    throw new RenderError(
      `${item.deviceId} slot ${item.slot}: ${fontProblem}.`,
      "Run mise run fonts-setup to reinstall the licensed faces; mise run fonts-check verifies them against Config/BrandFonts.json.",
    );
  }
  // Resolving only on `load` means a decode failure never settles and the run
  // hangs rather than failing. Reject on error, and cap the wait.
  await page.evaluate(
    () =>
      new Promise((resolve, reject) => {
        const img = document.querySelector("#screenshot");
        if (img.complete) {
          // A completed load with no intrinsic size already failed, and its
          // error event fired before this ran — waiting would burn the whole
          // timeout to reach the same conclusion.
          if (img.naturalWidth > 0) {
            resolve();
          } else {
            reject(new Error("screenshot failed to decode"));
          }
          return;
        }
        const timer = setTimeout(() => reject(new Error("screenshot did not decode within 10s")), 10_000);
        // `load` can fire on an image with no intrinsic size, which renders as
        // a blank device screen — so the same check guards both paths.
        img.addEventListener("load", () => {
          clearTimeout(timer);
          if (img.naturalWidth > 0) {
            resolve();
          } else {
            reject(new Error("screenshot loaded with no intrinsic size"));
          }
        }, { once: true });
        img.addEventListener("error", () => { clearTimeout(timer); reject(new Error("screenshot failed to decode")); }, { once: true });
      }),
  );

  // The caption row is a fixed two-line height, so a longer string would be
  // silently clipped by the body's overflow: hidden. Refuse instead — a
  // half-visible caption in a store listing is worse than a failed render.
  const captionOverflow = await page.evaluate(() => {
    const caption = document.querySelector("#caption");
    return caption.scrollHeight - caption.clientHeight;
  });

  if (captionOverflow > 1) {
    // Thrown rather than fail()ed: fail() exits the process, which would skip
    // main's finally and leave Chromium running and .staging on disk.
    throw new RenderError(
      `${item.deviceId} slot ${item.slot}: "${item.caption}" needs more than the two lines the caption row reserves.`,
      "Shorten it in Config/StoreCaptions.json, or raise captionBlock in the LAYOUT table for every image.",
    );
  }

  // A device taller than the row it sits in grows *upward*, because it is
  // bottom-aligned — so it covers the caption instead of running off the bottom,
  // and the caption check above cannot see it. That is invisible at review size
  // on a phone-shaped canvas and obvious on a squatter one. Both directions are
  // wrong, so measure the gap: negative overlaps the caption, positive leaves a
  // yellow strip along the bottom edge the design does not have.
  const deviceGap = await page.evaluate(() => {
    const device = document.querySelector(".device");
    const caption = document.querySelector("#caption");
    const top = device.getBoundingClientRect().top - caption.getBoundingClientRect().bottom;
    const bottom = document.body.clientHeight - device.getBoundingClientRect().bottom;
    return { top, bottom };
  });

  if (deviceGap.top < 0 || deviceGap.bottom > 1) {
    throw new RenderError(
      deviceGap.top < 0
        ? `${item.deviceId} slot ${item.slot}: the device overlaps the caption by ${Math.abs(Math.round(deviceGap.top))}px.`
        : `${item.deviceId} slot ${item.slot}: the device stops ${Math.round(deviceGap.bottom)}px short of the bottom edge.`,
      "Adjust deviceWidth for this device in Config/StoreScreenshots.json so the device height fills the row under the caption.",
    );
  }

  const destination = join(outputDir, item.locale, storeImageName(item));
  await mkdir(dirname(destination), { recursive: true });

  // JPEG, not PNG: Apple accepts both, and the framed output is ~5MB as JPEG
  // against ~15MB as PNG for images that get committed.
  const buffer = await page.screenshot({ type: "jpeg", quality: 92 });
  await writeFile(destination, buffer);
  await page.close();

  console.log(`  ${item.deviceId} slot ${item.slot}: "${item.caption}" -> ${item.locale}/${storeImageName(item)}`);
}

// Device-scoped, because every device declares the same slots and ids: without
// it the iPad render would overwrite the iPhone one in the same locale
// directory. deliver reads the display type from the image's pixel size rather
// than its name, so the prefix is free — it only has to sort each device's own
// slots in order, which a zero-padded slot does.
function storeImageName(item) {
  return `${item.deviceId}-${String(item.slot).padStart(2, "0")}-${item.id}.jpg`;
}

function kebab(value) {
  return value.replace(/[A-Z]/gu, (character) => `-${character.toLowerCase()}`);
}

function fail(message, remedy) {
  console.error(`store-images: ${message}\n  fix: ${remedy}`);
  process.exit(1);
}

/**
 * A failure raised from inside the render loop, where exiting the process
 * directly would skip the cleanup that closes Chromium and removes the staging
 * directory. Carries the same message and remedy fail() prints.
 */
class RenderError extends Error {
  constructor(message, remedy) {
    super(message);
    this.name = "RenderError";
    this.remedy = remedy;
  }
}

try {
  await main();
} catch (error) {
  if (error instanceof RenderError) {
    fail(error.message, error.remedy);
  }

  throw error;
}
