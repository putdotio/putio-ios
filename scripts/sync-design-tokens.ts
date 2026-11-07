#!/usr/bin/env node

import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const TOKENS_PATH = join(ROOT, "Config", "DesignTokens.json");
const COLORS_ROOT = join(ROOT, "Putio", "Assets.xcassets", "Colors");
const SWIFT_PATH = join(ROOT, "Putio", "Common", "Extensions", "UIColor+Putio.swift");

export interface Components {
  red: string;
  green: string;
  blue: string;
  alpha: string;
}

export interface ColorToken {
  group: string;
  key: string;
  light: Components;
  dark: Components;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function rubyToF(text: string): number {
  const value = Number.parseFloat(text);
  return Number.isNaN(value) ? 0 : value;
}

const TENS = Array.from({ length: 23 }, (_, i) => Number(`1e${i}`));
const QUICK_MAX = 14;

function words(value: number): { hi: number; lo: number } {
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, value);
  return { hi: view.getUint32(0), lo: view.getUint32(4) };
}

function fromWords(hi: number, lo: number): number {
  const view = new DataView(new ArrayBuffer(8));
  view.setUint32(0, hi >>> 0);
  view.setUint32(4, lo >>> 0);
  return view.getFloat64(0);
}

function exactParts(value: number): { mantissa: bigint; exponent: number } {
  const { hi, lo } = words(value);
  const biased = (hi >>> 20) & 0x7ff;
  const fraction = (BigInt(hi & 0xfffff) << 32n) | BigInt(lo);
  return biased === 0
    ? { mantissa: fraction, exponent: -1074 }
    : { mantissa: fraction | (1n << 52n), exponent: biased - 1075 };
}

function bumpUp(digits: string, k: number, allowIncrement: (digit: number) => boolean): { digits: string; k: number } {
  let end = digits.length;
  while (end > 0 && digits[end - 1] === "9") end--;
  if (end === 0) return { digits: "1", k: k + 1 };
  const digit = Number(digits[end - 1]);
  if (!allowIncrement(digit)) return { digits: digits.slice(0, end), k };
  return { digits: digits.slice(0, end - 1) + String(digit + 1), k };
}

function exactDigits(value: number, ndigits: number, half: boolean): { digits: string; k: number } {
  const { mantissa, exponent } = exactParts(value);
  const scale = 10n ** BigInt(ndigits);
  let numerator = mantissa * scale;
  let denominator = 1n;
  if (exponent >= 0) numerator <<= BigInt(exponent);
  else denominator <<= BigInt(-exponent);
  const quotient = numerator / denominator;
  const twiceRemainder = 2n * (numerator % denominator);
  const digits = quotient.toString();
  const k = digits.length - 1 - ndigits;
  if (quotient === 0n) {
    return twiceRemainder > denominator ? { digits: "1", k: -ndigits } : { digits: "", k };
  }
  const lastOdd = Number(digits.at(-1)) % 2 === 1;
  if (twiceRemainder > denominator || (twiceRemainder === denominator && lastOdd)) {
    return bumpUp(digits, k, (digit) => !half || digit % 2 === 1);
  }
  return { digits, k };
}

function quickDigits(value: number, ndigits: number): { digits: string; k: number } | "fast_failed" | "half" {
  const { hi, lo } = words(value);
  const biased = (hi >>> 20) & 0x7ff;
  if (biased === 0) return "fast_failed";
  const d2 = fromWords((hi & 0xfffff) | 0x3ff00000, lo);
  const i = biased - 1023;
  const ds = (d2 - 1.5) * 0.289529654602168 + 0.1760912590558 + i * 0.301029995663981;
  let k = Math.trunc(ds);
  if (ds < 0 && ds !== k) k--;
  let kCheck = true;
  if (k >= 0 && k <= 22) {
    if (value < (TENS[k] ?? 1)) k--;
    kCheck = false;
  }
  let ilim = ndigits + k + 1;
  const ilim1 = ilim - 1;
  if (ilim < 0 || ilim > QUICK_MAX) return "fast_failed";

  let d = value;
  let ieps = 2;
  if (k > 0) d /= TENS[k] ?? 1;
  else if (k < 0) d *= TENS[-k] ?? 1;
  if (kCheck && d < 1 && ilim > 0) {
    if (ilim1 <= 0) return "fast_failed";
    ilim = ilim1;
    k--;
    d *= 10;
    ieps++;
  }
  let eps = (ieps * d + 7) * 2 ** -52;
  if (ilim === 0) {
    d -= 5;
    if (d > eps) return { digits: "1", k: k + 1 };
    if (d < -eps) return { digits: "", k };
    return "fast_failed";
  }
  eps *= TENS[ilim - 1] ?? 1;
  let digits = "";
  for (let place = 1; ; place++, d *= 10) {
    const L = Math.trunc(d);
    d -= L;
    if (d === 0) ilim = place;
    digits += String(L);
    if (place === ilim) {
      if (d > 0.5 + eps) return bumpUp(digits, k, () => true);
      if (d < 0.5 - eps) return { digits, k };
      if (L % 2 === 1) return bumpUp(digits, k, () => true);
      return "half";
    }
  }
}

