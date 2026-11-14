import { execFileSync } from "node:child_process";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export type AndroidValue = string | { plurals: Record<string, string> };

export type AndroidSnapshot = {
  repository: string;
  commit: string;
  files: string[];
  strings: Record<string, AndroidValue>;
};

export type CatalogRecord =
  | { kind: "android"; key: string; differs?: string }
  | { kind: "ios-only"; reason: string };

type StringUnit = { state?: string; value: string };
type Localization = {
  stringUnit?: StringUnit;
  variations?: { plural?: Record<string, { stringUnit: StringUnit }> };
};
type CatalogEntry = {
  comment?: string;
  extractionState?: string;
  localizations?: Record<string, Localization>;
};
export type Catalog = {
  sourceLanguage: string;
  strings: Record<string, CatalogEntry>;
  version: string;
};

export type CatalogTarget = {
  name: string;
  catalog: string;
  sources: string[];
  bundle?: string;
};

export const targets: CatalogTarget[] = [
  {
    name: "iOS",
    catalog: "Apps/iOS/Sources/Localizable.xcstrings",
    sources: ["Apps/iOS/Sources"],
  },
  {
    name: "PutioCore",
    catalog: "Packages/PutioCore/Sources/PutioCore/Resources/Localizable.xcstrings",
    sources: ["Packages/PutioCore/Sources/PutioCore"],
    bundle: ".module",
  },
];

export const excludedPaths = [
  "Apps/iOS/Sources/Harness/",
  "Packages/PutioCore/Sources/PutioCore/Harness/",
  "Packages/PutioCore/Sources/PutioCore/Generated/",
  "Packages/PutioCore/Sources/PutioCore/Components/PutioComponentGallery.swift",
];

export const exemptLiterals: { file: string; text: string; reason: string }[] = [
  {
    file: "Packages/PutioCore/Sources/PutioCore/Session/SignedOutPresentation.swift",
    text: "Harness exercise complete",
    reason: "shown only to the harness after a scripted sign-out",
  },
];

export const androidSnapshotPath = "Config/AndroidStrings.json";

const androidStringFile =
  /^(?:mobile|core\/[^/]+|domain\/[^/]+)\/src\/main\/res\/values\/strings[^/]*\.xml$/;

const recordPattern = /^(?:android: ([a-z0-9_]+)(?: \| differs: (\S.*))?|ios-only: (\S.*))$/;

export const parseRecord = (comment: string | undefined): CatalogRecord | undefined => {
  const match = comment === undefined ? null : recordPattern.exec(comment);
  if (!match) return undefined;
  if (match[3] !== undefined) return { kind: "ios-only", reason: match[3] };
  return match[2] === undefined
    ? { kind: "android", key: match[1] }
    : { kind: "android", key: match[1], differs: match[2] };
};

const unescapeAndroid = (raw: string): string => {
  let text = raw.trim();
  const cdata = /^<!\[CDATA\[([\s\S]*)\]\]>$/.exec(text);
  if (cdata) text = cdata[1];
  else text = text.replace(/\s+/g, " ");
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) text = text.slice(1, -1);
  return text
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, code: string) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code: string) => String.fromCodePoint(parseInt(code, 16)))
    .replace(/&amp;/g, "&")
    .replace(/\\u([0-9a-fA-F]{4})/g, (_, code: string) => String.fromCharCode(parseInt(code, 16)))
    .replace(/\\(.)/g, (_, char: string) => (char === "n" ? "\n" : char === "t" ? "\t" : char));
};

