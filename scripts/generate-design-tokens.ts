import assert from "node:assert/strict";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
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
const inputPath = fileURLToPath(import.meta.resolve("@putdotio/design/tokens"));
const coveragePath = path.join(repositoryRoot, "scripts", "design-token-coverage.json");
const outputPath = path.join(
  repositoryRoot,
  "Packages",
  "PutioCore",
  "Sources",
  "PutioCore",
  "Generated",
  "PutioTheme+Generated.swift",
);
const assetCatalogPath = path.join(
  repositoryRoot,
  "Packages",
  "PutioCore",
  "Sources",
  "PutioCore",
  "Resources",
  "PutioColors.xcassets",
);

type CoverageManifest = {
  readonly sourcePackageVersion: string;
  readonly generated: readonly string[];
  readonly aliased: Readonly<Record<string, string>>;
  readonly excluded: Readonly<Record<string, readonly string[]>>;
};

type SemanticColorRole = {
  readonly assetName: string;
  readonly swiftName: string;
  readonly token: string;
};

export const semanticColorRoles = [
  {
    assetName: "PutioBackground",
    swiftName: "background",
    token: "surface.dark.appBg",
  },
  {
    assetName: "PutioSurface",
    swiftName: "surface",
    token: "component.alias.cardDark",
  },
  {
    assetName: "PutioTextPrimary",
    swiftName: "textPrimary",
    token: "component.alias.foregroundDark",
  },
  {
    assetName: "PutioTextSecondary",
    swiftName: "textSecondary",
    token: "component.alias.foregroundMutedDark",
  },
  {
    assetName: "PutioAccent",
    swiftName: "accent",
    token: "component.alias.primary",
  },
  {
    assetName: "PutioAccentForeground",
    swiftName: "accentForeground",
    token: "component.alias.primaryForeground",
  },
  {
    assetName: "PutioSuccess",
    swiftName: "success",
    token: "component.alias.successDark",
  },
  {
    assetName: "PutioSuccessForeground",
    swiftName: "successForeground",
    token: "component.alias.successForeground",
  },
  {
    assetName: "PutioDestructive",
    swiftName: "destructive",
    token: "component.alias.destructiveDark",
  },
  {
    assetName: "PutioDestructiveForeground",
    swiftName: "destructiveForeground",
    token: "component.alias.destructiveForeground",
  },
  {
    assetName: "PutioSeparator",
    swiftName: "separator",
    token: "color.neutral.dark.border",
  },
] as const satisfies readonly SemanticColorRole[];

export const generatedTokenNames = [...new Set([
  ...semanticColorRoles.map((role) => role.token),
  "border.width",
  "component.button.gap",
  "component.button.iconSize",
  "motion.duration.base",
  "motion.duration.fast",
  "motion.duration.slow",
  "motion.easing.inOut",
  "motion.easing.out",
  "radius.default",
  "radius.lg",
  "radius.md",
  "radius.pill",
  "radius.sm",
  ...Array.from({ length: 9 }, (_, index) => `spacing.${index}`),
  "typography.fontFamily.display",
  "typography.fontFamily.mono",
  "typography.fontFamily.sans",
  "typography.fontSize.2xl",
  "typography.fontSize.3xl",
  "typography.fontSize.base",
  "typography.fontSize.display",
  "typography.fontSize.lg",
  "typography.fontSize.md",
  "typography.fontSize.sm",
  "typography.fontSize.xl",
  "typography.fontSize.xs",
  "typography.fontWeight.black",
  "typography.fontWeight.bold",
  "typography.fontWeight.medium",
  "typography.fontWeight.regular",
  "typography.lineHeight.normal",
  "typography.lineHeight.snug",
  "typography.lineHeight.tight",
  "context.tv.text.primary",
  "context.tv.text.secondary",
  "context.tv.text.tertiary",
  "tv.fontWeight.medium",
  "tv.fontWeight.regular",
  "tv.overscan.x",
  "tv.overscan.y",
  "tv.radius",
  ...["body", "caption", "heading", "label", "smol"].map((name) => `tv.text.${name}`),
  ...["lg", "md", "sm", "xl", "xs", "xxl", "xxs"].map((name) => `tv.space.${name}`),
  "tv.z.modal",
  "tv.z.overlay",
  "tv.z.toast",
])] as readonly string[];

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

