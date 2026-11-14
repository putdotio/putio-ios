import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { buildManifest, configPath, parseConfig, resolvedPins, resolveRepository } from "./open-source-licenses.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const configText = await readFile(join(root, configPath), "utf8");
const config = () => parseConfig(JSON.parse(configText));

test("every bundled package in the resolved graph gets one notice with its resolved version", async () => {
  const resolved = await resolveRepository(root);
  const manifest = buildManifest(config(), resolved);
  const sdk = JSON.parse(await readFile(join(root, "Packages/PutioCore/Package.resolved"), "utf8"));
  const sentry = await readFile(join(root, "Packages/SentrySDK/Package.swift"), "utf8");
  const tuist = JSON.parse(await readFile(join(root, "Tuist/Package.resolved"), "utf8"));
  const pinned = (identity: string) =>
    tuist.pins.find((pin: { identity: string }) => pin.identity === identity)?.state.version;
  assert.deepEqual(
    manifest.packages.map((notice) => `${notice.name} ${notice.version}`).sort(),
    [
      `AetherEngine ${/AetherEngine", exact: "([^"]+)"/.exec(await readFile(join(root, "Tuist/Package.swift"), "utf8"))?.[1]}`,
      `FFmpeg ${pinned("ffmpegbuild")}`,
      `Google Cast SDK ${/ios-(\d+\.\d+\.\d+)_/.exec(await readFile(join(root, "Packages/GoogleCastSDK/Package.swift"), "utf8"))?.[1]}`,
      `Intercom ${/intercom-ios-sp", exact: "([^"]+)"/.exec(await readFile(join(root, "Tuist/Package.swift"), "utf8"))?.[1]}`,
      `SMBClient ${pinned("smbclient")}`,
      `libdovi ${pinned("libdovi")}`,
      `Sentry ${/download\/([^/]+)\//.exec(sentry)?.[1]}`,
      `putio-sdk-swift ${sdk.pins[0].state.version}`,
    ].sort(),
  );
});

test("a resolved package with no notice stops generation", async () => {
  const resolved = await resolveRepository(root);
  resolved.set("swift-new-dependency", "1.0.0");
  assert.throws(() => buildManifest(config(), resolved), /swift-new-dependency is bundled but has no notice/);
});

test("a notice for a package that is no longer resolved stops generation", async () => {
  const resolved = await resolveRepository(root);
  resolved.delete("intercom-ios-sp");
  assert.throws(() => buildManifest(config(), resolved), /intercom-ios-sp has a notice but is not resolved/);
});

test("one package resolved to two versions stops generation", () => {
  const pin = (version: string) =>
    JSON.stringify({ pins: [{ identity: "swift-syntax", state: { version } }] });
  assert.throws(() => resolvedPins([pin("604.0.0"), pin("605.0.0")]), /swift-syntax resolves to both 604.0.0 and 605.0.0/);
});

test("notices accept only https links", () => {
  const raw = JSON.parse(configText);
  raw.packages.SentrySDK.licenseText = "http://example.com/LICENSE";
  assert.throws(() => parseConfig(raw), /SentrySDK.licenseText must be an https URL/);
});