export function formatFixed(value: number, ndigits: number): string {
  const sign = value < 0 || Object.is(value, -0) ? "-" : "";
  const magnitude = Math.abs(value);
  let result: { digits: string; k: number };
  if (magnitude === 0) {
    result = { digits: "", k: 0 };
  } else {
    const quick = quickDigits(magnitude, ndigits);
    result = typeof quick === "string" ? exactDigits(magnitude, ndigits, quick === "half") : quick;
  }
  const scaled = result.digits === "" ? 0n : BigInt(result.digits) * 10n ** BigInt(ndigits + result.k + 1 - result.digits.length);
  const text = scaled.toString().padStart(ndigits + 1, "0");
  return `${sign}${text.slice(0, -ndigits)}.${text.slice(-ndigits)}`;
}

const HSL_PATTERN =
  /^hsla?\([ \t\r\n\f\v]*([\d.]+)[ \t\r\n\f\v]*,[ \t\r\n\f\v]*([\d.]+)%[ \t\r\n\f\v]*,[ \t\r\n\f\v]*([\d.]+)%[ \t\r\n\f\v]*(?:,[ \t\r\n\f\v]*([\d.]+)[ \t\r\n\f\v]*)?\)$/;

export function parseHsl(value: unknown): Components {
  const match = typeof value === "string" ? HSL_PATTERN.exec(value) : null;
  if (!match) {
    throw new Error(`Unparseable color value: ${JSON.stringify(value)}`);
  }

  const h = rubyToF(match[1] ?? "");
  const s = rubyToF(match[2] ?? "") / 100.0;
  const l = rubyToF(match[3] ?? "") / 100.0;
  const alpha = rubyToF(match[4] ?? "1");

  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60.0) % 2) - 1));
  const m = l - c / 2.0;

  let rgb: [number, number, number];
  if (h >= 0 && h < 60) rgb = [c, x, 0];
  else if (h >= 60 && h < 120) rgb = [x, c, 0];
  else if (h >= 120 && h < 180) rgb = [0, c, x];
  else if (h >= 180 && h < 240) rgb = [0, x, c];
  else if (h >= 240 && h < 300) rgb = [x, 0, c];
  else rgb = [c, 0, x];

  return {
    red: formatFixed(rgb[0] + m, 3),
    green: formatFixed(rgb[1] + m, 3),
    blue: formatFixed(rgb[2] + m, 3),
    alpha: formatFixed(alpha, 3),
  };
}

export function collectColorTokens(tokens: Record<string, unknown>): ColorToken[] {
  const collected: ColorToken[] = [];
  for (const [group, entries] of Object.entries(tokens)) {
    if (group.startsWith("$")) continue;
    if (!isRecord(entries)) {
      throw new TypeError(`Token group ${JSON.stringify(group)} is not an object`);
    }

    for (const [key, definition] of Object.entries(entries)) {
      if (key.startsWith("$")) continue;
      if (!isRecord(definition) || definition["$type"] !== "color") continue;
      const value = definition["$value"];
      if (typeof value !== "string" || !value.startsWith("hsl")) continue;

      const light = parseHsl(value);
      const extensions = definition["$extensions"];
      const mode = isRecord(extensions) ? extensions["putio.mode"] : undefined;
      const darkRaw = isRecord(mode) ? mode["dark"] : undefined;
      collected.push({
        group,
        key,
        light,
        dark: darkRaw !== undefined && darkRaw !== null && darkRaw !== false ? parseHsl(darkRaw) : light,
      });
    }
  }
  return collected;
}

function capitalize(word: string): string {
  return word.charAt(0).toUpperCase() + word.slice(1).toLowerCase();
}

export function swiftName(key: string): string {
  const [first = "", ...rest] = key.split("-");
  const name = first + rest.map(capitalize).join("");
  return /^\d/.test(name) ? `step${name}` : name;
}

