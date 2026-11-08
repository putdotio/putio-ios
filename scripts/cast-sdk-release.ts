#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

type Version = readonly [number, number, number];
type Release = Readonly<{ version: string; url: string; checksum: string }>;
type AlertIssue = Readonly<{ title: string; body: string }>;

const UPSTREAM = "googlecast/google-cast-ios-sdk";
const UPSTREAM_TARGET = "GoogleCastDynamicBinary";
const ISSUE_AUTHOR = "github-actions[bot]";
const ISSUE_MARKER = "<!-- cast-sdk-release -->";
const PACKAGE_PATH = "ThirdParty/GoogleCast/Package.swift";
const CAST_PACKAGE = join(dirname(fileURLToPath(import.meta.url)), "..", PACKAGE_PATH);

const fail = (message: string): never => {
  process.stderr.write(`cast-sdk-release: ${message}\n`);
  process.exit(1);
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const parseVersion = (text: string): Version | undefined => {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(text);
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : undefined;
};

const compareVersions = (a: Version, b: Version): number => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];

const versionOrFail = (text: string, context: string): Version =>
  parseVersion(text) ?? fail(`${context} is not a MAJOR.MINOR.PATCH version: ${JSON.stringify(text)}`);

export const latestVersion = (tags: readonly string[]): string | undefined => {
  let best: { name: string; version: Version } | undefined;
  for (const name of tags) {
    const version = parseVersion(name);
    if (version && (!best || compareVersions(version, best.version) > 0)) best = { name, version };
  }
  return best?.name;
};

export const pinnedVersion = (packageSwift: string): string | undefined =>
  /url: "https:\/\/dl\.google\.com\/[^"]*\/GoogleCastSDK-ios-(\d+\.\d+\.\d+)_dynamic\.zip"/.exec(packageSwift)?.[1];

export const dynamicBinary = (packageSwift: string): Omit<Release, "version"> | undefined => {
  const target = new RegExp(`\\.binaryTarget\\(\\s*name:\\s*"${UPSTREAM_TARGET}",\\s*url:\\s*"([^"]+)",\\s*checksum:\\s*"([^"]+)"`).exec(packageSwift);
  const [, url, checksum] = target ?? [];
  if (!url || !checksum || !/^[0-9a-f]{64}$/.test(checksum)) return undefined;
  const parsed = URL.parse(url);
  if (parsed?.protocol !== "https:" || parsed.hostname !== "dl.google.com" || !parsed.pathname.endsWith(".zip")) return undefined;
  return { url, checksum };
};

export const alertIssue = (release: Release, pinned: string, repository: string): AlertIssue => ({
  title: `Update the Google Cast iOS SDK to ${release.version}`,
  body: [
    ISSUE_MARKER,
    `Google Cast iOS SDK [${release.version}](https://github.com/${UPSTREAM}/tree/${release.version}) is out. \`main\` pins ${pinned}.`,
    "",
    `Point the binary target in [\`${PACKAGE_PATH}\`](https://github.com/${repository}/blob/main/${PACKAGE_PATH}) at the dynamic zip from [its upstream \`Package.swift\`](https://github.com/${UPSTREAM}/blob/${release.version}/Package.swift):`,
    "",
    "```swift",
    `url: "${release.url}",`,
    `checksum: "${release.checksum}"`,
    "```",
    "",
    "Then run `mise run acknowledgements-sync` and `mise run verify`.",
    "",
  ].join("\n"),
});

const gh = (args: readonly string[], input?: string): string => {
  const result = spawnSync("gh", args, { encoding: "utf8", input, maxBuffer: 16 * 1024 * 1024 });
  if (result.error) throw new Error(`gh ${args.join(" ")} did not run`, { cause: result.error });
  if (result.status !== 0) throw new Error(`gh ${args.join(" ")} exited ${result.status}: ${result.stderr.trim()}`);
  return result.stdout;
};

const pages = (json: string, context: string): unknown[] => {
  const parsed: unknown = JSON.parse(json);
  if (!Array.isArray(parsed) || !parsed.every(Array.isArray)) return fail(`${context} is not a list of pages`);
  return parsed.flat();
};

const tagNames = (json: string): string[] =>
  pages(json, "the upstream tag list").map((tag) =>
    isRecord(tag) && typeof tag.name === "string" ? tag.name : fail("an upstream tag has no name"),
  );

const openAlertNumber = (json: string): number | undefined => {
  const issue = pages(json, "the open issue list").find(
    (item) =>
      isRecord(item) &&
      !("pull_request" in item) &&
      isRecord(item.user) &&
      item.user.login === ISSUE_AUTHOR &&
      typeof item.body === "string" &&
      item.body.includes(ISSUE_MARKER),
  );
  if (issue === undefined) return undefined;
  return isRecord(issue) && Number.isSafeInteger(issue.number) ? Number(issue.number) : fail("the open alert issue has no number");
};

const issueUrl = (json: string): string => {
  const parsed: unknown = JSON.parse(json);
  return isRecord(parsed) && typeof parsed.html_url === "string" ? parsed.html_url : fail("GitHub returned no issue URL");
};

const main = (): void => {
  const repository = process.env.GITHUB_REPOSITORY || fail("GITHUB_REPOSITORY is not set");
  const override = process.env.PINNED_VERSION ?? "";
  const pinned = override || (pinnedVersion(readFileSync(CAST_PACKAGE, "utf8")) ?? fail(`no dynamic Google Cast SDK URL in ${PACKAGE_PATH}`));
  const pinnedParsed = versionOrFail(pinned, override ? "PINNED_VERSION" : `the version pinned in ${PACKAGE_PATH}`);

  const latest = latestVersion(tagNames(gh(["api", "--paginate", "--slurp", `repos/${UPSTREAM}/tags?per_page=100`])));
  if (!latest) return fail(`${UPSTREAM} has no MAJOR.MINOR.PATCH tag`);
  if (compareVersions(versionOrFail(latest, "the latest tag"), pinnedParsed) <= 0) {
    process.stdout.write(`Google Cast iOS SDK ${pinned} is current; the latest upstream tag is ${latest}.\n`);
    return;
  }

  const upstreamPackage = gh(["api", "-H", "Accept: application/vnd.github.raw", `repos/${UPSTREAM}/contents/Package.swift?ref=${latest}`]);
  const binary = dynamicBinary(upstreamPackage) ?? fail(`${UPSTREAM} ${latest} Package.swift has no ${UPSTREAM_TARGET} with a dl.google.com zip and a sha256 checksum`);
  const issue = JSON.stringify(alertIssue({ version: latest, ...binary }, pinned, repository));

  const existing = openAlertNumber(
    gh(["api", "--paginate", "--slurp", `repos/${repository}/issues?state=open&creator=${encodeURIComponent(ISSUE_AUTHOR)}&per_page=100`]),
  );
  if (existing === undefined) {
    const url = issueUrl(gh(["api", "--method", "POST", `repos/${repository}/issues`, "--input", "-"], issue));
    process.stdout.write(`Opened ${url} for Google Cast iOS SDK ${latest}.\n`);
  } else {
    const url = issueUrl(gh(["api", "--method", "PATCH", `repos/${repository}/issues/${existing}`, "--input", "-"], issue));
    process.stdout.write(`Updated ${url} for Google Cast iOS SDK ${latest}.\n`);
  }
};

if (import.meta.main) main();
