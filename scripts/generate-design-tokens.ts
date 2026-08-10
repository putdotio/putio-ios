import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const tokenTypes = [
  "color",
  "cubicBezier",
  "dimension",
  "duration",
  "fontFamily",
  "fontWeight",
  "number",
  "string",
] as const;
const tokenModes = ["light", "dark", "global", "tv"] as const;

type TokenType = (typeof tokenTypes)[number];
type TokenMode = (typeof tokenModes)[number];

export type DesignToken = {
  readonly cssName: string;
  readonly type: TokenType;
  readonly mode: TokenMode;
  readonly value: string | number;
  readonly originalValue: string | number;
  readonly description?: string;
  readonly basis?: "viewport-width" | "viewport-height";
  readonly deprecated?: boolean;
};

export type TokenEntry = {
  readonly name: string;
  readonly token: DesignToken;
};

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const packageRoot = path.join(repositoryRoot, "node_modules", "@putdotio", "design");
const inputPath = path.join(packageRoot, "dist", "tokens.flat.json");
const packagePath = path.join(packageRoot, "package.json");
const outputPath = path.join(
  repositoryRoot,
  "Packages",
  "PutioCore",
  "Sources",
  "PutioCore",
  "Generated",
  "PutioTheme+Generated.swift",
);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isStringOrNumber = (value: unknown): value is string | number =>
  typeof value === "string" || typeof value === "number";

