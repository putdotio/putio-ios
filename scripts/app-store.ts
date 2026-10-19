// Store as code: reads Config/AppStore.json and metadata/, then drives the
// pinned asc CLI to check, plan, apply, validate, and upload screenshots for
// one App Store version. Every asc call runs with telemetry disabled.
//
//   node scripts/app-store.ts check [--version 3.0.0]
//   node scripts/app-store.ts plan --version 3.0.0 [--export build/app-store]
//   node scripts/app-store.ts apply --version 3.0.0 --confirm
//   node scripts/app-store.ts validate --version 3.0.0 [--strict]
//   node scripts/app-store.ts screenshots --version 3.0.0 (--dry-run | --confirm)
import { execFile } from "node:child_process";
import { appendFile, copyFile, mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

export type Platform = "IOS" | "MAC_OS" | "TV_OS" | "VISION_OS";
export type ReleaseType = "MANUAL" | "AFTER_APPROVAL";
export type AgeRatingValue = boolean | string;

export type ScreenshotSet = Readonly<{ deviceType: string; prefix: string }>;

export type AppStoreConfig = Readonly<{
  appId: string;
  platform: Platform;
  primaryLocale: string;
  metadataDir: string;
  version: Readonly<{ releaseType: ReleaseType; phasedRelease: boolean }>;
  ageRating: Readonly<Record<string, AgeRatingValue>>;
  screenshots: Readonly<{ dir: string; sets: readonly ScreenshotSet[] }>;
}>;

// asc 5.15.0 accepts both Apple vocabularies for frequency answers.
const LEVELS = ["NONE", "INFREQUENT_OR_MILD", "FREQUENT_OR_INTENSE", "INFREQUENT", "FREQUENT"] as const;

// API attribute -> asc age-rating edit flag. asc names several flags
// differently from the attribute they set.
const AGE_RATING_FIELDS: Readonly<Record<string, Readonly<{ flag: string; values: "boolean" | readonly string[] }>>> = {
  advertising: { flag: "advertising", values: "boolean" },
  ageAssurance: { flag: "age-assurance", values: "boolean" },
  gambling: { flag: "gambling", values: "boolean" },
  healthOrWellnessTopics: { flag: "health-or-wellness-topics", values: "boolean" },
  lootBox: { flag: "loot-box", values: "boolean" },
  messagingAndChat: { flag: "messaging-and-chat", values: "boolean" },
  parentalControls: { flag: "parental-controls", values: "boolean" },
  socialMedia: { flag: "social-media", values: "boolean" },
  socialMediaAgeRestricted: { flag: "social-media-age-restricted", values: "boolean" },
  unrestrictedWebAccess: { flag: "unrestricted-web-access", values: "boolean" },
  userGeneratedContent: { flag: "user-generated-content", values: "boolean" },
  alcoholTobaccoOrDrugUseOrReferences: { flag: "alcohol-tobacco-drug-use", values: LEVELS },
  contests: { flag: "contests", values: LEVELS },
  gamblingSimulated: { flag: "gambling-simulated", values: LEVELS },
  gunsOrOtherWeapons: { flag: "guns-or-other-weapons", values: LEVELS },
  horrorOrFearThemes: { flag: "horror-fear", values: LEVELS },
  matureOrSuggestiveThemes: { flag: "mature-suggestive", values: LEVELS },
  medicalOrTreatmentInformation: { flag: "medical-treatment", values: LEVELS },
  profanityOrCrudeHumor: { flag: "profanity-humor", values: LEVELS },
  sexualContentGraphicAndNudity: { flag: "sexual-content-graphic-nudity", values: LEVELS },
  sexualContentOrNudity: { flag: "sexual-content-nudity", values: LEVELS },
  violenceCartoonOrFantasy: { flag: "violence-cartoon", values: LEVELS },
  violenceRealistic: { flag: "violence-realistic", values: LEVELS },
  violenceRealisticProlongedGraphicOrSadistic: { flag: "violence-realistic-graphic", values: LEVELS },
};

// asc 5.15.0's App Store localization catalog
// (internal/cli/shared/app_store_localizations.go). Bump with the pin.
const APP_STORE_LOCALES = [
  "ar-SA", "bn-BD", "ca", "cs", "da", "de-DE", "el", "en-AU", "en-CA", "en-GB", "en-US", "es-ES", "es-MX",
  "fi", "fr-CA", "fr-FR", "gu-IN", "he", "hi", "hr", "hu", "id", "it", "ja", "kn-IN", "ko", "ml-IN", "mr-IN",
  "ms", "nl-NL", "no", "or-IN", "pa-IN", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sl-SI", "sv", "ta-IN",
  "te-IN", "th", "tr", "uk", "ur-PK", "vi", "zh-Hans", "zh-Hant",
];

// Apple caps one locale and display type at ten screenshots.
const SCREENSHOT_LIMIT = 10;
const SCREENSHOT_EXTENSIONS = /\.(png|jpe?g)$/i;
const VERSION_PATTERN = /^\d+\.\d+\.\d+$/;

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonObject = { [key: string]: Json };

const isObject = (value: unknown): value is JsonObject =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const expectKeys = (value: JsonObject, allowed: readonly string[], context: string): void => {
  const unknown = Object.keys(value).filter((key) => !allowed.includes(key));
  if (unknown.length > 0) throw new Error(`${context}: unknown key ${unknown.join(", ")}`);
};

const stringAt = (value: JsonObject, key: string, context: string): string => {
  const field = value[key];
  if (typeof field !== "string" || field.trim() === "") throw new Error(`${context}.${key} must be a non-empty string`);
  return field;
};

const objectAt = (value: JsonObject, key: string, context: string): JsonObject => {
  const field = value[key];
  if (!isObject(field)) throw new Error(`${context}.${key} must be an object`);
  return field;
};

export const appStoreLocale = (locale: string, context: string): string => {
  if (!APP_STORE_LOCALES.includes(locale)) throw new Error(`${context}: ${locale} is not an App Store locale, such as en-US or pt-BR`);
  return locale;
};

export const parseConfig = (raw: unknown): AppStoreConfig => {
  const context = "Config/AppStore.json";
  if (!isObject(raw)) throw new Error(`${context} must be an object`);
  expectKeys(raw, ["$comment", "appId", "platform", "primaryLocale", "metadataDir", "version", "ageRating", "screenshots"], context);

  const appId = stringAt(raw, "appId", context);
  if (!/^\d+$/.test(appId)) throw new Error(`${context}.appId must be the numeric App Store Connect app ID`);
  const platform = stringAt(raw, "platform", context);
  if (!["IOS", "MAC_OS", "TV_OS", "VISION_OS"].includes(platform)) throw new Error(`${context}.platform is not an App Store platform`);

  const version = objectAt(raw, "version", context);
  expectKeys(version, ["releaseType", "phasedRelease"], `${context}.version`);
  const releaseType = stringAt(version, "releaseType", `${context}.version`);
  // SCHEDULED needs a date that belongs to one release, not to the config.
  if (releaseType !== "MANUAL" && releaseType !== "AFTER_APPROVAL") {
    throw new Error(`${context}.version.releaseType must be MANUAL or AFTER_APPROVAL`);
  }
  if (typeof version.phasedRelease !== "boolean") throw new Error(`${context}.version.phasedRelease must be a boolean`);

  const ageRating = objectAt(raw, "ageRating", context);
  for (const [key, value] of Object.entries(ageRating)) {
    const field = AGE_RATING_FIELDS[key];
    if (!field) throw new Error(`${context}.ageRating.${key} is not a supported age-rating attribute`);
    const valid = field.values === "boolean" ? typeof value === "boolean" : typeof value === "string" && field.values.includes(value);
    if (!valid) {
      const expected = field.values === "boolean" ? "a boolean" : `one of ${field.values.join(", ")}`;
      throw new Error(`${context}.ageRating.${key} must be ${expected}`);
    }
  }

  const screenshots = objectAt(raw, "screenshots", context);
  expectKeys(screenshots, ["dir", "sets"], `${context}.screenshots`);
  const rawSets = screenshots.sets;
  if (!Array.isArray(rawSets) || rawSets.length === 0) throw new Error(`${context}.screenshots.sets must be a non-empty array`);
  const sets = rawSets.map((set, index): ScreenshotSet => {
    const setContext = `${context}.screenshots.sets[${index}]`;
    if (!isObject(set)) throw new Error(`${setContext} must be an object`);
    expectKeys(set, ["deviceType", "prefix"], setContext);
    return { deviceType: stringAt(set, "deviceType", setContext), prefix: stringAt(set, "prefix", setContext) };
  });
  for (const set of sets) {
    const overlapping = sets.find((other) => other !== set && other.prefix.startsWith(set.prefix));
    if (overlapping) throw new Error(`${context}.screenshots: prefix ${set.prefix} also matches ${overlapping.prefix}`);
  }

  return {
    appId,
    platform: platform as Platform,
    primaryLocale: appStoreLocale(stringAt(raw, "primaryLocale", context), `${context}.primaryLocale`),
    metadataDir: stringAt(raw, "metadataDir", context),
    version: { releaseType, phasedRelease: version.phasedRelease },
    ageRating: ageRating as Record<string, AgeRatingValue>,
    screenshots: { dir: stringAt(screenshots, "dir", `${context}.screenshots`), sets },
  };
};

export type AgeRatingChange = Readonly<{ field: string; desired: AgeRatingValue; remote: Json | undefined }>;

export const ageRatingChanges = (
  desired: Readonly<Record<string, AgeRatingValue>>,
  remote: Readonly<Record<string, Json | undefined>>,
): AgeRatingChange[] =>
  Object.entries(desired)
    .filter(([field, value]) => remote[field] !== value)
    .map(([field, value]) => ({ field, desired: value, remote: remote[field] }));

export const ageRatingFlags = (changes: readonly AgeRatingChange[]): string[] =>
  changes.flatMap(({ field, desired }) => {
    const definition = AGE_RATING_FIELDS[field];
    if (!definition) throw new Error(`unsupported age-rating attribute ${field}`);
    return [`--${definition.flag}`, String(desired)];
  });

export type RemoteVersion = Readonly<{
  id: string;
  state: string;
  releaseType: string | undefined;
  phasedRelease: Readonly<{ id: string; state: string }> | undefined;
}>;

export type VersionAction =
  | Readonly<{ kind: "create"; releaseType: ReleaseType }>
  | Readonly<{ kind: "set-release-type"; from: string | undefined; to: ReleaseType }>
  | Readonly<{ kind: "create-phased-release" }>
  | Readonly<{ kind: "delete-phased-release"; id: string }>;

export const versionActions = (desired: AppStoreConfig["version"], remote: RemoteVersion | undefined): VersionAction[] => {
  if (!remote) {
    const created: VersionAction[] = [{ kind: "create", releaseType: desired.releaseType }];
    return desired.phasedRelease ? [...created, { kind: "create-phased-release" }] : created;
  }
  const actions: VersionAction[] = [];
  if (remote.releaseType !== desired.releaseType) {
    actions.push({ kind: "set-release-type", from: remote.releaseType, to: desired.releaseType });
  }
  if (desired.phasedRelease && !remote.phasedRelease) actions.push({ kind: "create-phased-release" });
  if (!desired.phasedRelease && remote.phasedRelease) {
    // Apple only deletes a phased release that has not started.
    if (remote.phasedRelease.state !== "INACTIVE") {
      throw new Error(`phased release is ${remote.phasedRelease.state}; turn it off in a later version instead`);
    }
    actions.push({ kind: "delete-phased-release", id: remote.phasedRelease.id });
  }
  return actions;
};

// asc 5.15.0's editable version states
// (internal/cli/shared/app_store_version_diagnostics.go). Apple rejects
// metadata, screenshot, and age-rating edits on a version in any other state.
const EDITABLE_STATES = ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"];

export const requireEditable = (version: string, remote: RemoteVersion | undefined): void => {
  if (remote && !EDITABLE_STATES.includes(remote.state)) {
    throw new Error(`version ${version} is ${remote.state}; App Store Connect only edits a version in ${EDITABLE_STATES.join(", ")}`);
  }
};

export const describeVersionAction = (action: VersionAction): string => {
  switch (action.kind) {
    case "create":
      return `create the version with release type ${action.releaseType}`;
    case "set-release-type":
      return `release type ${action.from ?? "unset"} → ${action.to}`;
    case "create-phased-release":
      return "turn on phased release";
    case "delete-phased-release":
      return "turn off phased release";
  }
};

// Assigns every image under one locale to exactly one configured set, and
// every configured set at least one image.
export const assignScreenshots = (
  sets: readonly ScreenshotSet[],
  files: readonly string[],
): Map<ScreenshotSet, string[]> => {
  const assigned = new Map<ScreenshotSet, string[]>(sets.map((set) => [set, []]));
  const unassigned: string[] = [];
  for (const file of [...files].sort()) {
    if (!SCREENSHOT_EXTENSIONS.test(file)) continue;
    const set = sets.find((candidate) => file.startsWith(candidate.prefix));
    if (set) assigned.get(set)?.push(file);
    else unassigned.push(file);
  }
  if (unassigned.length > 0) throw new Error(`screenshots match no configured set: ${unassigned.join(", ")}`);
  for (const [set, images] of assigned) {
    // An empty set would never be replaced, leaving stale screenshots live.
    if (images.length === 0) throw new Error(`${set.deviceType} has no screenshots starting with ${set.prefix}`);
    if (images.length > SCREENSHOT_LIMIT) {
      throw new Error(`${set.deviceType} has ${images.length} screenshots; App Store Connect keeps ${SCREENSHOT_LIMIT}`);
    }
  }
  return assigned;
};

export const parseRemoteVersion = (listing: unknown): RemoteVersion | undefined => {
  if (!isObject(listing) || !Array.isArray(listing.data)) throw new Error("asc versions list returned no data array");
  if (listing.data.length > 1) throw new Error("asc versions list matched more than one version");
  const version = listing.data[0];
  if (version === undefined) return undefined;
  if (!isObject(version) || typeof version.id !== "string" || !isObject(version.attributes)) {
    throw new Error("asc versions list returned a malformed version");
  }
  const attributes = version.attributes;
  const state = attributes.appVersionState ?? attributes.appStoreState;
  return {
    id: version.id,
    state: typeof state === "string" ? state : "UNKNOWN",
    releaseType: typeof attributes.releaseType === "string" ? attributes.releaseType : undefined,
    phasedRelease: parsePhasedRelease(version, listing.included),
  };
};

const PHASED_RELEASE_STATES = ["INACTIVE", "ACTIVE", "PAUSED", "COMPLETE"];

// Reads the phased release from the version's JSON:API linkage. Anything
// short of an explicit null linkage or a well-formed included resource is
// rejected, so a malformed response never reads as "no phased release".
const parsePhasedRelease = (version: JsonObject, included: Json | undefined): RemoteVersion["phasedRelease"] => {
  const relationships = version.relationships;
  const relationship = isObject(relationships) ? relationships.appStoreVersionPhasedRelease : undefined;
  if (!isObject(relationship) || !("data" in relationship)) {
    throw new Error("asc versions list did not report the phased-release relationship");
  }
  const linkage = relationship.data;
  if (linkage === null) return undefined;
  if (!isObject(linkage) || linkage.type !== "appStoreVersionPhasedReleases" || typeof linkage.id !== "string") {
    throw new Error("asc versions list returned a malformed phased-release linkage");
  }
  if (!Array.isArray(included)) throw new Error("asc versions list linked a phased release but included none");
  const resource = included.find((candidate) => isObject(candidate) && candidate.type === linkage.type && candidate.id === linkage.id);
  const phasedState = isObject(resource) && isObject(resource.attributes) ? resource.attributes.phasedReleaseState : undefined;
  if (typeof phasedState !== "string" || !PHASED_RELEASE_STATES.includes(phasedState)) {
    throw new Error(`asc versions list returned phased release ${linkage.id} without a known state`);
  }
  return { id: linkage.id, state: phasedState };
};

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const ascBinary = process.env.ASC_BIN ?? "asc";
const ascEnvironment = (): NodeJS.ProcessEnv => ({
  ...process.env,
  ASC_TELEMETRY_DISABLED: "1",
  ASC_SKILLS_AUTO_CHECK: "0",
  ASC_SPINNER_DISABLED: "1",
});

type AscResult = Readonly<{ code: number; stdout: string; stderr: string }>;

const runAsc = (args: readonly string[]): Promise<AscResult> =>
  new Promise((resolvePromise, reject) => {
    execFile(ascBinary, args, { cwd: root, env: ascEnvironment(), maxBuffer: 64 << 20 }, (error, stdout, stderr) => {
      if (error && typeof error.code !== "number") {
        reject(new Error(`could not run ${ascBinary}`, { cause: error }));
        return;
      }
      resolvePromise({ code: typeof error?.code === "number" ? error.code : 0, stdout, stderr });
    });
  });

const asc = async (args: readonly string[]): Promise<string> => {
  const result = await runAsc(args);
  if (result.code !== 0) {
    throw new Error(`asc ${args.slice(0, 2).join(" ")} exited ${result.code}\n${result.stderr.trim()}`);
  }
  return result.stdout;
};

const ascJson = async (args: readonly string[]): Promise<unknown> => JSON.parse(await asc([...args, "--output", "json"]));

let telemetryChecked = false;
const assertTelemetryOff = async (): Promise<void> => {
  if (telemetryChecked) return;
  const status = await ascJson(["telemetry", "status"]);
  if (!isObject(status) || status.enabled !== false) throw new Error("asc telemetry is still enabled; refusing to continue");
  telemetryChecked = true;
};

const exists = async (path: string): Promise<boolean> => {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
};

const loadConfig = async (path: string): Promise<AppStoreConfig> => parseConfig(JSON.parse(await readFile(path, "utf8")));

const report = async (markdown: string): Promise<void> => {
  process.stdout.write(`${markdown}\n`);
  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (summary) await appendFile(summary, `${markdown}\n`);
};

const versionFile = (config: AppStoreConfig, version: string): string =>
  resolve(root, config.metadataDir, "version", version, `${config.primaryLocale}.json`);

const requireWhatsNew = async (config: AppStoreConfig, version: string): Promise<void> => {
  const path = versionFile(config, version);
  if (!(await exists(path))) throw new Error(`${config.metadataDir}/version/${version}/${config.primaryLocale}.json is missing; every version needs its What's New`);
  const localization: unknown = JSON.parse(await readFile(path, "utf8"));
  if (!isObject(localization) || typeof localization.whatsNew !== "string" || localization.whatsNew.trim() === "") {
    throw new Error(`${config.metadataDir}/version/${version}/${config.primaryLocale}.json has no whatsNew`);
  }
};

// Copies each set into its own directory, because asc validates and
// uploads one device type per directory.
const stageScreenshots = async (config: AppStoreConfig): Promise<{ dir: string; sets: { locale: string; set: ScreenshotSet; path: string; count: number }[] }> => {
  const source = resolve(root, config.screenshots.dir);
  const locales = (await readdir(source, { withFileTypes: true })).filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort();
  if (locales.length === 0) throw new Error(`${config.screenshots.dir} has no locale directories`);
  // Validate everything before creating the staging directory, so a rejection leaves nothing behind.
  const plan: { locale: string; assigned: Map<ScreenshotSet, string[]> }[] = [];
  for (const locale of locales) {
    appStoreLocale(locale, `${config.screenshots.dir}/${locale}`);
    plan.push({ locale, assigned: assignScreenshots(config.screenshots.sets, await readdir(join(source, locale))) });
  }
  const staged = await mkdtemp(join(tmpdir(), "putio-app-store-screenshots-"));
  const sets: { locale: string; set: ScreenshotSet; path: string; count: number }[] = [];
  try {
    for (const { locale, assigned } of plan) {
      for (const [set, files] of assigned) {
        const path = join(staged, locale, set.deviceType);
        await mkdir(path, { recursive: true });
        for (const file of files) await copyFile(join(source, locale, file), join(path, file));
        sets.push({ locale, set, path, count: files.length });
      }
    }
  } catch (error) {
    await rm(staged, { recursive: true, force: true });
    throw error;
  }
  return { dir: staged, sets };
};

const check = async (config: AppStoreConfig, version: string | undefined): Promise<string[]> => {
  await assertTelemetryOff();
  const lines: string[] = [];
  const metadataDir = resolve(root, config.metadataDir);
  if (!(await exists(metadataDir))) throw new Error(`${config.metadataDir}/ is missing`);
  await asc(["metadata", "validate", "--dir", metadataDir, "--output", "json"]);
  lines.push(`- Metadata in \`${config.metadataDir}/\` passes \`asc metadata validate\``);
  if (version) {
    await requireWhatsNew(config, version);
    lines.push(`- ${version} has What's New for ${config.primaryLocale}`);
  }
  if (!(await exists(resolve(root, config.screenshots.dir)))) throw new Error(`${config.screenshots.dir}/ is missing`);
  const staged = await stageScreenshots(config);
  try {
    for (const { locale, set, path, count } of staged.sets) {
      await asc(["screenshots", "validate", "--path", path, "--device-type", set.deviceType, "--output", "json"]);
      lines.push(`- ${locale} ${set.deviceType}: ${count} screenshots pass \`asc screenshots validate\``);
    }
  } finally {
    await rm(staged.dir, { recursive: true, force: true });
  }
  return lines;
};

const fetchRemoteVersion = async (config: AppStoreConfig, version: string): Promise<RemoteVersion | undefined> =>
  parseRemoteVersion(
    await ascJson([
      "versions", "list", "--app", config.appId, "--platform", config.platform, "--version", version,
      "--include", "appStoreVersionPhasedRelease",
    ]),
  );

// --app resolves only while one app info is current or being prepared, so it
// fails once a version is in review, rejected, or pending release. The
// version's own declaration has no such ambiguity.
const ageRatingTarget = (config: AppStoreConfig, remote: RemoteVersion | undefined): string[] =>
  remote ? ["--version-id", remote.id] : ["--app", config.appId];

const fetchAgeRating = async (config: AppStoreConfig, remote: RemoteVersion | undefined): Promise<JsonObject> => {
  const declaration = await ascJson(["age-rating", "view", ...ageRatingTarget(config, remote)]);
  if (!isObject(declaration) || !isObject(declaration.data) || !isObject(declaration.data.attributes)) {
    throw new Error("asc age-rating view returned no attributes");
  }
  return declaration.data.attributes;
};

const metadataArgs = (config: AppStoreConfig, version: string): string[] => [
  "metadata", "push", "--app", config.appId, "--version", version, "--platform", config.platform,
  "--dir", resolve(root, config.metadataDir),
];

const formatValue = (value: Json | undefined): string => (value === undefined ? "unset" : JSON.stringify(value));

const plan = async (config: AppStoreConfig, version: string, exportDir: string | undefined): Promise<void> => {
  // Before any read, so a marker left by an earlier export can't vouch for
  // one that fails partway.
  if (exportDir) await rm(join(resolve(root, exportDir), "age-rating.json"), { force: true });
  const lines = [`## App Store plan for ${version}`, "", ...(await check(config, version)), ""];
  const remote = await fetchRemoteVersion(config, version);
  lines.push(remote ? `Version ${version} is \`${remote.state}\`.` : `Version ${version} does not exist yet.`, "");
  const ageRating = await fetchAgeRating(config, remote);
  // Exported first, so a locked version still yields App Store Connect's listing.
  if (exportDir) await exportListing(config, version, remote, ageRating, exportDir);
  requireEditable(version, remote);

  const actions = versionActions(config.version, remote);
  lines.push("### Version settings", "", ...(actions.length > 0 ? actions.map((action) => `- ${describeVersionAction(action)}`) : ["- No change"]), "");

  const changes = ageRatingChanges(config.ageRating, ageRating);
  lines.push(
    "### Age rating",
    "",
    ...(changes.length > 0 ? changes.map((change) => `- \`${change.field}\`: ${formatValue(change.remote)} → ${formatValue(change.desired)}`) : ["- No change"]),
    "",
  );
  const unmanaged = Object.keys(ageRating).filter((field) => AGE_RATING_FIELDS[field] && !(field in config.ageRating));
  if (unmanaged.length > 0) lines.push(`Not managed yet: ${unmanaged.map((field) => `\`${field}\``).join(", ")}.`, "");

  lines.push("### Metadata", "");
  if (remote) {
    lines.push(await asc([...metadataArgs(config, version), "--dry-run", "--output", "markdown"]));
  } else {
    lines.push("Applied after the version is created.");
  }
  await report(lines.join("\n"));
};

const exportListing = async (config: AppStoreConfig, version: string, remote: RemoteVersion | undefined, ageRating: JsonObject, exportDir: string): Promise<void> => {
  const target = resolve(root, exportDir);
  await mkdir(target, { recursive: true });
  if (remote) {
    await asc(["metadata", "pull", "--app", config.appId, "--version", version, "--platform", config.platform, "--dir", join(target, "metadata"), "--force", "--output", "json"]);
  }
  // Last, so its presence means the export is complete.
  await writeFile(join(target, "age-rating.json"), `${JSON.stringify(ageRating, null, 2)}\n`);
};

const apply = async (config: AppStoreConfig, version: string): Promise<void> => {
  await check(config, version);
  const lines = [`## App Store changes for ${version}`, ""];
  let remote = await fetchRemoteVersion(config, version);
  for (const action of versionActions(config.version, remote)) {
    switch (action.kind) {
      case "create":
        await asc(["versions", "create", "--app", config.appId, "--version", version, "--platform", config.platform, "--release-type", action.releaseType, "--output", "json"]);
        remote = await fetchRemoteVersion(config, version);
        if (!remote) throw new Error(`version ${version} is still missing after asc versions create`);
        break;
      case "set-release-type":
        await asc(["versions", "update", "--version-id", requireVersion(remote).id, "--release-type", action.to, "--output", "json"]);
        break;
      case "create-phased-release":
        await asc(["versions", "phased-release", "create", "--version-id", requireVersion(remote).id, "--output", "json"]);
        break;
      case "delete-phased-release":
        await asc(["versions", "phased-release", "delete", "--id", action.id, "--confirm", "--output", "json"]);
        break;
    }
    lines.push(`- Version: ${describeVersionAction(action)}`);
  }

  // --confirm lets asc apply an explicit null, which clears a managed field.
  await asc([...metadataArgs(config, version), "--confirm", "--output", "json"]);
  lines.push(`- Metadata: applied \`${config.metadataDir}/\` for ${version}`);

  const changes = ageRatingChanges(config.ageRating, await fetchAgeRating(config, remote));
  if (changes.length > 0) {
    await asc(["age-rating", "edit", ...ageRatingTarget(config, remote), ...ageRatingFlags(changes), "--output", "json"]);
    for (const change of changes) lines.push(`- Age rating: \`${change.field}\` ${formatValue(change.remote)} → ${formatValue(change.desired)}`);
  }
  await report(lines.join("\n"));
};