export function parseCoverageManifest(value: unknown): CoverageManifest {
  if (!isRecord(value) || typeof value.sourcePackageVersion !== "string") {
    throw new Error("token coverage manifest must declare sourcePackageVersion");
  }
  if (!Array.isArray(value.generated) || !value.generated.every((item) => typeof item === "string")) {
    throw new Error("token coverage manifest generated list must contain token names");
  }
  if (!isRecord(value.aliased)) {
    throw new Error("token coverage manifest aliased map must be an object");
  }
  const aliased = Object.fromEntries(
    Object.entries(value.aliased).map(([name, target]) => {
      if (typeof target !== "string") {
        throw new Error(`aliased token ${name} must name its generated target`);
      }
      return [name, target];
    }),
  );
  if (!isRecord(value.excluded)) {
    throw new Error("token coverage manifest excluded groups must be an object");
  }
  const excluded = Object.fromEntries(
    Object.entries(value.excluded).map(([reason, names]) => {
      if (!Array.isArray(names) || !names.every((item) => typeof item === "string")) {
        throw new Error(`excluded group ${reason} must contain token names`);
      }
      return [reason, names];
    }),
  );
  return {
    sourcePackageVersion: value.sourcePackageVersion,
    generated: value.generated,
    aliased,
    excluded,
  };
}

export function validateCoverage(
  entries: readonly TokenEntry[],
  manifest: CoverageManifest,
  packageVersion: string,
): void {
  if (manifest.sourcePackageVersion !== packageVersion) {
    throw new Error(
      `token coverage targets @putdotio/design ${manifest.sourcePackageVersion}, received ${packageVersion}`,
    );
  }
  const groups = [
    ["generated", manifest.generated] as const,
    ["aliased", Object.keys(manifest.aliased)] as const,
    ...Object.entries(manifest.excluded).map(
      ([reason, names]) => [`excluded:${reason}`, names] as const,
    ),
  ];
  const classifications = new Map<string, string>();
  for (const [classification, names] of groups) {
    for (const name of names) {
      const existing = classifications.get(name);
      if (existing) {
        throw new Error(`token ${name} is classified as both ${existing} and ${classification}`);
      }
      classifications.set(name, classification);
    }
  }
  const entryNames = new Set(entries.map((entry) => entry.name));
  const missing = [...entryNames].filter((name) => !classifications.has(name)).sort();
  const stale = [...classifications.keys()].filter((name) => !entryNames.has(name)).sort();
  if (missing.length > 0) {
    throw new Error(`unclassified design tokens: ${missing.join(", ")}`);
  }
  if (stale.length > 0) {
    throw new Error(`coverage references missing design tokens: ${stale.join(", ")}`);
  }
  const expectedGenerated = [...new Set(generatedTokenNames)].sort();
  const declaredGenerated = [...manifest.generated].sort();
  assert.deepEqual(
    declaredGenerated,
    expectedGenerated,
    "coverage generated list must match the native adapter inputs",
  );
  for (const [name, target] of Object.entries(manifest.aliased)) {
    const aliasEntry = entries.find((entry) => entry.name === name);
    const targetEntry = entries.find((entry) => entry.name === target);
    if (!targetEntry) {
      throw new Error(`aliased token ${name} targets missing token ${target}`);
    }
    if (!expectedGenerated.includes(target)) {
      throw new Error(`aliased token ${name} must target a generated token`);
    }
    if (
      !aliasEntry ||
      aliasEntry.token.type !== targetEntry.token.type ||
      aliasEntry.token.value !== targetEntry.token.value
    ) {
      throw new Error(`aliased token ${name} diverges from generated token ${target}`);
    }
  }
}

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

const swiftMultilineColor = (value: string, closingIndent = 8): string => {
  const [red, green, blue, opacity] = swiftColorComponents(value);
  const valueIndent = " ".repeat(closingIndent + 2);
  const endIndent = " ".repeat(closingIndent);
  return `Color(
${valueIndent}.sRGB,
${valueIndent}red: ${red},
${valueIndent}green: ${green},
${valueIndent}blue: ${blue},
${valueIndent}opacity: ${opacity}
${endIndent})`;
};

