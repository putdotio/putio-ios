#!/usr/bin/env node

// Frames the raw store screenshots into finished App Store marketing images:
// brand-yellow field, bold caption, screenshot in a rounded black device that
// runs off the bottom edge — matching the Apple TV and Android TV listings.
//
// Input comes from `mise run store-screenshots` (gitignored). Output is
// committed, so it is reviewed as an image diff before upload.
//
// Brand values come from @putdotio/design and the caption face is the licensed
// GT America the app bundles, so these match the product rather than resemble it.
//
// Usage (run directly — Node strips the types, there is no build step):
//   node scripts/store-images.ts          # render into fastlane/screenshots/
//   node scripts/store-images.ts --check  # verify inputs without rendering

import { existsSync } from "node:fs";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";
import { chromium } from "playwright";
import type { Browser } from "playwright";
import { computeLock, LOCALE, LOCK_PATH, storeImageName as lockImageName } from "./store-images-lock.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCREENSHOTS_CONFIG = join(ROOT, "Config/StoreScreenshots.json");
const CAPTIONS_CONFIG = join(ROOT, "Config/StoreCaptions.json");
const TEMPLATE = join(ROOT, "scripts/store-images/template.html");
const RAW_DIR = join(ROOT, "dist/store-screenshots");
const OUTPUT_DIR = join(ROOT, "fastlane/screenshots");
const FONTS_DIR = join(ROOT, "Putio/Fonts");

// The weight the caption is set in; template.html must agree.
const CAPTION_WEIGHT = 900;

// Proportional layout: each value declares its own axis — widths against width,
// vertical rhythm against height. Scaling everything off one axis makes the
// device wider than the canvas on a tall phone.
//
// These ratios are iPhone's. The two radii do not generalize: a corner radius is
// physical device geometry, and a phone's corners are far rounder relative to
// its width than a tablet's. A device whose corners differ declares its own in
// Config/StoreScreenshots.json.
const LAYOUT = {
  captionSize: ["width", 0.082],
  captionPaddingBlock: ["height", 0.042],
  captionPaddingInline: ["width", 0.09],
  // Fixed rather than auto, so one- and two-line captions place the device at
  // the same y. Measured, not derived: GT America Black's ascent and descent
  // make the line box taller than the 1.1 line height. A third line overflows,
  // which render() refuses rather than clips.
  captionBlock: ["height", 0.13],
  // Wide enough that the bottom-aligned device reaches up under the caption;
  // at 0.8 it leaves a visible band of dead yellow between the two.
  deviceWidth: ["width", 0.86],
  deviceBezel: ["width", 0.014],
  deviceRadius: ["width", 0.075],
  screenRadius: ["width", 0.062],
} as const satisfies Record<string, readonly [Axis, number]>;

type Axis = "width" | "height";

/** Ratio overrides a device may declare, keyed by the LAYOUT entry they replace. */
type LayoutOverrides = Partial<Record<keyof typeof LAYOUT, number>>;

interface ScreenshotEntry {
  slot: number;
  baseline: string;
  id: string;
  captionKey: string;
}

interface Device {
  width: number;
  height: number;
  layout?: LayoutOverrides;
  screenshots: ScreenshotEntry[];
}

interface Config {
  devices: Record<string, Device>;
}

interface Captions {
  locales?: Record<string, Record<string, string>>;
}

/** One image to render: a raw capture, the caption over it, and the canvas it fills. */
interface PlanItem {
  deviceId: string;
  slot: number;
  id: string;
  caption: string;
  rawName: string;
  rawPath: string;
  width: number;
  height: number;
  layout: LayoutOverrides | undefined;
  locale: string;
}

async function main(): Promise<void> {
  const checkOnly = process.argv.includes("--check");
  const config = JSON.parse(await readFile(SCREENSHOTS_CONFIG, "utf8"));
  const captions = JSON.parse(await readFile(CAPTIONS_CONFIG, "utf8"));
  const locale = LOCALE;
  const strings = captions.locales?.[locale];

  if (!strings) {
    fail(`no captions for locale ${locale}`, "Add it to Config/StoreCaptions.json.");
  }

  const plan = await buildPlan(config, strings, locale);

  // Always a config mistake, never an intent to publish zero screenshots.
  // Without this the swap below deletes the committed set and then fails.
  if (plan.length === 0) {
    fail(
      "the plan is empty — no device declares any screenshots.",
      "Check the devices block in Config/StoreScreenshots.json. Refusing rather than replacing the committed set with nothing.",
    );
  }

  // Validated in both modes, so --check is a real preflight rather than one
  // that passes and then fails on render.
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

  // Before rendering, so a lock that cannot be built fails while the committed
  // set is untouched. It hashes inputs, never output, so nothing need exist yet.
  const lock = `${JSON.stringify(await computeLock(), null, 2)}\n`;

  // Staging plus swap on success: wiping up front would leave a half-written
  // listing if the browser died mid-loop, and a diff would read it as intended.
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

  // Moved aside rather than deleted: a rename failing after an rm would leave
  // the listing path gone and the new images stranded under .staging.
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

  // After the swap: the lock must never describe a set that is not on disk.
  await writeFile(LOCK_PATH, lock);

  console.log(`rendered ${plan.length} store images into fastlane/screenshots/`);
}