const requireVersion = (remote: RemoteVersion | undefined): RemoteVersion => {
  if (!remote) throw new Error("the App Store version is missing");
  return remote;
};

const validate = async (config: AppStoreConfig, version: string, strict: boolean): Promise<number> => {
  await assertTelemetryOff();
  const args = ["validate", "--app", config.appId, "--version", version, "--platform", config.platform, "--output", "markdown"];
  const result = await runAsc(strict ? [...args, "--strict"] : args);
  await report([`## asc validate ${version}`, "", result.stdout.trim() || result.stderr.trim()].join("\n"));
  return result.code;
};

const screenshots = async (config: AppStoreConfig, version: string, dryRun: boolean): Promise<void> => {
  await check(config, version);
  requireEditable(version, await fetchRemoteVersion(config, version));
  const staged = await stageScreenshots(config);
  const lines = [`## Screenshots for ${version}${dryRun ? " (dry run)" : ""}`, ""];
  try {
    for (const { locale, set, path, count } of staged.sets) {
      await asc([
        "screenshots", "upload", "--app", config.appId, "--version", version, "--platform", config.platform,
        "--locale", locale, "--path", path, "--device-type", set.deviceType, "--replace",
        dryRun ? "--dry-run" : "--confirm", "--output", "json",
      ]);
      lines.push(`- ${locale} ${set.deviceType}: ${dryRun ? "would replace the set with" : "replaced the set with"} ${count} screenshots`);
    }
  } finally {
    await rm(staged.dir, { recursive: true, force: true });
  }
  await report(lines.join("\n"));
};

