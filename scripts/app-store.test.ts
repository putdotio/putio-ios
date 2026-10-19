import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, mkdir, mkdtemp, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { crc32, deflateSync } from "node:zlib";

import type { AppStoreConfig, RemoteVersion } from "./app-store.ts";
import {
  ageRatingChanges,
  ageRatingFlags,
  assignScreenshots,
  parseConfig,
  parseRemoteVersion,
  versionActions,
} from "./app-store.ts";

const validConfig = {
  appId: "1260479699",
  platform: "IOS",
  primaryLocale: "en-US",
  metadataDir: "metadata",
  version: { releaseType: "MANUAL", phasedRelease: true },
  ageRating: { socialMedia: false, socialMediaAgeRestricted: false },
  screenshots: {
    dir: "screenshots",
    sets: [
      { deviceType: "IPHONE_69", prefix: "iphone-6.9-" },
      { deviceType: "IPAD_PRO_3GEN_129", prefix: "ipad-13-" },
    ],
  },
};

const config = parseConfig(validConfig);

test("config rejects what App Store Connect would not accept", () => {
  assert.throws(() => parseConfig({ ...validConfig, appId: "com.putio.tvOS" }), /numeric/);
  assert.throws(() => parseConfig({ ...validConfig, version: { releaseType: "SCHEDULED", phasedRelease: true } }), /MANUAL or AFTER_APPROVAL/);
  assert.throws(() => parseConfig({ ...validConfig, ageRating: { socialMedia: "false" } }), /must be a boolean/);
  assert.throws(() => parseConfig({ ...validConfig, ageRating: { violenceRealistic: "SOME" } }), /one of NONE/);
  assert.equal(parseConfig({ ...validConfig, ageRating: { violenceRealistic: "INFREQUENT" } }).ageRating.violenceRealistic, "INFREQUENT");
  assert.throws(() => parseConfig({ ...validConfig, ageRating: { seventeenPlus: true } }), /not a supported/);
  assert.throws(() => parseConfig({ ...validConfig, releaseType: "MANUAL" }), /unknown key releaseType/);
  assert.throws(() => parseConfig({ ...validConfig, primaryLocale: "en_US" }), /en_US is not an App Store locale/);
  assert.throws(
    () => parseConfig({ ...validConfig, screenshots: { dir: "s", sets: [{ deviceType: "A", prefix: "ip" }, { deviceType: "B", prefix: "ipad-" }] } }),
    /prefix ip also matches ipad-/,
  );
});

test("only drifted age-rating answers become asc flags, under asc's flag names", () => {
  const desired = { socialMedia: false, socialMediaAgeRestricted: false, horrorOrFearThemes: "NONE" };
  const changes = ageRatingChanges(desired, { socialMedia: null, socialMediaAgeRestricted: false, horrorOrFearThemes: "INFREQUENT_OR_MILD" });
  assert.deepEqual(ageRatingFlags(changes), ["--social-media", "false", "--horror-fear", "NONE"]);
  assert.deepEqual(ageRatingChanges(desired, { socialMedia: false, socialMediaAgeRestricted: false, horrorOrFearThemes: "NONE" }), []);
});

const remote = (overrides: Partial<RemoteVersion> = {}): RemoteVersion => ({
  id: "v1",
  state: "PREPARE_FOR_SUBMISSION",
  releaseType: "MANUAL",
  phasedRelease: { id: "p1", state: "INACTIVE" },
  ...overrides,
});

test("version settings converge on the config and stop at a no-op", () => {
  assert.deepEqual(versionActions(config.version, undefined), [
    { kind: "create", releaseType: "MANUAL" },
    { kind: "create-phased-release" },
  ]);
  assert.deepEqual(versionActions(config.version, remote({ releaseType: "AFTER_APPROVAL", phasedRelease: undefined })), [
    { kind: "set-release-type", from: "AFTER_APPROVAL", to: "MANUAL" },
    { kind: "create-phased-release" },
  ]);
  assert.deepEqual(versionActions(config.version, remote()), []);

  const off: AppStoreConfig["version"] = { releaseType: "MANUAL", phasedRelease: false };
  assert.deepEqual(versionActions(off, remote()), [{ kind: "delete-phased-release", id: "p1" }]);
  assert.throws(() => versionActions(off, remote({ phasedRelease: { id: "p1", state: "ACTIVE" } })), /ACTIVE/);
});

