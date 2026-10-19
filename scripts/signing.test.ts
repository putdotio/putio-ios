import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { parse } from "yaml";

const script = (name: string) => fileURLToPath(new URL(`./${name}`, import.meta.url));

const tempDir = async (t: test.TestContext): Promise<string> => {
  const dir = await mkdtemp(join(tmpdir(), "putio-signing-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
};

const run = (command: string, args: string[], options: { cwd?: string; env?: NodeJS.ProcessEnv } = {}) => {
  const result = spawnSync(command, args, { encoding: "utf8", ...options });
  assert.equal(result.error, undefined, `${command} must be installed`);
  return result;
};

const TEAM = "TEAM123456";
const BUNDLE = "com.example.app";
const UUID = "12345678-1234-1234-1234-123456789ABC";

// A throwaway self-signed signer stands in for Apple's: the checker reads the
// payload and never trusts the signature.
const certificate = async (dir: string, name: string) => {
  const made = run("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", `/CN=${name}/OU=${TEAM}`,
    "-keyout", join(dir, `${name}.key`), "-out", join(dir, `${name}.pem`)]);
  assert.equal(made.status, 0, made.stderr);
  const der = spawnSync("openssl", ["x509", "-in", join(dir, `${name}.pem`), "-outform", "DER"]);
  assert.equal(der.status, 0, String(der.stderr));
  const bytes = der.stdout;
  return { base64: bytes.toString("base64"), sha256: createHash("sha256").update(bytes).digest("hex") };
};

type Profile = {
  application?: string;
  prefix?: string;
  team?: string;
  certificate: string;
  expires?: string;
  devices?: boolean;
  debuggable?: boolean;
  uuid?: string;
};

// A signed profile as `asc profiles list --output json` carries it.
const profile = async (dir: string, fields: Profile) => {
  const prefix = fields.prefix ?? TEAM;
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>ApplicationIdentifierPrefix</key><array><string>${prefix}</string></array>
  <key>DeveloperCertificates</key>
  <array><data>${fields.certificate}</data></array>
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key><string>${fields.application ?? `${prefix}.${BUNDLE}`}</string>
    <key>get-task-allow</key>${fields.debuggable ? "<true/>" : "<false/>"}
  </dict>
  <key>ExpirationDate</key><date>${fields.expires ?? "2099-01-01T00:00:00Z"}</date>
  ${fields.devices ? "<key>ProvisionedDevices</key><array><string>00008110-000000000000001E</string></array>" : ""}
  <key>TeamIdentifier</key><array><string>${fields.team ?? TEAM}</string></array>
  <key>UUID</key><string>${fields.uuid ?? UUID}</string>
</dict>
</plist>
`;
  await writeFile(join(dir, "profile.plist"), plist);
  const signed = spawnSync("openssl", ["cms", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", join(dir, "profile.plist"),
    "-signer", join(dir, "signer.pem"), "-inkey", join(dir, "signer.key")]);
  assert.equal(signed.status, 0, String(signed.stderr));
  return { id: fields.uuid ?? UUID, type: "profiles", attributes: { name: `profile ${fields.uuid ?? UUID}`, profileContent: signed.stdout.toString("base64") } };
};

const listing = async (dir: string, profiles: unknown[]) => {
  const path = join(dir, "profiles.json");
  await writeFile(path, JSON.stringify({ data: profiles }));
  return path;
};

const check = (dir: string, path: string, sha256: string) => {
  const output = join(dir, "picked.mobileprovision");
  return { ...run("ruby", [script("check-signing-profile.rb"), path, sha256, BUNDLE, TEAM, output]), output };
};

const signer = (dir: string) => certificate(dir, "signer");

test("the signing profile check picks only an unexpired App Store profile for this app and identity", async (t) => {
  const dir = await tempDir(t);
  await signer(dir);
  const identity = await certificate(dir, "identity");
  const other = await certificate(dir, "other");

  const accepted = check(dir, await listing(dir, [await profile(dir, { certificate: identity.base64 })]), identity.sha256);
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.equal(accepted.stdout.trim(), UUID);
  assert.equal(run("openssl", ["cms", "-verify", "-noverify", "-inform", "DER", "-in", accepted.output]).status, 0, "writes the picked profile");

  const legacyPrefix = check(dir, await listing(dir, [await profile(dir, { certificate: identity.base64, prefix: "PREFIX0001" })]), identity.sha256);
  assert.equal(legacyPrefix.status, 0, `an App ID prefix other than the team ID: ${legacyPrefix.stderr}`);

  const refusals: [string, Omit<Profile, "certificate"> & { certificate?: string }][] = [
    ["another app", { application: `${TEAM}.com.example.other` }],
    ["a wildcard", { application: `${TEAM}.*` }],
    ["another prefix's app", { application: `PREFIX0001.${BUNDLE}` }],
    ["another team", { team: "OTHER12345" }],
    ["another certificate", { certificate: other.base64 }],
    ["an expired profile", { expires: "2001-01-01T00:00:00Z" }],
    ["an ad hoc profile", { devices: true }],
    ["a development profile", { debuggable: true }],
  ];
  for (const [label, fields] of refusals) {
    const refused = check(dir, await listing(dir, [await profile(dir, { certificate: identity.base64, ...fields })]), identity.sha256);
    assert.equal(refused.status, 1, label);
    assert.equal(refused.stdout, "", `${label} prints no UUID`);
  }
  const garbage = { id: "x", attributes: { profileContent: Buffer.from("not a profile").toString("base64") } };
  assert.equal(check(dir, await listing(dir, [garbage]), identity.sha256).status, 1, "an unreadable profile");
  assert.equal(check(dir, await listing(dir, []), identity.sha256).status, 1, "no profiles");
});

test("the signing profile check skips another certificate's profile for the same app", async (t) => {
  const dir = await tempDir(t);
  await signer(dir);
  const identity = await certificate(dir, "identity");
  const other = await certificate(dir, "other");
  const MATCHING = "22222222-2222-2222-2222-222222222222";
  const picked = check(dir, await listing(dir, [
    await profile(dir, { certificate: other.base64, uuid: "11111111-1111-1111-1111-111111111111" }),
    await profile(dir, { certificate: identity.base64, uuid: MATCHING }),
  ]), identity.sha256);
  assert.equal(picked.status, 0, picked.stderr);
  assert.equal(picked.stdout.trim(), MATCHING);
});

// A stand-in asc: keychain install records the modes of the files it was
// handed and answers with a receipt in FAKE_TEAM's team; profiles list serves
// FAKE_LISTING.
const fakeAsc = `#!/bin/bash
echo "$*" >> "$ASC_LOG"
case "$1 $2" in
  "signing keychain")
    [ -z "$FAKE_INSTALL_FAILS" ] || exit 1
    for file in identity identity-password keychain-password; do
      path="$(sed -E "s/.*--$file(-file)? ([^ ]+).*/\\2/" <<< "$*")"
      ls -l "$path" | cut -c1-10 >> "$MODE_LOG"
    done
    printf '{"keychainPath":"x","certificateSha256":"%s","certificateSha1":"ABCDEF","teamId":"%s"}\\n' "$FAKE_SHA256" "$FAKE_TEAM" ;;
  "profiles list") cat "$FAKE_LISTING" ;;
  "profiles local") echo '{}' ;;
  *) exit 1 ;;