function byteOrder(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function assetName(token: ColorToken): string {
  return `putio.${token.group}.${token.key}`;
}

function colorEntry(components: Components, appearances: unknown[] | null): Record<string, unknown> {
  const entry: Record<string, unknown> = {};
  if (appearances) entry["appearances"] = appearances;
  entry["color"] = {
    "color-space": "srgb",
    components: {
      alpha: components.alpha,
      blue: components.blue,
      green: components.green,
      red: components.red,
    },
  };
  entry["idiom"] = "universal";
  return entry;
}

export function colorsetContents(token: ColorToken): string {
  const contents = {
    colors: [
      colorEntry(token.light, null),
      colorEntry(token.dark, [{ appearance: "luminosity", value: "dark" }]),
    ],
    info: { author: "xcode", version: 1 },
  };
  return `${JSON.stringify(contents, null, 2)}\n`;
}

export function swiftSource(colorTokens: ColorToken[]): string {
  const groups = new Map<string, ColorToken[]>();
  for (const token of colorTokens) {
    const list = groups.get(token.group) ?? [];
    list.push(token);
    groups.set(token.group, list);
  }

  const lines = [
    "import UIKit",
    "",
    "// Generated by scripts/sync-design-tokens.ts from Config/DesignTokens.json.",
    "// Do not edit; run `mise run tokens-sync` after token changes.",
    "extension UIColor {",
    "    struct Putio {",
  ];

  for (const group of [...groups.keys()].sort(byteOrder)) {
    lines.push(`        struct ${group.split("-").map(capitalize).join("")} {`);
    const sorted = [...(groups.get(group) ?? [])].sort((a, b) => byteOrder(a.key, b.key));
    for (const token of sorted) {
      lines.push(`            static let ${swiftName(token.key)} = UIColor(named: "${assetName(token)}")!`);
    }
    lines.push("        }");
    lines.push("");
  }

  lines.push("    }");
  lines.push("}");
  return `${lines.join("\n")}\n`;
}

function sortedEntries(dir: string): string[] {
  try {
    return readdirSync(dir)
      .filter((name) => !name.startsWith("."))
      .sort(byteOrder);
  } catch {
    return [];
  }
}

function isRealDirectory(path: string): boolean {
  try {
    return lstatSync(path).isDirectory();
  } catch {
    return false;
  }
}

function globRecursive(dir: string, extensions: string[]): string[] {
  const matches: string[] = [];
  const walk = (current: string): void => {
    for (const name of sortedEntries(current)) {
      const path = join(current, name);
      if (extensions.some((extension) => name.endsWith(extension))) matches.push(path);
      if (isRealDirectory(path)) walk(path);
    }
  };
  walk(dir);
  return matches;
}

class DesignTokenSync {
  readonly #checkOnly: boolean;
  readonly #tokens: Record<string, unknown>;
  readonly #drift: string[] = [];

  constructor(checkOnly: boolean) {
    this.#checkOnly = checkOnly;
    const parsed: unknown = JSON.parse(readFileSync(TOKENS_PATH, "utf8"));
    if (!isRecord(parsed)) throw new TypeError(`${TOKENS_PATH} is not a JSON object`);
    this.#tokens = parsed;
  }

  run(): void {
    const colorTokens = collectColorTokens(this.#tokens);

    for (const token of colorTokens) {
      this.#writeOutput(join(COLORS_ROOT, `${assetName(token)}.colorset`, "Contents.json"), colorsetContents(token));
    }

    this.#removeUnlistedColorsets(colorTokens);
    this.#writeOutput(SWIFT_PATH, swiftSource(colorTokens));

    if (this.#checkOnly) {
      this.#checkInterfaceBuilderReferences(colorTokens);

      if (this.#drift.length > 0) {
        console.error("Design tokens are out of sync. Run: mise run tokens-sync");
        for (const path of this.#drift) console.error(`  drift: ${path}`);
        process.exit(1);
      }
      console.log(`Verified ${colorTokens.length} design tokens.`);
    } else {
      console.log(`Generated ${colorTokens.length} colorsets and UIColor+Putio.swift.`);
    }
  }

  #checkInterfaceBuilderReferences(colorTokens: ColorToken[]): void {
    const known = new Set(colorTokens.map(assetName));
    const putioRoot = join(ROOT, "Putio");
    const ibFiles = [
      ...globRecursive(putioRoot, [".storyboard", ".xib"]),
      ...sortedEntries(ROOT)
        .filter((name) => name.endsWith(".storyboard"))
        .map((name) => join(ROOT, name)),
    ];

    for (const path of ibFiles) {
      const names = new Set<string>();
      for (const match of readFileSync(path, "utf8").matchAll(/name="(putio\.[^"]+)"/g)) {
        if (match[1] !== undefined) names.add(match[1]);
      }
      for (const name of names) {
        if (known.has(name)) continue;
        this.#drift.push(`${relative(ROOT, path)} references unknown color ${name}`);
      }
    }
  }

  #removeUnlistedColorsets(colorTokens: ColorToken[]): void {
    const expected = new Set(colorTokens.map((token) => `${assetName(token)}.colorset`));

    for (const name of sortedEntries(COLORS_ROOT)) {
      if (!name.endsWith(".colorset") || expected.has(name)) continue;
      const dir = join(COLORS_ROOT, name);

      if (this.#checkOnly) {
        this.#drift.push(dir);
      } else {
        rmSync(dir, { recursive: true, force: true });
      }
    }
  }

  #writeOutput(path: string, content: string): void {
    if (this.#checkOnly) {
      if (!existsSync(path) || !readFileSync(path).equals(Buffer.from(content))) this.#drift.push(path);
    } else {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, content);
    }
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  new DesignTokenSync(process.argv.slice(2).includes("--check")).run();
}