export const parseAndroidStrings = (xml: string): Record<string, AndroidValue> => {
  const strings: Record<string, AndroidValue> = {};
  const body = xml.replace(/<!--[\s\S]*?-->/g, "");
  for (const match of body.matchAll(/<string\b([^>]*?)(?:\/>|>([\s\S]*?)<\/string>)/g)) {
    const name = /\bname="([^"]+)"/.exec(match[1])?.[1];
    if (name === undefined) throw new Error(`Android string without a name: ${match[0]}`);
    strings[name] = unescapeAndroid(match[2] ?? "");
  }
  for (const match of body.matchAll(/<plurals\b([^>]*)>([\s\S]*?)<\/plurals>/g)) {
    const name = /\bname="([^"]+)"/.exec(match[1])?.[1];
    if (name === undefined) throw new Error(`Android plurals without a name: ${match[0]}`);
    const plurals: Record<string, string> = {};
    for (const item of match[2].matchAll(/<item\b[^>]*\bquantity="([^"]+)"[^>]*>([\s\S]*?)<\/item>/g)) {
      plurals[item[1]] = unescapeAndroid(item[2]);
    }
    strings[name] = { plurals };
  }
  return strings;
};

export const snapshotAndroid = (checkout: string, ref: string): AndroidSnapshot => {
  const git = (...args: string[]): string =>
    execFileSync("git", ["-C", checkout, ...args], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  const commit = git("rev-parse", `${ref}^{commit}`).trim();
  const files = git("ls-tree", "-r", "--name-only", commit)
    .split("\n")
    .filter((path) => androidStringFile.test(path))
    .sort();
  const strings: Record<string, AndroidValue> = {};
  for (const file of files) {
    for (const [key, value] of Object.entries(parseAndroidStrings(git("show", `${commit}:${file}`)))) {
      if (key in strings) throw new Error(`duplicate Android string key ${key} in ${file}`);
      strings[key] = value;
    }
  }
  const sorted = Object.fromEntries(Object.entries(strings).sort(([a], [b]) => (a < b ? -1 : 1)));
  return { repository: "putdotio/putio-android", commit, files, strings: sorted };
};

export const normalizeFormat = (value: string): string => {
  let sequential = 0;
  return value.replace(
    /%(?:(\d+)\$)?(?:@|ll[du]|l[duf]|[dfsu]|%)/g,
    (token: string, position: string | undefined) => {
      if (token === "%%") return "%";
      sequential += 1;
      return `{${position ?? sequential}}`;
    },
  );
};

const PLACEHOLDER = "\u0000";

export const keyTemplate = (key: string): string =>
  key.replace(/%(?:\d+\$)?(?:@|ll[du]|l[duf]|[dfsu])/g, PLACEHOLDER).replace(/%%/g, "%");

export type SwiftLiteral = {
  file: string;
  line: number;
  template: string;
  callee?: string;
  calleePath?: string;
  label?: string;
  callLabels: string[];
  lineText: string;
  comparison: boolean;
  coalesced: boolean;
  concatenated: boolean;
  inDescription: boolean;
  start: number;
  end: number;
};

type Frame = {
  open: string;
  callee?: string;
  calleePath?: string;
  description?: boolean;
  labels: string[];
  currentLabel?: string;
};

const identifierChar = /[A-Za-z0-9_]/;

export const scanSwift = (source: string, file: string): SwiftLiteral[] => {
  const literals: SwiftLiteral[] = [];
  const lines = source.split("\n");
  let index = 0;
  let line = 1;

  const calleePathBefore = (offset: number): string => {
    let end = offset;
    while (end > 0 && /[ \t]/.test(source[end - 1])) end -= 1;
    let start = end;
    while (start > 0 && (identifierChar.test(source[start - 1]) || source[start - 1] === ".")) start -= 1;
    return source.slice(start, end);
  };

  const calleeName = (path: string): string | undefined => {
    const last = path.split(".").filter(Boolean).pop();
    if (last === undefined) return undefined;
    return path.includes(".") ? `.${last}` : last;
  };

  const run = (stack: Frame[], stopAtParen: boolean): void => {
    const top = (): Frame | undefined => stack[stack.length - 1];
    while (index < source.length) {
      const char = source[index];
      const next = source[index + 1];
      if (char === "\n") {
        line += 1;
        index += 1;
        continue;
      }
      if (char === "/" && next === "/") {
        while (index < source.length && source[index] !== "\n") index += 1;
        continue;
      }
      if (char === "/" && next === "*") {
        let depth = 1;
        index += 2;
        while (index < source.length && depth > 0) {
          if (source[index] === "/" && source[index + 1] === "*") {
            depth += 1;
            index += 2;
          } else if (source[index] === "*" && source[index + 1] === "/") {
            depth -= 1;
            index += 2;
          } else {
            if (source[index] === "\n") line += 1;
            index += 1;
          }
        }
        continue;
      }
      if (char === '"' || (char === "#" && /^#+"/.test(source.slice(index, index + 16)))) {
        readString(stack);
        continue;
      }
      if (char === "(" || char === "[" || char === "{") {
        const lineStart = source.lastIndexOf("\n", index) + 1;
        const calleePath = char === "(" ? calleePathBefore(index) : undefined;
        const frame: Frame = {
          open: char,
          callee: calleePath === undefined ? undefined : calleeName(calleePath),
          calleePath,
          description:
            char === "{" && /\b(?:var|func)\s+(?:debugDescription|description)\b/.test(source.slice(lineStart, index)),
          labels: [],
        };
        stack.push(frame);
        index += 1;
        continue;
      }
      if (char === ")" || char === "]" || char === "}") {
        stack.pop();
        index += 1;
        if (char === ")" && stopAtParen && stack.length === 0) return;
        continue;
      }
      const frame = top();
      if (frame && frame.open === "(") {
        if (char === ",") {
          frame.currentLabel = undefined;
          index += 1;
          continue;
        }
        if (identifierChar.test(char) && !identifierChar.test(source[index - 1] ?? "")) {
          let end = index;
          while (end < source.length && identifierChar.test(source[end])) end += 1;
          let after = end;
          while (after < source.length && /[ \t]/.test(source[after])) after += 1;
          if (source[after] === ":" && source[after + 1] !== ":") {
            let before = index - 1;
            while (before >= 0 && /[ \t\n]/.test(source[before])) before -= 1;
            if (source[before] === "(" || source[before] === ",") {
              const label = source.slice(index, end);
              frame.currentLabel = label;
              frame.labels.push(label);
            }
          }
          index = end;
          continue;
        }
      }
      index += 1;
    }
  };

  const readString = (stack: Frame[]): void => {
    let hashes = 0;
    const opening = index;
    while (source[index] === "#") {
      hashes += 1;
      index += 1;
    }
    const multiline = source.startsWith('"""', index);
    const quote = multiline ? '"""' : '"';
    index += quote.length;
    const terminator = quote + "#".repeat(hashes);
    const escape = "\\" + "#".repeat(hashes);
    let template = "";
    const startLine = line;
    const frame = stack[stack.length - 1];
    let before = opening - 1;
    while (before >= 0 && /[ \t\n]/.test(source[before])) before -= 1;
    const literal: SwiftLiteral = {
      file,
      line: startLine,
      template: "",
      callee: frame?.open === "(" ? frame.callee : undefined,
      calleePath: frame?.open === "(" ? frame.calleePath : undefined,
      label: frame?.open === "(" ? frame.currentLabel : undefined,
      callLabels: frame?.labels ?? [],
      lineText: lines[startLine - 1] ?? "",
      comparison: /[!=]=$/.test(source.slice(Math.max(0, before - 1), before + 1)),
      coalesced: source.slice(Math.max(0, before - 1), before + 1) === "??",
      concatenated: source[before] === "+",
      inDescription: stack.some((open) => open.description === true),
      start: opening,
      end: opening,
    };
    while (index < source.length) {
      if (source.startsWith(terminator, index)) {
        index += terminator.length;
        break;
      }
      if (source.startsWith(escape, index)) {
        const after = source[index + escape.length];
        if (after === "(") {
          index += escape.length;
          template += PLACEHOLDER;
          const interpolation: Frame[] = [];
          run(interpolation, true);
          continue;
        }
        index += escape.length + 1;
        const escapes: Record<string, string> = { n: "\n", t: "\t", r: "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\" };
        if (after === "u" && source[index] === "{") {
          const close = source.indexOf("}", index);
          template += String.fromCodePoint(parseInt(source.slice(index + 1, close), 16));
          index = close + 1;
        } else if (after === "\n") {
          line += 1;
        } else {
          template += escapes[after] ?? after;
        }
        continue;
      }
      if (source[index] === "\n") line += 1;
      template += source[index];
      index += 1;
    }
    if (multiline) template = template.replace(/^\n/, "").replace(/\n[ \t]*$/, "");
    literal.template = template;
    literal.end = index;
    let after = index;
    while (after < source.length && /[ \t\n]/.test(source[after])) after += 1;
    if (source[after] === "+" && source[after + 1] !== "=") literal.concatenated = true;
    literals.push(literal);
  };

  run([], false);
  return literals;
};

const localizingCallees = new Set([
  "Text",
  "Label",
  "Button",
  "Toggle",
  "Section",
  "NavigationLink",
  "TextField",
  "SecureField",
  "Picker",
  "Menu",
  "ProgressView",
  "LabeledContent",
  "ContentUnavailableView",
  "Link",
  "Tab",
  ".navigationTitle",
  ".alert",
  ".confirmationDialog",
  ".accessibilityLabel",
  ".accessibilityValue",
  ".accessibilityHint",
  ".accessibilityAction",
  ".searchable",
  ".help",
]);

const bundleCallees = new Set(["Text"]);

const ignoredLabels = new Set([
  "systemImage",
  "systemName",
  "image",
  "identifier",
  "retryIdentifier",
  "subsystem",
  "category",
  "forInfoDictionaryKey",
  "forKey",
  "subdirectory",
  "withExtension",
  "forResource",
  "ofType",
  "verbatimIdentifier",
]);

const ignoredCallees = new Set([
  "Image",
  "UIImage",
  "URL",
  "Logger",
  "print",
  "fatalError",
  "precondition",
  "preconditionFailure",
  "assert",
  "assertionFailure",
  ".accessibilityIdentifier",
  "Notification.Name",
  ".Name",
  "NSError",
  "UTType",
  ".debug",
  ".info",
  ".notice",
  ".trace",
  ".warning",
  ".fault",
  ".critical",
  ".log",
]);

const ignoredLine = /\b(?:logger|log)\.(?:debug|info|notice|error|warning|fault|trace|critical)\(|\bos_log\(/;

export const isProse = (template: string): boolean => {
  const text = template.replaceAll(PLACEHOLDER, " ").trim();
  if (!/\p{L}{2,}/u.test(text)) return false;
  if (template.includes(PLACEHOLDER) && /\s\p{L}{2,}|\p{L}{2,}\s/u.test(template.replaceAll(PLACEHOLDER, " "))) return true;
  if (/\s/.test(template.replaceAll(PLACEHOLDER, "").trim())) return true;
  return /^[A-Z][a-z’'-]+[.!?…]?$/.test(text);
};

const localizingPosition = (literal: SwiftLiteral): "string" | "swiftui" | undefined => {
  const callee = literal.callee;
  if (callee === "String" && literal.label === "localized") return "string";
  if (literal.coalesced || literal.concatenated) return undefined;
  if (callee === undefined || !localizingCallees.has(callee)) return undefined;
  const labelOk =
    literal.label === undefined ||
    (callee === ".searchable" && literal.label === "prompt") ||
    (callee === ".accessibilityAction" && literal.label === "named");
  return labelOk ? "swiftui" : undefined;
};

export const classify = (
  literal: SwiftLiteral,
  bundle: string | undefined,
): "ignored" | "localized" | "unlocalized" | "missing-bundle" => {
  if (ignoredLine.test(literal.lineText) || literal.comparison || literal.inDescription) return "ignored";
  if (literal.calleePath !== undefined && /(?:^|\.)logger\.\w+$/i.test(literal.calleePath)) return "ignored";
  if (literal.label !== undefined && ignoredLabels.has(literal.label)) return "ignored";
  if (literal.callee !== undefined && ignoredCallees.has(literal.callee)) return "ignored";
  if (/^\w+=/.test(literal.template)) return "ignored";
  const position = localizingPosition(literal);
  if (position === undefined) return isProse(literal.template) ? "unlocalized" : "ignored";
  if (!/\p{L}/u.test(literal.template)) return "ignored";
  if (bundle === undefined) return "localized";
  const bundled = literal.callLabels.includes("bundle");
  if (position === "string") return bundled ? "localized" : "missing-bundle";
  return literal.callee !== undefined && bundleCallees.has(literal.callee) && bundled ? "localized" : "missing-bundle";
};

const listSwiftFiles = async (root: string, directory: string): Promise<string[]> => {
  const entries = await readdir(join(root, directory), { withFileTypes: true, recursive: true });
  return entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".swift"))
    .map((entry) => relative(root, join(entry.parentPath, entry.name)).split(sep).join("/"))
    .filter((path) => !excludedPaths.some((excluded) => path.startsWith(excluded)))
    .sort();
};

const englishValues = (entry: CatalogEntry): { value?: string; plural?: Record<string, string> } => {
  const english = entry.localizations?.en;
  const plural = english?.variations?.plural;
  if (plural) {
    return {
      plural: Object.fromEntries(Object.entries(plural).map(([category, item]) => [category, item.stringUnit.value])),
    };
  }
  return { value: english?.stringUnit?.value };
};

const sameAsAndroid = (english: { value?: string; plural?: Record<string, string> }, android: AndroidValue): boolean => {
  if (typeof android === "string") {
    return english.value !== undefined && normalizeFormat(english.value) === normalizeFormat(android);
  }
  if (english.plural === undefined) return false;
  const categories = new Set([...Object.keys(english.plural), ...Object.keys(android.plurals)]);
  for (const category of categories) {
    const ios = english.plural[category];
    const droid = android.plurals[category];
    if (ios === undefined || droid === undefined) return false;
    if (normalizeFormat(ios) !== normalizeFormat(droid)) return false;
  }
  return true;
};

export type CheckResult = {
  problems: string[];
  iosOnly: { target: string; key: string; reason: string }[];
  counts: { keys: number; android: number; differs: number; iosOnly: number };
};

export const checkRepository = async (root: string): Promise<CheckResult> => {
  const problems: string[] = [];
  const iosOnly: CheckResult["iosOnly"] = [];
  const counts = { keys: 0, android: 0, differs: 0, iosOnly: 0 };
  const android = JSON.parse(await readFile(join(root, androidSnapshotPath), "utf8")) as AndroidSnapshot;

  for (const target of targets) {
    const catalog = JSON.parse(await readFile(join(root, target.catalog), "utf8")) as Catalog;
    if (catalog.sourceLanguage !== "en") problems.push(`${target.catalog}: sourceLanguage must be en`);
    const templates = new Map<string, string[]>();
    for (const [key, entry] of Object.entries(catalog.strings)) {
      counts.keys += 1;
      templates.set(keyTemplate(key), [...(templates.get(keyTemplate(key)) ?? []), key]);
      const english = englishValues(entry);
      if (english.value === undefined && english.plural === undefined) {
        problems.push(`${target.catalog}: "${key}" has no English value`);
      }
      if (english.value !== undefined && english.value !== key) {
        problems.push(`${target.catalog}: "${key}" English value differs from its key: "${english.value}"`);
      }
      if (english.plural !== undefined && english.plural.other !== key) {
        problems.push(`${target.catalog}: "${key}" plural "other" variation must equal its key`);
      }
      const record = parseRecord(entry.comment);
      if (record === undefined) {
        problems.push(
          `${target.catalog}: "${key}" needs a comment "android: <key>", "android: <key> | differs: <reason>", or "ios-only: <reason>"`,
        );
        continue;
      }
      if (record.kind === "ios-only") {
        counts.iosOnly += 1;
        iosOnly.push({ target: target.name, key, reason: record.reason });
        continue;
      }
      counts.android += 1;
      const value = android.strings[record.key];
      if (value === undefined) {
        problems.push(`${target.catalog}: "${key}" records Android key ${record.key}, which ${androidSnapshotPath} lacks`);
        continue;
      }
      const same = sameAsAndroid(english, value);
      if (record.differs !== undefined) {
        counts.differs += 1;
        if (same) problems.push(`${target.catalog}: "${key}" matches ${record.key}; drop "| differs"`);
      } else if (!same) {
        const shown = typeof value === "string" ? value : JSON.stringify(value.plurals);
        problems.push(
          `${target.catalog}: "${key}" differs from Android ${record.key} ("${shown}"); match it or add "| differs: <reason>"`,
        );
      }
    }

    const used = new Set<string>();
    for (const file of (await Promise.all(target.sources.map((dir) => listSwiftFiles(root, dir)))).flat()) {
      const source = await readFile(join(root, file), "utf8");
      if (/==\s*1\s*\?\s*(?:String\(localized:\s*)?"[a-z]/.test(source)) {
        problems.push(`${file}: pluralize with a catalog plural variation, not a count == 1 word ternary`);
      }
      for (const literal of scanSwift(source, file)) {
        if (literal.label === "comment" && (literal.callee === "String" || literal.callee === "Text")) {
          problems.push(`${file}:${literal.line}: move the comment into the catalog record`);
          continue;
        }
        const verdict = classify(literal, target.bundle);
        if (verdict === "ignored") continue;
        if (exemptLiterals.some((exempt) => exempt.file === file && exempt.text === literal.template)) continue;
        const where = `${file}:${literal.line}`;
        const shown = literal.template.replaceAll(PLACEHOLDER, "\\(…)");
        if (verdict === "unlocalized") {
          problems.push(`${where}: user-facing literal "${shown}" is not localized; wrap it in String(localized:) or a SwiftUI title`);
          continue;
        }
        if (verdict === "missing-bundle") {
          problems.push(`${where}: "${shown}" must look up in ${target.name} with bundle: ${target.bundle}`);
          continue;
        }
        const keys = templates.get(literal.template);
        if (keys === undefined) {
          problems.push(`${where}: "${shown}" is not in ${target.catalog}`);
          continue;
        }
        for (const key of keys) used.add(key);
      }
    }
    for (const key of Object.keys(catalog.strings)) {
      if (!used.has(key)) problems.push(`${target.catalog}: "${key}" is not used in ${target.sources.join(", ")}`);
    }
  }
  iosOnly.sort((a, b) => (a.key < b.key ? -1 : 1));
  return { problems, iosOnly, counts };
};

const main = async (): Promise<void> => {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const [command, ...rest] = process.argv.slice(2);
  if (command === "android") {
    const [checkout, ref = "origin/main"] = rest;
    if (checkout === undefined) throw new Error("usage: string-catalog.ts android <putio-android checkout> [ref]");
    const snapshot = snapshotAndroid(resolve(checkout), ref);
    await writeFile(join(root, androidSnapshotPath), `${JSON.stringify(snapshot, null, 2)}\n`);
    console.log(`${Object.keys(snapshot.strings).length} Android strings from ${snapshot.commit}`);
    return;
  }
  if (command !== "--check") throw new Error("usage: string-catalog.ts --check | android <checkout> [ref]");
  const result = await checkRepository(root);
  console.log(`ios-only strings (${result.iosOnly.length}):`);
  for (const entry of result.iosOnly) console.log(`  [${entry.target}] ${entry.key} — ${entry.reason}`);
  console.log(
    `${result.counts.keys} catalog keys: ${result.counts.android} mapped to Android (${result.counts.differs} intended differences), ${result.counts.iosOnly} ios-only`,
  );
  if (result.problems.length > 0) {
    console.error(result.problems.join("\n"));
    console.error(`string catalog check failed with ${result.problems.length} problems`);
    process.exitCode = 1;
  }
};

if (import.meta.main) await main();
