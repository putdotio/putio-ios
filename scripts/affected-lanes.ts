import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const lanes = ["tooling", "store", "checks", "build", "ios", "tvos", "proof"] as const;
export type Lane = (typeof lanes)[number];

const apple: readonly Lane[] = ["checks", "build", "ios", "tvos", "proof"];
const everything: readonly Lane[] = lanes;

type Rule = Readonly<{ match: (path: string) => boolean; lanes: readonly Lane[] }>;

const exact =
  (...paths: string[]) =>
  (path: string): boolean =>
    paths.includes(path);
const under =
  (...directories: string[]) =>
  (path: string): boolean =>
    directories.some((directory) => path.startsWith(`${directory}/`));

const rules: readonly Rule[] = [
  { match: exact("scripts/affected-lanes.ts", ".github/workflows/ci-next.yml"), lanes: everything },
  { match: under(".github/actions"), lanes: everything },
  { match: (path) => path.endsWith(".md"), lanes: ["tooling"] },
  {
    match: (path) =>
      under("docs", ".agents", ".claude", ".github/ISSUE_TEMPLATE", "Tests/Formal")(path) ||
      exact(
        "LICENSE",
        "skills-lock.json",
        "renovate.json",
        ".worktreeinclude",
        ".periphery.yml",
        "scripts/bootstrap.sh",
        "scripts/dead-code.sh",
        "scripts/open.sh",
        "scripts/xcode-skills.sh",
      )(path),
    lanes: [],
  },
  { match: exact("scripts/install-asc.sh"), lanes: ["store"] },
  { match: (path) => /^scripts\/app-store[^/]*\.ts$/.test(path), lanes: ["tooling", "store"] },
  {
    match: exact(
      "package.json",
      "pnpm-lock.yaml",
      "pnpm-workspace.yaml",
      "scripts/sync-brand-fonts.ts",
      "Config/BrandFonts.json",
    ),
    lanes: everything,
  },
  {
    match: (path) =>
      exact("tsconfig.json", ".oxfmtrc.json", "Config/AndroidStrings.json")(path) ||
      /^scripts\/[^/]+\.ts$/.test(path),
    lanes: ["tooling"],
  },
  { match: exact("scripts/test-harness-interruption.sh"), lanes: ["tooling", "checks"] },
  { match: exact("scripts/doctor.sh", "scripts/test.sh"), lanes: ["checks"] },
  { match: exact("scripts/build.sh"), lanes: ["build"] },
  { match: exact("scripts/harness-ci.sh"), lanes: ["proof"] },
  {
    match: (path) =>
      under("Packages", "Tools/PutioHarness", "Tuist", "Apps/Shared")(path) ||
      exact(
        "Project.swift",
        "Tuist.swift",
        ".xcode-version",
        "scripts/verify.sh",
        "scripts/generate.sh",
        "scripts/harness.sh",
      )(path),
    lanes: apple,
  },
  { match: under("Apps/iOS", "Apps/watchOS"), lanes: ["checks", "build", "ios", "proof"] },
  { match: under("Apps/tvOS"), lanes: ["checks", "build", "tvos"] },
  { match: under("Tests/ComponentSnapshots/__Snapshots__/ios"), lanes: ["ios"] },
  { match: under("Tests/ComponentSnapshots/__Snapshots__/tvos"), lanes: ["tvos"] },
  { match: under("Tests/iOS", "Tests/iOSUITests"), lanes: ["checks", "ios", "proof"] },
  { match: under("Tests/tvOS", "Tests/tvOSUITests"), lanes: ["checks", "tvos"] },
  {
    match: under("Tests/ComponentSnapshots", "Tests/Shared"),
    lanes: ["checks", "ios", "tvos", "proof"],
  },
  { match: under("Tests/HarnessMedia"), lanes: ["build", "ios", "tvos", "proof"] },
];