/**
 * pnpm 10+ blocks postinstall scripts unless the package is allowlisted, so a
 * clean install leaves no browser for chromium.launch(). The mise task installs
 * one; a direct node invocation would otherwise fail deep inside Playwright
 * with a stack rather than a remedy.
 */
function assertBrowserInstalled(): void {
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

async function designTokens(): Promise<string> {
  const path = join(ROOT, "node_modules/@putdotio/design/dist/css/tokens.css");

  if (!existsSync(path)) {
    fail(
      "@putdotio/design is not installed, so brand tokens are unavailable.",
      "Run pnpm install. Rendering without tokens would produce off-brand images.",
    );
  }

  return readFile(path, "utf8");
}

async function buildPlan(
  config: Config,
  strings: Record<string, string>,
  locale: string,
): Promise<PlanItem[]> {
  const plan: PlanItem[] = [];

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
        // The LAYOUT ratios were tuned on a 0.46-aspect phone, and two of them
        // fight on a 0.75-aspect tablet: captionSize grows with width while
        // captionBlock shrinks with height. A device declares what its shape
        // needs rather than every committed iPhone image being re-rendered.
        layout: device.layout,
        locale,
      });
    }
  }

  return plan;
}

/**
 * Chromium will not load a local file through @font-face from a data: document,
 * so the faces are embedded. A missing face falls back silently to a system
 * font, which would ship store images in the wrong typography.
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

  const weights: Record<string, number> = { regular: 400, medium: 500, bold: 700, black: 900 };
  const faces: string[] = [];
  const loaded = new Set<number>();

  for (const file of files) {
    const weightName = /gt-america-standard-([a-z]+)\.otf$/u.exec(file)?.[1];
    const weight = weightName === undefined ? undefined : weights[weightName];
    if (weight === undefined) {
      continue;
    }

    const data = await readFile(join(FONTS_DIR, file));
    loaded.add(weight);
    faces.push(
      `@font-face { font-family: "GT America"; font-weight: ${weight}; font-style: normal; ` +
        `src: url(data:font/otf;base64,${data.toString("base64")}) format("opentype"); }`,
    );
  }

  // Files existing is not usable faces existing: a rename would leave this
  // empty, and an empty @font-face block falls back to a system font.
  if (faces.length === 0) {
    fail(
      `found ${files.length} GT America file(s) in Putio/Fonts but none matched gt-america-standard-<weight>.otf.`,
      "Run mise run fonts-setup. If the upstream naming changed, update the weight map in this script.",
    );
  }

  // The template sets captions in 900, so a partial install carrying only
  // lighter weights would render them in a system font and still report success.
  if (!loaded.has(CAPTION_WEIGHT)) {
    fail(
      `GT America ${CAPTION_WEIGHT} (black) is missing from Putio/Fonts; found ${[...loaded].sort().join(", ") || "nothing usable"}.`,
      "Run mise run fonts-setup. Captions are set in the black weight, so a partial install would silently fall back.",
    );
  }

  return faces.join("\n");
}

async function render(
  browser: Browser,
  item: PlanItem,
  css: string,
  fontFaces: string,
  outputDir: string,
): Promise<void> {
  const page = await browser.newPage({
    viewport: { width: item.width, height: item.height },
    deviceScaleFactor: 1,
  });

  const screenshot = await readFile(item.rawPath);
  const entries = Object.entries(LAYOUT) as [keyof typeof LAYOUT, readonly [Axis, number]][];
  const variables = entries
    .map(([name, [axis, ratio]]) => {
      const basis = axis === "width" ? item.width : item.height;
      const resolved = item.layout?.[name] ?? ratio;
      return `--${kebab(name)}: ${Math.round(resolved * basis)}px;`;
    })
    .join("\n");

  await page.goto(`file://${TEMPLATE}`);
  await page.evaluate(
    ({ css, fontFaces, variables, caption, image, width, height }) => {
      // The template is the only thing that can make this fail, so name the
      // missing id rather than throwing a TypeError from deep in the page.
      const need = <T extends Element>(selector: string): T => {
        const element = document.querySelector<T>(selector);
        if (!element) {
          throw new Error(`template.html has no ${selector}`);
        }
        return element;
      };

      need("#design-tokens").textContent = css;
      need("#brand-fonts").textContent = fontFaces;
      document.documentElement.style.cssText = `${variables} --frame-width: ${width}px; --frame-height: ${height}px;`;
      need("#caption").textContent = caption;
      need<HTMLImageElement>("#screenshot").src = image;
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

  // Fonts and the embedded screenshot must decode before capture, or the first
  // image renders in a fallback face.
  //
  // `fonts.ready` resolves once every attempt finishes, failures included, so a
  // corrupt OTF would still report success. Ask the font set what happened.
  const fontProblem = await page.evaluate(async (weight) => {
    await document.fonts.ready;
    const faces = [...document.fonts].filter((face) => face.family === "GT America");
    const errored = faces.filter((face) => face.status === "error").map((face) => face.weight);

    if (errored.length > 0) {
      return `Chromium could not parse these GT America faces: ${errored.join(", ")}`;
    }

    // Only the caption weight has to be live; unused weights stay "unloaded".
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
    // Thrown, not fail()ed — see the caption check below.
    throw new RenderError(
      `${item.deviceId} slot ${item.slot}: ${fontProblem}.`,
      "Run mise run fonts-setup to reinstall the licensed faces; mise run verify-fonts verifies them against Config/BrandFonts.json.",
    );
  }
  // Resolving only on `load` would hang the run on a decode failure rather
  // than failing it. Reject on error, and cap the wait.
  await page.evaluate(
    () =>
      new Promise<void>((resolve, reject) => {
        const img = document.querySelector<HTMLImageElement>("#screenshot");
        if (!img) {
          reject(new Error("template.html has no #screenshot"));
          return;
        }
        if (img.complete) {
          // Already failed, and its error event fired before this ran, so
          // waiting would burn the whole timeout for the same answer.
          if (img.naturalWidth > 0) {
            resolve();
          } else {
            reject(new Error("screenshot failed to decode"));
          }
          return;
        }
        const timer = setTimeout(() => reject(new Error("screenshot did not decode within 10s")), 10_000);
        // `load` can fire on an image with no intrinsic size, which renders as
        // a blank device screen.
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

  // The caption row is a fixed two-line height, so a longer string is silently
  // clipped by the body's overflow: hidden. A half-visible caption in a store
  // listing is worse than a failed render.
  const captionOverflow = await page.evaluate(() => {
    const caption = document.querySelector("#caption");
    if (!caption) {
      throw new Error("template.html has no #caption");
    }
    return caption.scrollHeight - caption.clientHeight;
  });

  if (captionOverflow > 1) {
    // fail() exits the process, skipping main's finally and leaving Chromium
    // running with .staging on disk.
    throw new RenderError(
      `${item.deviceId} slot ${item.slot}: "${item.caption}" does not fit the caption row.`,
      "Shorten it in Config/StoreCaptions.json, or raise captionBlock — in the LAYOUT table for every device, or in this device's layout block in Config/StoreScreenshots.json. Raising it also wants deviceWidth adjusted, which the device-fit check below enforces.",
    );
  }

  // The device's height is intrinsic, so it can miss the space under the
  // caption either way and the caption check above sees neither: too tall it
  // grows upward over the caption, too short it leaves a band of yellow.
  //
  // Only the top edge is measurable — align-self: end keeps the bottom flush at
  // every size, so a bottom measurement is always zero.
  const captionToDevice = await page.evaluate(() => {
    const device = document.querySelector(".device");
    const caption = document.querySelector("#caption");
    if (!device || !caption) {
      throw new Error("template.html has no .device or no #caption");
    }
    return device.getBoundingClientRect().top - caption.getBoundingClientRect().bottom;
  });

  // Measured, not guessed: the shipped iPhone layout leaves 3.11% and iPad's
  // fitted one leaves 0, so this accepts both while still catching a visible band.
  const slack = item.height * 0.04;

  if (captionToDevice < 0 || captionToDevice > slack) {
    throw new RenderError(
      captionToDevice < 0
        ? `${item.deviceId} slot ${item.slot}: the device overlaps the caption by ${Math.abs(Math.round(captionToDevice))}px.`
        : `${item.deviceId} slot ${item.slot}: ${Math.round(captionToDevice)}px of empty yellow sits between the caption and the device, over the ${Math.round(slack)}px allowed.`,
      "Adjust deviceWidth for this device in Config/StoreScreenshots.json so the device height fills the row under the caption.",
    );
  }

  const destination = join(outputDir, item.locale, storeImageName(item));
  await mkdir(dirname(destination), { recursive: true });

  // Apple accepts both, and these get committed: JPEG is roughly a third of
  // PNG here.
  const buffer = await page.screenshot({ type: "jpeg", quality: 92 });
  await writeFile(destination, buffer);
  await page.close();

  console.log(`  ${item.deviceId} slot ${item.slot}: "${item.caption}" -> ${item.locale}/${storeImageName(item)}`);
}

// Every device declares the same slots and ids, so without a device scope the
// iPad render would overwrite the iPhone one in the same locale directory.
// deliver reads the display type from pixel size, not the name, so the prefix
// only has to sort each device's own slots — which a zero-padded slot does.
function storeImageName(item: PlanItem): string {
  return lockImageName(item.deviceId, item.slot, item.id);
}

function kebab(value: string): string {
  return value.replace(/[A-Z]/gu, (character) => `-${character.toLowerCase()}`);
}

function fail(message: string, remedy: string): never {
  console.error(`store-images: ${message}\n  fix: ${remedy}`);
  process.exit(1);
}

/**
 * A failure raised inside the render loop, where exiting directly would skip the
 * cleanup that closes Chromium and removes the staging directory.
 */
class RenderError extends Error {
  readonly remedy: string;

  constructor(message: string, remedy: string) {
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