export function parseTokens(value: unknown): readonly TokenEntry[] {
  if (!isRecord(value)) {
    throw new Error("design token artifact must be an object");
  }

  return Object.entries(value)
    .map(([name, candidate]): TokenEntry => {
      if (!isRecord(candidate)) {
        throw new Error(`token ${name} must be an object`);
      }
      const { cssName, type, mode, originalValue } = candidate;
      const tokenValue = candidate.value;
      if (typeof cssName !== "string" || !cssName.startsWith("--")) {
        throw new Error(`token ${name} has an invalid cssName`);
      }
      if (typeof type !== "string" || !tokenTypes.includes(type as TokenType)) {
        throw new Error(`token ${name} has an unsupported type`);
      }
      if (typeof mode !== "string" || !tokenModes.includes(mode as TokenMode)) {
        throw new Error(`token ${name} has an unsupported mode`);
      }
      if (!isStringOrNumber(tokenValue) || !isStringOrNumber(originalValue)) {
        throw new Error(`token ${name} has an invalid value`);
      }
      if (
        candidate.basis !== undefined &&
        candidate.basis !== "viewport-width" &&
        candidate.basis !== "viewport-height"
      ) {
        throw new Error(`token ${name} has an unsupported basis`);
      }

      return {
        name,
        token: {
          cssName,
          type: type as TokenType,
          mode: mode as TokenMode,
          value: tokenValue,
          originalValue,
          ...(typeof candidate.description === "string"
            ? { description: candidate.description }
            : {}),
          ...(candidate.basis === "viewport-width" || candidate.basis === "viewport-height"
            ? { basis: candidate.basis }
            : {}),
          ...(typeof candidate.deprecated === "boolean"
            ? { deprecated: candidate.deprecated }
            : {}),
        },
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

const swiftKeywords = new Set([
  "associatedtype",
  "class",
  "deinit",
  "enum",
  "extension",
  "fileprivate",
  "func",
  "import",
  "init",
  "inout",
  "internal",
  "let",
  "open",
  "operator",
  "private",
  "protocol",
  "public",
  "rethrows",
  "static",
  "struct",
  "subscript",
  "typealias",
  "var",
]);

const swiftIdentifier = (cssName: string): string => {
  const words = cssName.replace(/^--/, "").split(/[^A-Za-z0-9]+/).filter(Boolean);
  assert(words.length > 0, `cannot derive a Swift identifier from ${cssName}`);
  const identifier = words
    .map((word, index) =>
      index === 0
        ? word.toLowerCase()
        : `${word.slice(0, 1).toUpperCase()}${word.slice(1).toLowerCase()}`,
    )
    .join("");
  const safe = /^\d/.test(identifier) ? `token${identifier}` : identifier;
  return swiftKeywords.has(safe) ? `${safe}Value` : safe;
};

const swiftString = (value: string): string => JSON.stringify(value);
const decimal = (value: number): string => {
  const rounded = Math.round(value * 1_000_000) / 1_000_000;
  return Number.isInteger(rounded) ? `${rounded}.0` : `${rounded}`;
};

const hslPattern =
  /^hsla?\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)%\s*,\s*(\d+(?:\.\d+)?)%\s*(?:,\s*(\d+(?:\.\d+)?)\s*)?\)$/;

const hueToRgb = (p: number, q: number, rawT: number): number => {
  let t = rawT;
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  if (t < 1 / 6) return p + (q - p) * 6 * t;
  if (t < 1 / 2) return q;
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
  return p;
};

const swiftColorComponents = (value: string): readonly string[] => {
  const match = hslPattern.exec(value);
  if (!match) throw new Error(`unsupported color value: ${value}`);
  const hue = (((Number(match[1]) % 360) + 360) % 360) / 360;
  const saturation = Number(match[2]) / 100;
  const lightness = Number(match[3]) / 100;
  const opacity = match[4] === undefined ? 1 : Number(match[4]);
  let red = lightness;
  let green = lightness;
  let blue = lightness;
  if (saturation !== 0) {
    const q =
      lightness < 0.5
        ? lightness * (1 + saturation)
        : lightness + saturation - lightness * saturation;
    const p = 2 * lightness - q;
    red = hueToRgb(p, q, hue + 1 / 3);
    green = hueToRgb(p, q, hue);
    blue = hueToRgb(p, q, hue - 1 / 3);
  }
  return [decimal(red), decimal(green), decimal(blue), decimal(opacity)];
};

const swiftColor = (value: string): string => {
  const [red, green, blue, opacity] = swiftColorComponents(value);
  return `Color(.sRGB, red: ${red}, green: ${green}, blue: ${blue}, opacity: ${opacity})`;
};

const swiftMultilineColor = (value: string): string => {
  const [red, green, blue, opacity] = swiftColorComponents(value);
  return `Color(
          .sRGB,
          red: ${red},
          green: ${green},
          blue: ${blue},
          opacity: ${opacity}
        )`;
};

const dimensionPoints = (value: string | number): number => {
  if (typeof value === "number") return value;
  if (value === "0") return 0;
  const match = /^(-?\d+(?:\.\d+)?)(px|rem)$/.exec(value);
  if (!match) throw new Error(`unsupported dimension value: ${value}`);
  const amount = Number(match[1]);
  return match[2] === "rem" ? amount * 16 : amount;
};

const durationSeconds = (value: string | number): number => {
  if (typeof value === "number") return value;
  const match = /^(\d+(?:\.\d+)?)(ms|s)$/.exec(value);
  if (!match) throw new Error(`unsupported duration value: ${value}`);
  const amount = Number(match[1]);
  return match[2] === "ms" ? amount / 1_000 : amount;
};

const cubicBezier = (value: string | number): readonly number[] => {
  if (typeof value !== "string") throw new Error(`unsupported easing value: ${value}`);
  const match =
    /^cubic-bezier\(\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\)$/.exec(
      value,
    );
  if (!match) throw new Error(`unsupported easing value: ${value}`);
  return match.slice(1).map(Number);
};

const primaryFontFamily = (value: string | number): string => {
  if (typeof value !== "string") throw new Error(`unsupported font family: ${value}`);
  return value.split(",", 1)[0]?.trim().replace(/^"|"$/g, "") ?? value;
};

const fontWeight = (value: string | number): string => {
  const numeric = Number(value);
  const weights = new Map<number, string>([
    [400, ".regular"],
    [500, ".medium"],
    [600, ".semibold"],
    [700, ".bold"],
    [900, ".black"],
  ]);
  const result = weights.get(numeric);
  if (!result) throw new Error(`unsupported font weight: ${value}`);
  return result;
};

const requiredToken = (
  entries: readonly TokenEntry[],
  name: string,
  type?: TokenType,
): DesignToken => {
  const result = entries.find((entry) => entry.name === name)?.token;
  if (!result) throw new Error(`required token is missing: ${name}`);
  if (type && result.type !== type) {
    throw new Error(`required token ${name} must have type ${type}`);
  }
  return result;
};

const groupedColors = (
  entries: readonly TokenEntry[],
  mode: "product" | "tv",
): readonly { readonly identifier: string; readonly entries: readonly TokenEntry[] }[] => {
  const groups = new Map<string, TokenEntry[]>();
  for (const entry of entries) {
    if (entry.token.type !== "color") continue;
    if ((mode === "tv") !== (entry.token.mode === "tv")) continue;
    const group = groups.get(entry.token.cssName) ?? [];
    group.push(entry);
    groups.set(entry.token.cssName, group);
  }
  const result = [...groups.entries()]
    .map(([cssName, colorEntries]) => ({
      identifier: swiftIdentifier(cssName),
      entries: colorEntries.sort((left, right) => left.name.localeCompare(right.name)),
    }))
    .sort((left, right) => left.identifier.localeCompare(right.identifier));
  const identifiers = result.map((item) => item.identifier);
  assert.equal(new Set(identifiers).size, identifiers.length, "color identifiers must be unique");
  return result;
};

const renderProductColors = (entries: readonly TokenEntry[]): string =>
  groupedColors(entries, "product")
    .map(({ identifier, entries: variants }) => {
      const global = variants.find((entry) => entry.token.mode === "global");
      const light = variants.find((entry) => entry.token.mode === "light") ?? global ?? variants[0];
      const dark = variants.find((entry) => entry.token.mode === "dark") ?? global ?? variants[0];
      assert(light && dark, `color ${identifier} has no usable variants`);
      return `    public static let ${identifier} = PutioDynamicColor(\n      light: ${swiftColor(String(light.token.value))},\n      dark: ${swiftColor(String(dark.token.value))}\n    )`;
    })
    .join("\n\n");

const renderTVColors = (entries: readonly TokenEntry[]): string =>
  groupedColors(entries, "tv")
    .map(({ identifier, entries: variants }) => {
      assert.equal(variants.length, 1, `TV color ${identifier} must have one variant`);
      return `        public static let ${identifier} = ${swiftMultilineColor(String(variants[0]?.token.value))}`;
    })
    .join("\n");

const dimension = (entries: readonly TokenEntry[], name: string): string =>
  decimal(dimensionPoints(requiredToken(entries, name, "dimension").value));

const numberValue = (entries: readonly TokenEntry[], name: string): string => {
  const value = requiredToken(entries, name, "number").value;
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) throw new Error(`token ${name} must be numeric`);
  return decimal(numeric);
};

export function renderSwift(entries: readonly TokenEntry[], packageVersion: string): string {
  const familySans = primaryFontFamily(requiredToken(entries, "typography.fontFamily.sans").value);
  const familyDisplay = primaryFontFamily(
    requiredToken(entries, "typography.fontFamily.display").value,
  );
  const familyMono = primaryFontFamily(requiredToken(entries, "typography.fontFamily.mono").value);
  const easingOut = cubicBezier(requiredToken(entries, "motion.easing.out").value);
  const easingInOut = cubicBezier(requiredToken(entries, "motion.easing.inOut").value);

  return `// Do not edit directly. Generated by scripts/generate-design-tokens.ts.
// Source: @putdotio/design ${packageVersion} (${entries.length} tokens).

import SwiftUI

public struct PutioDynamicColor: Sendable {
  public let light: Color
  public let dark: Color

  public init(light: Color, dark: Color) {
    self.light = light
    self.dark = dark
  }

  public func resolve(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? dark : light
  }
}

public struct PutioFontRole: Sendable {
  public let family: String
  public let size: CGFloat
  public let weight: Font.Weight
  public let lineHeight: CGFloat
  public let textStyle: Font.TextStyle

  public init(
    family: String,
    size: CGFloat,
    weight: Font.Weight,
    lineHeight: CGFloat,
    textStyle: Font.TextStyle
  ) {
    self.family = family
    self.size = size
    self.weight = weight
    self.lineHeight = lineHeight
    self.textStyle = textStyle
  }

  public var font: Font {
    .custom(family, size: size, relativeTo: textStyle).weight(weight)
  }

  var baseLineSpacing: CGFloat {
    max(0, size * (lineHeight - 1))
  }
}

private struct PutioFontModifier: ViewModifier {
  let role: PutioFontRole
  @ScaledMetric private var lineSpacing: CGFloat

  init(role: PutioFontRole) {
    self.role = role
    _lineSpacing = ScaledMetric(
      wrappedValue: role.baseLineSpacing,
      relativeTo: role.textStyle
    )
  }

  func body(content: Content) -> some View {
    content
      .font(role.font)
      .lineSpacing(lineSpacing)
  }
}

extension View {
  public func putioFont(_ role: PutioFontRole) -> some View {
    modifier(PutioFontModifier(role: role))
  }
}

public struct PutioCubicBezier: Equatable, Sendable {
  public let x1: Double
  public let y1: Double
  public let x2: Double
  public let y2: Double

  public init(x1: Double, y1: Double, x2: Double, y2: Double) {
    self.x1 = x1
    self.y1 = y1
    self.x2 = x2
    self.y2 = y2
  }

  public func animation(duration: TimeInterval) -> Animation {
    .timingCurve(x1, y1, x2, y2, duration: duration)
  }
}

public enum PutioTheme {
  public static let sourcePackage = "@putdotio/design"
  public static let sourceVersion = ${swiftString(packageVersion)}
  public static let sourceTokenCount = ${entries.length}

  public enum Colors {
${renderProductColors(entries)}
  }

  public enum Typography {
    public static let familySans = ${swiftString(familySans)}
    public static let familyDisplay = ${swiftString(familyDisplay)}
    public static let familyMono = ${swiftString(familyMono)}

    public static let sizeXs: CGFloat = ${dimension(entries, "typography.fontSize.xs")}
    public static let sizeSm: CGFloat = ${dimension(entries, "typography.fontSize.sm")}
    public static let sizeBase: CGFloat = ${dimension(entries, "typography.fontSize.base")}
    public static let sizeMd: CGFloat = ${dimension(entries, "typography.fontSize.md")}
    public static let sizeLg: CGFloat = ${dimension(entries, "typography.fontSize.lg")}
    public static let sizeXl: CGFloat = ${dimension(entries, "typography.fontSize.xl")}
    public static let size2xl: CGFloat = ${dimension(entries, "typography.fontSize.2xl")}
    public static let size3xl: CGFloat = ${dimension(entries, "typography.fontSize.3xl")}
    public static let sizeDisplay: CGFloat = ${dimension(entries, "typography.fontSize.display")}

    public static let caption = PutioFontRole(
      family: familySans,
      size: sizeSm,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.regular").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
      textStyle: .caption
    )
    public static let body = PutioFontRole(
      family: familySans,
      size: sizeBase,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.regular").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
      textStyle: .body
    )
    public static let subheading = PutioFontRole(
      family: familySans,
      size: sizeMd,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.medium").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.snug")},
      textStyle: .subheadline
    )
    public static let heading = PutioFontRole(
      family: familySans,
      size: sizeLg,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.bold").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.tight")},
      textStyle: .headline
    )
    public static let title = PutioFontRole(
      family: familySans,
      size: sizeXl,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.bold").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.tight")},
      textStyle: .title
    )
    public static let display = PutioFontRole(
      family: familyDisplay,
      size: sizeDisplay,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.black").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.tight")},
      textStyle: .largeTitle
    )
    #if !os(tvOS)
      public static let mono = PutioFontRole(
        family: familyMono,
        size: sizeSm,
        weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.regular").value)},
        lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
        textStyle: .caption
      )
    #endif
  }

  public enum Spacing {
    public static let space0: CGFloat = ${dimension(entries, "spacing.0")}
    public static let space1: CGFloat = ${dimension(entries, "spacing.1")}
    public static let space2: CGFloat = ${dimension(entries, "spacing.2")}
    public static let space3: CGFloat = ${dimension(entries, "spacing.3")}
    public static let space4: CGFloat = ${dimension(entries, "spacing.4")}
    public static let space5: CGFloat = ${dimension(entries, "spacing.5")}
    public static let space6: CGFloat = ${dimension(entries, "spacing.6")}
    public static let space7: CGFloat = ${dimension(entries, "spacing.7")}
    public static let space8: CGFloat = ${dimension(entries, "spacing.8")}
  }

  public enum Radius {
    public static let small: CGFloat = ${dimension(entries, "radius.sm")}
    public static let standard: CGFloat = ${dimension(entries, "radius.default")}
    public static let medium: CGFloat = ${dimension(entries, "radius.md")}
    public static let large: CGFloat = ${dimension(entries, "radius.lg")}
    public static let pill: CGFloat = ${dimension(entries, "radius.pill")}
  }

  public enum Border {
    public static let width: CGFloat = ${dimension(entries, "border.width")}
  }

  public enum Motion {
    public static let durationFast: TimeInterval = ${decimal(durationSeconds(requiredToken(entries, "motion.duration.fast").value))}
    public static let durationBase: TimeInterval = ${decimal(durationSeconds(requiredToken(entries, "motion.duration.base").value))}
    public static let durationSlow: TimeInterval = ${decimal(durationSeconds(requiredToken(entries, "motion.duration.slow").value))}
    public static let easingOut = PutioCubicBezier(
      x1: ${decimal(easingOut[0] ?? 0)},
      y1: ${decimal(easingOut[1] ?? 0)},
      x2: ${decimal(easingOut[2] ?? 0)},
      y2: ${decimal(easingOut[3] ?? 0)}
    )
    public static let easingInOut = PutioCubicBezier(
      x1: ${decimal(easingInOut[0] ?? 0)},
      y1: ${decimal(easingInOut[1] ?? 0)},
      x2: ${decimal(easingInOut[2] ?? 0)},
      y2: ${decimal(easingInOut[3] ?? 0)}
    )
  }

  #if os(tvOS)
    public enum TV {
      public enum Colors {
${renderTVColors(entries)}
      }

      public enum Typography {
        public static let heading = PutioFontRole(
          family: PutioTheme.Typography.familySans,
          size: ${dimension(entries, "tv.text.heading")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.medium").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.tight")},
          textStyle: .title
        )
        public static let label = PutioFontRole(
          family: PutioTheme.Typography.familySans,
          size: ${dimension(entries, "tv.text.label")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.medium").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.snug")},
          textStyle: .headline
        )
        public static let body = PutioFontRole(
          family: PutioTheme.Typography.familySans,
          size: ${dimension(entries, "tv.text.body")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.regular").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
          textStyle: .body
        )
        public static let caption = PutioFontRole(
          family: PutioTheme.Typography.familySans,
          size: ${dimension(entries, "tv.text.caption")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.regular").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
          textStyle: .caption
        )
        public static let small = PutioFontRole(
          family: PutioTheme.Typography.familySans,
          size: ${dimension(entries, "tv.text.smol")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.regular").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
          textStyle: .caption2
        )
      }

      public enum Spacing {
        public static let xxs: CGFloat = ${dimension(entries, "tv.space.xxs")}
        public static let xs: CGFloat = ${dimension(entries, "tv.space.xs")}
        public static let small: CGFloat = ${dimension(entries, "tv.space.sm")}
        public static let medium: CGFloat = ${dimension(entries, "tv.space.md")}
        public static let large: CGFloat = ${dimension(entries, "tv.space.lg")}
        public static let xl: CGFloat = ${dimension(entries, "tv.space.xl")}
        public static let xxl: CGFloat = ${dimension(entries, "tv.space.xxl")}
      }

      public enum Overscan {
        public static let horizontal = ${numberValue(entries, "tv.overscan.x")}
        public static let vertical = ${numberValue(entries, "tv.overscan.y")}
      }

      public static let radius: CGFloat = ${dimension(entries, "tv.radius")}

      public enum ZIndex {
        public static let modal = ${numberValue(entries, "tv.z.modal")}
        public static let toast = ${numberValue(entries, "tv.z.toast")}
        public static let overlay = ${numberValue(entries, "tv.z.overlay")}
      }
    }
  #endif
}
`;
}

const readJSON = async (filePath: string): Promise<unknown> =>
  JSON.parse(await readFile(filePath, "utf8")) as unknown;

const run = async (): Promise<void> => {
  const [rawTokens, packageJSON] = await Promise.all([readJSON(inputPath), readJSON(packagePath)]);
  if (!isRecord(packageJSON) || typeof packageJSON.version !== "string") {
    throw new Error("@putdotio/design package.json has no version");
  }
  const generated = renderSwift(parseTokens(rawTokens), packageJSON.version);
  if (process.argv.includes("--check")) {
    const current = await readFile(outputPath, "utf8").catch(() => "");
    if (current !== generated) {
      throw new Error("generated Swift design tokens are stale; run pnpm tokens:generate");
    }
    return;
  }
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, generated);
};

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await run();
}