const main = async (): Promise<number> => {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: {
      config: { type: "string", default: "Config/AppStore.json" },
      version: { type: "string" },
      export: { type: "string" },
      confirm: { type: "boolean", default: false },
      "dry-run": { type: "boolean", default: false },
      strict: { type: "boolean", default: false },
    },
  });
  const [command] = positionals;
  const config = await loadConfig(resolve(root, values.config));
  const version = values.version?.replace(/^v/, "");
  if (version !== undefined && !VERSION_PATTERN.test(version)) throw new Error(`--version must look like 3.0.0, got ${version}`);
  const requiredVersion = (): string => {
    if (!version) throw new Error(`${command} needs --version`);
    return version;
  };

  switch (command) {
    case "check":
      await report(["## App Store check", "", ...(await check(config, version))].join("\n"));
      return 0;
    case "plan":
      await plan(config, requiredVersion(), values.export);
      return 0;
    case "apply":
      if (!values.confirm || values["dry-run"]) throw new Error("apply changes App Store Connect; pass --confirm without --dry-run, or use plan");
      await apply(config, requiredVersion());
      return 0;
    case "validate":
      return validate(config, requiredVersion(), values.strict);
    case "screenshots":
      if (values["dry-run"] === values.confirm) throw new Error("screenshots needs exactly one of --dry-run or --confirm");
      await screenshots(config, requiredVersion(), values["dry-run"]);
      return 0;
    default:
      throw new Error("usage: node scripts/app-store.ts <check|plan|apply|validate|screenshots> [--version X.Y.Z]");
  }
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main();
}