const linked = (phased: unknown) => ({ appStoreVersionPhasedRelease: { data: phased } });

test("remote version listings parse with and without a phased release", () => {
  assert.equal(parseRemoteVersion({ data: [] }), undefined);
  assert.deepEqual(
    parseRemoteVersion({
      data: [{
        id: "v1",
        attributes: { appVersionState: "PREPARE_FOR_SUBMISSION", releaseType: "MANUAL" },
        relationships: linked({ type: "appStoreVersionPhasedReleases", id: "p1" }),
      }],
      included: [{ type: "appStoreVersionPhasedReleases", id: "p1", attributes: { phasedReleaseState: "INACTIVE" } }],
    }),
    remote(),
  );
  assert.equal(
    parseRemoteVersion({ data: [{ id: "v1", attributes: { appStoreState: "READY_FOR_SALE" }, relationships: linked(null) }] })?.phasedRelease,
    undefined,
  );
  assert.throws(() => parseRemoteVersion({ data: [{ id: "a", attributes: {} }, { id: "b", attributes: {} }] }), /more than one/);
});

test("a malformed phased-release response is rejected, never read as absent", () => {
  const version = (relationships: unknown) => ({ id: "v1", attributes: { releaseType: "MANUAL" }, relationships });
  const link = { type: "appStoreVersionPhasedReleases", id: "p1" };
  assert.throws(() => parseRemoteVersion({ data: [version(undefined)] }), /did not report the phased-release relationship/);
  assert.throws(() => parseRemoteVersion({ data: [version(linked({ id: 7 }))] }), /malformed phased-release linkage/);
  assert.throws(() => parseRemoteVersion({ data: [version(linked(link))], included: "nope" }), /included none/);
  assert.throws(() => parseRemoteVersion({ data: [version(linked(link))], included: [] }), /without a known state/);
  assert.throws(
    () => parseRemoteVersion({ data: [version(linked(link))], included: [{ type: link.type, id: "p1", attributes: { phasedReleaseState: 3 } }] }),
    /without a known state/,
  );
});

test("every screenshot lands in exactly one set within Apple's limit", () => {
  const assigned = assignScreenshots(config.screenshots.sets, ["ipad-13-01.jpg", "iphone-6.9-02.jpg", "iphone-6.9-01.jpg", ".DS_Store"]);
  assert.deepEqual([...assigned.values()], [["iphone-6.9-01.jpg", "iphone-6.9-02.jpg"], ["ipad-13-01.jpg"]]);
  assert.throws(() => assignScreenshots(config.screenshots.sets, ["watch-01.png"]), /match no configured set: watch-01.png/);
  assert.throws(() => assignScreenshots(config.screenshots.sets, ["iphone-6.9-01.jpg"]), /IPAD_PRO_3GEN_129 has no screenshots/);
  const eleven = ["iphone-6.9-01.jpg", ...Array.from({ length: 11 }, (_, index) => `ipad-13-${String(index).padStart(2, "0")}.png`)];
  assert.throws(() => assignScreenshots(config.screenshots.sets, eleven), /11 screenshots/);
});

// A solid-colour RGB PNG; the colour keeps asc's duplicate-pixel check quiet.
const png = (width: number, height: number, shade: number): Buffer => {
  const chunk = (type: string, data: Buffer): Buffer => {
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header.set([8, 2, 0, 0, 0], 8);
  const row = Buffer.alloc(1 + width * 3, shade);
  row[0] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(Array.from({ length: height }, () => row)))),
    chunk("IEND", Buffer.alloc(0)),
  ]);
};