export const ciTasks: ReadonlySet<string> = new Set(["verify", "harness-ci", "fonts-setup"]);

const sectionByLine = (text: string): string[] => {
  let section = "";
  return text.split("\n").map((line) => {
    const header = /^\s*\[([^\]]+)\]\s*(#.*)?$/.exec(line);
    if (header) section = (header[1] ?? "").trim();
    return section;
  });
};

const changedSections = (before: string, after: string): Set<string> => {
  const sections = (text: string): Map<string, string> => {
    const lines = text.split("\n");
    const owners = sectionByLine(text);
    const grouped = new Map<string, string>();
    lines.forEach((line, index) => {
      const owner = owners[index] ?? "";
      grouped.set(owner, `${grouped.get(owner) ?? ""}${line.trim()}\n`);
    });
    return grouped;
  };
  const old = sections(before);
  const next = sections(after);
  const changed = new Set<string>();
  for (const name of new Set([...old.keys(), ...next.keys()])) {
    if (old.get(name) !== next.get(name)) changed.add(name);
  }
  return changed;
};

export const miseLanes = (before: string, after: string): readonly Lane[] => {
  for (const section of changedSections(before, after)) {
    const task = /^tasks\.(.+)$/.exec(section)?.[1]?.replace(/^"(.*)"$/, "$1");
    if (task === undefined || ciTasks.has(task)) return everything;
  }
  return [];
};

export const lanesFor = (
  paths: readonly string[],
  mise?: Readonly<{ before: string; after: string }>,
): ReadonlySet<Lane> => {
  const selected = new Set<Lane>();
  for (const path of paths) {
    const matched =
      path === "mise.toml"
        ? mise === undefined
          ? everything
          : miseLanes(mise.before, mise.after)
        : (rules.find((rule) => rule.match(path))?.lanes ?? everything);
    for (const lane of matched) selected.add(lane);
  }
  return selected;
};

const git = (...args: string[]): string =>
  execFileSync("git", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

const fileAt = (revision: string, path: string): string => {
  try {
    return git("show", `${revision}:${path}`);
  } catch {
    return "";
  }
};

const changedSince = (base: string, head: string | undefined): readonly string[] => {
  const tracked = git("diff", "--name-only", "--no-renames", base, ...(head ? [head] : []));
  const untracked = head ? "" : git("ls-files", "--others", "--exclude-standard");
  return [...new Set(`${tracked}\n${untracked}`.split("\n").filter(Boolean))];
};

const parseArguments = (argv: readonly string[]) => {
  const options: { base?: string; head?: string; all: boolean; github: boolean } = {
    all: false,
    github: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--all") options.all = true;
    else if (argument === "--github-output") options.github = true;
    else if (argument === "--base") options.base = argv[++index];
    else if (argument === "--head") options.head = argv[++index];
    else throw new Error(`unknown argument: ${argument}`);
  }
  return options;
};

const main = (): void => {
  const options = parseArguments(process.argv.slice(2));
  let selected: ReadonlySet<Lane>;
  if (options.all) {
    selected = new Set(lanes);
  } else {
    const base = options.base ?? git("merge-base", "HEAD", "origin/next").trim();
    const paths = changedSince(base, options.head);
    const after = options.head
      ? fileAt(options.head, "mise.toml")
      : readFileSync("mise.toml", "utf8");
    selected = lanesFor(paths, { before: fileAt(base, "mise.toml"), after });
    process.stderr.write(
      `affected-lanes: ${paths.length} changed paths since ${base.slice(0, 12)}\n`,
    );
  }
  if (options.github) {
    const output = process.env.GITHUB_OUTPUT;
    if (!output) throw new Error("--github-output needs GITHUB_OUTPUT");
    appendFileSync(output, lanes.map((lane) => `${lane}=${selected.has(lane)}\n`).join(""));
  }
  process.stdout.write(`${lanes.filter((lane) => selected.has(lane)).join(" ")}\n`);
};

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