const assetColor = (value: string): Record<string, unknown> => {
  const [red, green, blue, alpha] = swiftColorComponents(value);
  return {
    "color-space": "srgb",
    components: { red, green, blue, alpha },
  };
};

const formattedJSON = (value: unknown): string => `${JSON.stringify(value, null, 2)}\n`;

const requiredDarkColorToken = (
  entries: readonly TokenEntry[],
  name: string,
): DesignToken => {
  const token = requiredToken(entries, name, "color");
  if (token.mode !== "dark" && token.mode !== "global") {
    throw new Error(`dark-only semantic color ${name} must use dark or global mode`);
  }
  return token;
};

export function renderAssetCatalog(
  entries: readonly TokenEntry[],
): Readonly<Record<string, string>> {
  const files: Record<string, string> = {
    "Contents.json": formattedJSON({ info: { author: "xcode", version: 1 } }),
  };
  for (const role of semanticColorRoles) {
    const token = requiredDarkColorToken(entries, role.token);
    files[`${role.assetName}.colorset/Contents.json`] = formattedJSON({
      colors: [{ color: assetColor(String(token.value)), idiom: "universal" }],
      info: { author: "xcode", version: 1 },
    });
  }
  return files;
}

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

const nativeFontName = (family: string, weight: string | number): string => {
  const numeric = Number(weight);
  if (family === "GT America") {
    const names = new Map<number, string>([
      [400, "GTAmerica-Rg"],
      [500, "GTAmerica-Md"],
      [600, "GTAmerica-Bd"],
      [700, "GTAmerica-Bd"],
      [900, "GTAmerica-Bl"],
    ]);
    const name = names.get(numeric);
    if (name) return name;
  }
  if (family === "Berkeley Mono" && numeric === 400) {
    return "BerkeleyMonoVariable-Regular";
  }
  throw new Error(`unsupported native font mapping: ${family} ${weight}`);
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

const renderProductColors = (entries: readonly TokenEntry[]): string => {
  const roles = semanticColorRoles
    .map((role) => {
      const token = requiredDarkColorToken(entries, role.token);
      return `    public static let ${role.swiftName} = semanticColor(
      named: ${swiftString(role.assetName)},
      fallback: ${swiftMultilineColor(String(token.value), 6)}
    )`;
    })
    .join("\n\n");
  return `${roles}

    private static func semanticColor(named: String, fallback: Color) -> Color {
      #if os(macOS)
        fallback
      #else
        Color(named, bundle: .module)
      #endif
    }`;
};

const tvColorRoles = [
  ["textPrimary", "context.tv.text.primary"],
  ["textSecondary", "context.tv.text.secondary"],
  ["textTertiary", "context.tv.text.tertiary"],
] as const;

const renderTVColors = (entries: readonly TokenEntry[]): string =>
  tvColorRoles
    .map(([swiftName, tokenName]) => {
      const token = requiredToken(entries, tokenName, "color");
      return `        public static let ${swiftName} = ${swiftMultilineColor(String(token.value))}`;
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

public struct PutioMetricRole: Sendable {
  public let value: CGFloat
  public let textStyle: Font.TextStyle

  public init(value: CGFloat, relativeTo textStyle: Font.TextStyle) {
    self.value = value
    self.textStyle = textStyle
  }
}

@propertyWrapper
public struct PutioScaledMetric: DynamicProperty {
  @ScaledMetric private var metric: CGFloat

  public init(_ role: PutioMetricRole) {
    _metric = ScaledMetric(wrappedValue: role.value, relativeTo: role.textStyle)
  }

  public var wrappedValue: CGFloat {
    metric
  }
}

public struct PutioIconRole: Sendable {
  public let size: PutioMetricRole
  public let weight: Font.Weight

  public init(size: PutioMetricRole, weight: Font.Weight) {
    self.size = size
    self.weight = weight
  }
}

public struct PutioFontRole: Sendable {
  public let family: String
  public let fontName: String
  public let size: CGFloat
  public let weight: Font.Weight
  public let lineHeight: CGFloat
  public let textStyle: Font.TextStyle

  public init(
    family: String,
    fontName: String,
    size: CGFloat,
    weight: Font.Weight,
    lineHeight: CGFloat,
    textStyle: Font.TextStyle
  ) {
    self.family = family
    self.fontName = fontName
    self.size = size
    self.weight = weight
    self.lineHeight = lineHeight
    self.textStyle = textStyle
  }

  public var font: Font {
    .custom(fontName, size: size, relativeTo: textStyle)
  }

  var baseLineSpacing: CGFloat {
    max(0, size * (lineHeight - 1))
  }
}

public struct PutioTabularFontRole: Sendable {
  public let base: PutioFontRole

  public init(base: PutioFontRole) {
    self.base = base
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
  @MainActor
  public func putioFont(_ role: PutioFontRole) -> some View {
    modifier(PutioFontModifier(role: role))
  }

  @MainActor
  public func putioFont(_ role: PutioTabularFontRole) -> some View {
    modifier(PutioFontModifier(role: role.base))
      .monospacedDigit()
  }
}

private struct PutioIconModifier: ViewModifier {
  let role: PutioIconRole
  @ScaledMetric private var size: CGFloat

  init(role: PutioIconRole) {
    self.role = role
    _size = ScaledMetric(
      wrappedValue: role.size.value,
      relativeTo: role.size.textStyle
    )
  }

  func body(content: Content) -> some View {
    content.font(.system(size: size, weight: role.weight))
  }
}

extension Image {
  @MainActor
  public func putioIcon(_ role: PutioIconRole) -> some View {
    modifier(PutioIconModifier(role: role))
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
      fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "typography.fontWeight.regular").value))},
      size: sizeSm,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.regular").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
      textStyle: .caption
    )
    public static let body = PutioFontRole(
      family: familySans,
      fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "typography.fontWeight.regular").value))},
      size: sizeBase,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.regular").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
      textStyle: .body
    )
    public static let subheading = PutioFontRole(
      family: familySans,
      fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "typography.fontWeight.medium").value))},
      size: sizeMd,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.medium").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.snug")},
      textStyle: .subheadline
    )
    public static let heading = PutioFontRole(
      family: familySans,
      fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "typography.fontWeight.bold").value))},
      size: sizeLg,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.bold").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.tight")},
      textStyle: .headline
    )
    public static let title = PutioFontRole(
      family: familySans,
      fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "typography.fontWeight.bold").value))},
      size: sizeXl,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.bold").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.tight")},
      textStyle: .title
    )
    public static let display = PutioFontRole(
      family: familyDisplay,
      fontName: ${swiftString(nativeFontName(familyDisplay, requiredToken(entries, "typography.fontWeight.black").value))},
      size: sizeDisplay,
      weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.black").value)},
      lineHeight: ${numberValue(entries, "typography.lineHeight.tight")},
      textStyle: .largeTitle
    )
    #if os(iOS) || os(watchOS)
      public static let mono = PutioFontRole(
        family: familyMono,
        fontName: ${swiftString(nativeFontName(familyMono, requiredToken(entries, "typography.fontWeight.regular").value))},
        size: sizeSm,
        weight: ${fontWeight(requiredToken(entries, "typography.fontWeight.regular").value)},
        lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
        textStyle: .caption
      )
      public static let numeric = PutioTabularFontRole(base: mono)
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

  public enum ScaledMetrics {
    public static let compactContentGap = PutioMetricRole(
      value: Spacing.space1,
      relativeTo: .caption
    )
    public static let contentGap = PutioMetricRole(
      value: Spacing.space3,
      relativeTo: .body
    )
    public static let buttonContentGap = PutioMetricRole(
      value: ${dimension(entries, "component.button.gap")},
      relativeTo: .caption
    )
    public static let buttonIconSize = PutioMetricRole(
      value: ${dimension(entries, "component.button.iconSize")},
      relativeTo: .caption
    )
  }

  public enum Icons {
    public static let button = PutioIconRole(
      size: ScaledMetrics.buttonIconSize,
      weight: .regular
    )
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
          fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "tv.fontWeight.medium").value))},
          size: ${dimension(entries, "tv.text.heading")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.medium").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.tight")},
          textStyle: .title
        )
        public static let label = PutioFontRole(
          family: PutioTheme.Typography.familySans,
          fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "tv.fontWeight.medium").value))},
          size: ${dimension(entries, "tv.text.label")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.medium").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.snug")},
          textStyle: .headline
        )
        public static let body = PutioFontRole(
          family: PutioTheme.Typography.familySans,
          fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "tv.fontWeight.regular").value))},
          size: ${dimension(entries, "tv.text.body")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.regular").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
          textStyle: .body
        )
        public static let caption = PutioFontRole(
          family: PutioTheme.Typography.familySans,
          fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "tv.fontWeight.regular").value))},
          size: ${dimension(entries, "tv.text.caption")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.regular").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
          textStyle: .caption
        )
        public static let small = PutioFontRole(
          family: PutioTheme.Typography.familySans,
          fontName: ${swiftString(nativeFontName(familySans, requiredToken(entries, "tv.fontWeight.regular").value))},
          size: ${dimension(entries, "tv.text.smol")},
          weight: ${fontWeight(requiredToken(entries, "tv.fontWeight.regular").value)},
          lineHeight: ${numberValue(entries, "typography.lineHeight.normal")},
          textStyle: .caption2
        )
        public static let numeric = PutioTabularFontRole(base: caption)
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