const run = promisify(execFile);
const script = fileURLToPath(new URL("./app-store.ts", import.meta.url));
const ascAvailable = await run(process.env.ASC_BIN ?? "asc", ["version"], { env: { ...process.env, ASC_TELEMETRY_DISABLED: "1" } }).then(
  () => true,
  () => false,
);
// CI sets PUTIO_REQUIRE_ASC so a missing binary fails instead of skipping.
const requireAsc = process.env.PUTIO_REQUIRE_ASC === "1";

test("check runs the pinned asc against the listing offline", { skip: !ascAvailable && !requireAsc && "asc is not installed" }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "putio-app-store-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const fixture = { ...validConfig, metadataDir: join(dir, "metadata"), screenshots: { ...validConfig.screenshots, dir: join(dir, "screenshots") } };
  await writeFile(join(dir, "AppStore.json"), JSON.stringify(fixture));
  await mkdir(join(dir, "metadata/app-info"), { recursive: true });
  await mkdir(join(dir, "metadata/version/3.0.0"), { recursive: true });
  await mkdir(join(dir, "screenshots/en-US"), { recursive: true });
  await writeFile(join(dir, "metadata/app-info/en-US.json"), JSON.stringify({ name: "put.io" }));
  await writeFile(join(dir, "screenshots/en-US/iphone-6.9-01.png"), png(1320, 2868, 40));
  await writeFile(join(dir, "screenshots/en-US/ipad-13-01.png"), png(2064, 2752, 80));

  const check = (version: string) => run(process.execPath, [script, "check", "--config", join(dir, "AppStore.json"), "--version", version], { env: { ...process.env, GITHUB_STEP_SUMMARY: "" } });
  const version = (whatsNew: string) => writeFile(join(dir, "metadata/version/3.0.0/en-US.json"), JSON.stringify({ description: "Your put.io files, on your iPhone and iPad.", whatsNew }));

  await version("Faster folders.");
  const { stdout } = await check("3.0.0");
  assert.match(stdout, /en-US IPHONE_69: 1 screenshots pass/);
  assert.match(stdout, /en-US IPAD_PRO_3GEN_129: 1 screenshots pass/);

  await assert.rejects(check("3.1.0"), /version\/3\.1\.0\/en-US\.json is missing/);
  await assert.rejects(
    run(process.execPath, [script, "apply", "--config", join(dir, "AppStore.json"), "--version", "3.0.0", "--confirm", "--dry-run"]),
    /without --dry-run/,
  );
  await version("x".repeat(4001));
  await assert.rejects(check("3.0.0"), /asc metadata validate exited/);
  await version("Faster folders.");
  await writeFile(join(dir, "screenshots/en-US/ipad-13-02.png"), png(1320, 2868, 120));
  await assert.rejects(check("3.0.0"), /asc screenshots validate exited/);
});

// A stand-in asc that records every invocation and answers with canned JSON,
// so the tests can see exactly which App Store Connect calls each command makes.
const fakeAsc = `#!/bin/sh
printf '%s\\n' "$*" >> "$ASC_LOG"
case "$1 $2" in
  "telemetry status") echo '{"enabled":false}' ;;
  "versions list") echo '{"data":[{"id":"v1","attributes":{"appVersionState":"PREPARE_FOR_SUBMISSION","releaseType":"AFTER_APPROVAL"},"relationships":{"appStoreVersionPhasedRelease":{"data":null}}}]}' ;;
  "age-rating view") echo '{"data":{"id":"a1","attributes":{"socialMedia":true,"socialMediaAgeRestricted":false}}}' ;;
  "metadata push") case "$*" in *--dry-run*) echo "no changes" ;; *) echo '{}' ;; esac ;;
  *) echo '{}' ;;
esac
`;

const MUTATING = /^(versions (create|update|phased-release (create|delete))|age-rating edit|screenshots upload|review submit|publish )/;