esac
`;

test("install-signing exports the picked profile, keeps its secrets private, and refuses another team's identity", async (t) => {
  const dir = await tempDir(t);
  await signer(dir);
  const identity = await certificate(dir, "identity");
  const profiles = await listing(dir, [await profile(dir, { certificate: identity.base64 })]);
  const runnerTemp = join(dir, "runner");
  await mkdir(runnerTemp);
  await writeFile(join(dir, "asc"), fakeAsc);
  await chmod(join(dir, "asc"), 0o755);

  const install = async (team: string, sha256: string, fails = "") => {
    for (const file of ["env", "asc.log", "modes.log"]) await writeFile(join(dir, file), "");
    const result = run("bash", [script("install-signing.sh")], {
      env: {
        PATH: `${dir}:${process.env.PATH}`, ASC_LOG: join(dir, "asc.log"), MODE_LOG: join(dir, "modes.log"),
        FAKE_TEAM: team, FAKE_SHA256: sha256, FAKE_LISTING: profiles, FAKE_INSTALL_FAILS: fails,
        APPLE_DISTRIBUTION_P12: Buffer.from("synthetic p12").toString("base64"), APPLE_DISTRIBUTION_P12_PASSWORD: "canary-password",
        PUTIO_APP_IDENTIFIER: BUNDLE, PUTIO_DEVELOPMENT_TEAM: TEAM, RUNNER_TEMP: runnerTemp, GITHUB_ENV: join(dir, "env"),
      },
    });
    const read = (file: string) => readFile(join(dir, file), "utf8");
    return { ...result, env: await read("env"), calls: await read("asc.log"), modes: await read("modes.log"), left: await readdir(runnerTemp) };
  };

  const installed = await install(TEAM, identity.sha256);
  assert.equal(installed.status, 0, installed.stderr);
  assert.match(installed.env, new RegExp(`^PUTIO_PROVISIONING_PROFILE_UUID=${UUID}$`, "m"));
  assert.match(installed.env, /^PUTIO_SIGNING_CERTIFICATE_SHA1=ABCDEF$/m);
  assert.match(installed.calls, /^signing keychain install .*--add-to-search-list/m, "codesign finds the identity only through the search list");
  assert.match(installed.calls, /profiles list --profile-type IOS_APP_STORE --profile-state ACTIVE .*--paginate/);
  assert.match(installed.calls, /profiles local install --path /);
  assert.doesNotMatch(installed.calls, /--create-missing|--delete-stale-profiles|profiles (create|delete)|certificates/, "never changes App Store Connect");
  assert.doesNotMatch(installed.stdout + installed.stderr + installed.calls + installed.env, /canary-password/);
  assert.deepEqual(installed.modes.trim().split("\n"), ["-rw-------", "-rw-------", "-rw-------"], "the p12 and both passwords are owner-only");
  assert.deepEqual(installed.left, [], "the decoded p12 and passwords are gone after the run");

  const otherTeam = await install("OTHER12345", identity.sha256);
  assert.equal(otherTeam.status, 1);
  assert.doesNotMatch(otherTeam.calls, /profiles list/);
  assert.match(otherTeam.env, /^PUTIO_SIGNING_KEYCHAIN=/m, "cleanup still finds the keychain");
  assert.deepEqual(otherTeam.left, [], "a failed run leaves no secret files either");

  const installFails = await install(TEAM, identity.sha256, "1");
  assert.equal(installFails.status, 1);
  assert.match(installFails.env, /^PUTIO_SIGNING_KEYCHAIN=/m, "cleanup finds a keychain asc left behind when it failed");

  const unmatched = await install(TEAM, "0".repeat(64));
  assert.equal(unmatched.status, 1, "a profile without the identity's certificate is not installed");
  assert.doesNotMatch(unmatched.calls, /profiles local install/);
  assert.doesNotMatch(unmatched.env, /PUTIO_PROVISIONING_PROFILE_UUID/);
});

test("the signing check is a dispatch-only release job on protected main", async () => {
  const workflow = parse(await readFile(new URL("../.github/workflows/signing-check.yml", import.meta.url), "utf8")) as {
    on: Record<string, unknown>;
    jobs: Record<string, { uses?: string; needs?: string; environment?: string; steps?: { name?: string; run?: string; if?: string; env?: Record<string, string> }[] }>;
  };
  assert.deepEqual(Object.keys(workflow.on), ["workflow_dispatch"]);
  assert.equal(workflow.jobs["validate-ref"]?.uses, "./.github/workflows/delivery-ref.yml");
  const job = workflow.jobs.signing;
  assert.ok(job);
  assert.equal(job.needs, "validate-ref");
  assert.equal(job.environment, "release");
  const steps = job.steps ?? [];
  const at = (pattern: RegExp) => steps.findIndex((step) => pattern.test(step.run ?? ""));
  const install = at(/scripts\/install-signing\.sh/);
  // Searching only the new keychain would pass even if codesign couldn't see it.
  const find = at(/security find-identity -v -p codesigning \|[\s\S]*PUTIO_SIGNING_CERTIFICATE_SHA1/);
  const remove = at(/asc signing keychain delete --keychain "\$PUTIO_SIGNING_KEYCHAIN"/);
  assert.ok(install >= 0 && install < find && find < remove, "install, find the identity, then delete the keychain");
  assert.match(String(steps[remove]?.if), /always\(\)/);
  assert.equal(steps[install]?.env?.APPLE_DISTRIBUTION_P12, "${{ secrets.APPLE_DISTRIBUTION_P12 }}");
  assert.equal(steps[install]?.env?.APPLE_DISTRIBUTION_P12_PASSWORD, "${{ secrets.APPLE_DISTRIBUTION_P12_PASSWORD }}");
});

test("signing changes run their tests in the tooling lane", () => {
  for (const path of [".github/workflows/signing-check.yml", "scripts/install-signing.sh", "scripts/check-signing-profile.rb"]) {
    const result = spawnSync("sh", [script("ci-affected.sh")], { encoding: "utf8", input: `${path}\n` });
    assert.match(result.stdout, /^tooling=true$/m, path);
  }
});