const findDesignPackage = async (): Promise<{ readonly version: string }> => {
  let directory = path.dirname(inputPath);
  while (directory !== path.dirname(directory)) {
    const candidate = path.join(directory, "package.json");
    const value = await readJSON(candidate).catch(() => undefined);
    if (isRecord(value) && value.name === "@putdotio/design") {
      if (typeof value.version !== "string") {
        throw new Error("@putdotio/design package.json has no version");
      }
      return { version: value.version };
    }
    directory = path.dirname(directory);
  }
  throw new Error("could not find @putdotio/design package.json from its public token export");
};

const readGeneratedTree = async (
  root: string,
  relativeDirectory = "",
): Promise<Readonly<Record<string, string>>> => {
  const directory = path.join(root, relativeDirectory);
  const entries = await readdir(directory, { withFileTypes: true }).catch(() => []);
  const files: Record<string, string> = {};
  for (const entry of entries) {
    const relativePath = path.join(relativeDirectory, entry.name);
    if (entry.isDirectory()) {
      Object.assign(files, await readGeneratedTree(root, relativePath));
    } else if (entry.isFile()) {
      files[relativePath] = await readFile(path.join(root, relativePath), "utf8");
    }
  }
  return files;
};

const assertGeneratedTree = (
  current: Readonly<Record<string, string>>,
  expected: Readonly<Record<string, string>>,
): void => {
  assert.deepEqual(Object.keys(current).sort(), Object.keys(expected).sort());
  for (const [relativePath, contents] of Object.entries(expected)) {
    assert.equal(current[relativePath], contents, `${relativePath} is stale`);
  }
};