const recordingFixture = async (t: test.TestContext) => {
  const dir = await mkdtemp(join(tmpdir(), "putio-app-store-fake-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await writeFile(join(dir, "asc"), fakeAsc);
  await chmod(join(dir, "asc"), 0o755);
  await mkdir(join(dir, "metadata/version/3.0.0"), { recursive: true });
  await mkdir(join(dir, "screenshots/en-US"), { recursive: true });
  await writeFile(join(dir, "metadata/version/3.0.0/en-US.json"), JSON.stringify({ whatsNew: "Faster folders." }));
  await writeFile(join(dir, "screenshots/en-US/iphone-6.9-01.png"), "");
  await writeFile(join(dir, "screenshots/en-US/ipad-13-01.png"), "");
  const configPath = join(dir, "AppStore.json");
  await writeFile(configPath, JSON.stringify({ ...validConfig, metadataDir: join(dir, "metadata"), screenshots: { ...validConfig.screenshots, dir: join(dir, "screenshots") } }));
  const log = join(dir, "asc.log");
  await writeFile(log, "");
  const invoke = (...args: string[]) =>
    run(process.execPath, [script, ...args, "--config", configPath, "--version", "3.0.0"], {
      env: { ...process.env, ASC_BIN: join(dir, "asc"), ASC_LOG: log, GITHUB_STEP_SUMMARY: "" },
    });
  const calls = async () => (await readFile(log, "utf8")).split("\n").filter(Boolean);
  return { dir, invoke, calls };
};

test("apply without --confirm calls asc not once", async (t) => {
  const { invoke, calls } = await recordingFixture(t);
  await assert.rejects(invoke("apply"), /pass --confirm/);
  assert.deepEqual(await calls(), []);
});

test("check and plan only read from App Store Connect", async (t) => {
  const { invoke, calls } = await recordingFixture(t);
  await invoke("check");
  await invoke("plan");
  const made = await calls();
  assert.ok(made.some((call) => call.startsWith("versions list")), "plan reads the version");
  assert.deepEqual(made.filter((call) => MUTATING.test(call)), []);
  for (const push of made.filter((call) => call.startsWith("metadata push"))) assert.match(push, /--dry-run/);
});

test("apply confirms the metadata push and only changes what drifted", async (t) => {
  const { invoke, calls } = await recordingFixture(t);
  await invoke("apply", "--confirm");
  const made = (await calls()).filter((call) => MUTATING.test(call) || call.startsWith("metadata push"));
  assert.deepEqual(made.map((call) => call.split(" --")[0]), [
    "versions update",
    "versions phased-release create",
    "metadata push",
    "age-rating edit",
  ]);
  assert.match(made[2] ?? "", /--confirm/);
  assert.doesNotMatch(made[2] ?? "", /--dry-run/);
  assert.match(made[3] ?? "", /--social-media false/);
  assert.doesNotMatch(made[3] ?? "", /social-media-age-restricted/);
});

test("check rejects a screenshot locale App Store Connect doesn't know", async (t) => {
  const { dir, invoke } = await recordingFixture(t);
  await rename(join(dir, "screenshots/en-US"), join(dir, "screenshots/en_US"));
  const staging = async () => (await readdir(tmpdir())).filter((name) => name.startsWith("putio-app-store-screenshots-")).sort();
  const before = await staging();
  await assert.rejects(invoke("check"), /screenshots\/en_US: en_US is not an App Store locale/);
  assert.deepEqual(await staging(), before, "a rejected locale leaves no staging directory");
});

test("check fails when the configured screenshot directory is missing", async (t) => {
  const { dir, invoke, calls } = await recordingFixture(t);
  await rm(join(dir, "screenshots"), { recursive: true });
  await assert.rejects(invoke("check"), /screenshots\/ is missing/);
  assert.equal((await calls()).some((call) => call.startsWith("screenshots validate")), false);
});