const writeGeneratedTree = async (
  root: string,
  files: Readonly<Record<string, string>>,
): Promise<void> => {
  await rm(root, { force: true, recursive: true });
  for (const [relativePath, contents] of Object.entries(files)) {
    const filePath = path.join(root, relativePath);
    await mkdir(path.dirname(filePath), { recursive: true });
    await writeFile(filePath, contents);
  }
};

const run = async (): Promise<void> => {
  const [rawTokens, rawCoverage, packageMetadata] = await Promise.all([
    readJSON(inputPath),
    readJSON(coveragePath),
    findDesignPackage(),
  ]);
  const entries = parseTokens(rawTokens);
  const coverage = parseCoverageManifest(rawCoverage);
  validateCoverage(entries, coverage, packageMetadata.version);
  const generated = renderSwift(entries, packageMetadata.version);
  const generatedAssets = renderAssetCatalog(entries);
  if (process.argv.includes("--check")) {
    const [currentSwift, currentAssets] = await Promise.all([
      readFile(outputPath, "utf8").catch(() => ""),
      readGeneratedTree(assetCatalogPath),
    ]);
    try {
      assert.equal(currentSwift, generated, "generated Swift design tokens are stale");
      assertGeneratedTree(currentAssets, generatedAssets);
    } catch (error) {
      throw new Error("generated design tokens are stale; run pnpm tokens:generate", {
        cause: error,
      });
    }
    return;
  }
  await mkdir(path.dirname(outputPath), { recursive: true });
  await Promise.all([
    writeFile(outputPath, generated),
    writeGeneratedTree(assetCatalogPath, generatedAssets),
  ]);
};

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await run();
}
