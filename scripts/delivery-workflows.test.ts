import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { parse } from "yaml";

type RecordValue = Record<string, unknown>;

const asRecord = (value: unknown, context: string): RecordValue => {
  assert.equal(typeof value, "object", `${context} must be an object`);
  assert.notEqual(value, null, `${context} must not be null`);
  assert.equal(Array.isArray(value), false, `${context} must not be an array`);
  return value as RecordValue;
};

const recordAt = (record: RecordValue, key: string, context: string): RecordValue =>
  asRecord(record[key], `${context}.${key}`);

const arrayAt = (record: RecordValue, key: string, context: string): readonly unknown[] => {
  const value = record[key];
  assert.equal(Array.isArray(value), true, `${context}.${key} must be an array`);
  return value as readonly unknown[];
};

const loadYaml = async (path: string): Promise<RecordValue> =>
  asRecord(parse(await readFile(new URL(`../${path}`, import.meta.url), "utf8")) as unknown, path);

test("manual delivery validates before entering the release Environment", async () => {
  for (const [name, deliveryJob] of [
    ["beta.yml", "beta"],
    ["release.yml", "release"],
  ] as const) {
    const workflow = await loadYaml(`.github/workflows/${name}`);
    const jobs = recordAt(workflow, "jobs", name);
    const validate = recordAt(jobs, "validate-ref", `${name}.jobs`);
    const delivery = recordAt(jobs, deliveryJob, `${name}.jobs`);
    const validationInputs = recordAt(validate, "with", `${name}.validate-ref`);

    assert.equal(validate.uses, "./.github/workflows/delivery-ref.yml");
    assert.equal(validationInputs.expected_sha, "${{ inputs.expected_sha }}");
    assert.equal("environment" in validate, false);
    assert.equal(delivery.needs, "validate-ref");
    assert.equal(delivery.environment, "release");
    assert.match(JSON.stringify(delivery), /ref.*needs\.validate-ref\.outputs\.sha/);
    assert.doesNotMatch(JSON.stringify(delivery), /ref.*inputs\.expected_sha/);
  }
});

test("the shared guard binds manual dispatch to the protected main event SHA", async () => {
  const workflow = await loadYaml(".github/workflows/delivery-ref.yml");
  assert.deepEqual(recordAt(workflow, "permissions", "delivery-ref.yml"), {
    contents: "read",
  });
  const serialized = JSON.stringify(workflow);
  assert.doesNotMatch(serialized, /environment.*release/);
  assert.doesNotMatch(serialized, /secrets\./);
  assert.doesNotMatch(serialized, /actions\/checkout/);
  assert.match(serialized, /EXPECTED_SHA.*RUN_SHA/);
  assert.match(serialized, /\.protected/);
  assert.match(serialized, /current_sha.*RUN_SHA/);
  assert.match(serialized, /refs\/tags\/\$RELEASE_TAG/);
});

test("beta persists the selected TestFlight groups before distribution", async () => {
  const workflow = await loadYaml(".github/workflows/beta.yml");
  const jobs = recordAt(workflow, "jobs", "beta.yml");
  const beta = recordAt(jobs, "beta", "beta.yml.jobs");
  const steps = arrayAt(beta, "steps", "beta.yml.jobs.beta").map((step, index) =>
    asRecord(step, `beta.yml.jobs.beta.steps[${index}]`),
  );
  const metadata = steps.find((step) => step.name === "Prepare beta metadata");
  assert.notEqual(metadata, undefined);
  const run = String(metadata?.run);
  const newlineGuard = run.indexOf("PUTIO_BETA_GROUPS\" == *$'\\n'*");
  const envWrite = run.indexOf('echo "PUTIO_BETA_GROUPS=$PUTIO_BETA_GROUPS"');
  assert.notEqual(newlineGuard, -1);
  assert.notEqual(envWrite, -1);
  assert.ok(newlineGuard < envWrite, "group newline validation must precede the GITHUB_ENV write");
  assert.match(run.slice(newlineGuard, envWrite), /exit 1/);
});

test("every workflow that runs asc turns its telemetry off first", async () => {
  for (const name of ["beta.yml", "release.yml", "screenshots.yml", "submit.yml", "ci.yml"]) {
    const workflow = await loadYaml(`.github/workflows/${name}`);
    const serialized = JSON.stringify(workflow);
    assert.match(serialized, /install-asc\.sh/, `${name} installs the pinned asc`);
    assert.doesNotMatch(serialized, /brew install/, `${name} must not install asc from Homebrew`);
    assert.doesNotMatch(serialized, /asc web /, `${name} must not use asc web sessions`);
    const env = name === "ci.yml"
      ? recordAt(recordAt(recordAt(workflow, "jobs", name), "verify-tooling", name), "env", name)
      : recordAt(workflow, "env", name);
    assert.equal(env.ASC_TELEMETRY_DISABLED, "1", `${name} sets ASC_TELEMETRY_DISABLED`);
  }
});

test("submission runs from a validated SHA in the release Environment only", async () => {
  const workflow = await loadYaml(".github/workflows/submit.yml");
  const jobs = recordAt(workflow, "jobs", "submit.yml");
  assert.deepEqual(Object.keys(jobs), ["validate-ref", "submit"]);
  const submit = recordAt(jobs, "submit", "submit.yml.jobs");
  assert.equal(submit.needs, "validate-ref");
  assert.equal(submit.environment, "release");
  assert.match(JSON.stringify(submit), /ref.*needs\.validate-ref\.outputs\.sha/);
});

test("release tags only after the upload, as putio-ci with nothing else", async () => {
  const workflow = await loadYaml(".github/workflows/release.yml");
  assert.deepEqual(Object.keys(recordAt(workflow, "on", "release.yml")), ["workflow_dispatch"]);
  const tag = recordAt(recordAt(workflow, "jobs", "release.yml"), "tag", "release.yml.jobs");
  assert.deepEqual(tag.needs, ["validate-ref", "release"]);
  assert.equal(tag.environment, "release");
  assert.equal("permissions" in tag, false, "the tag needs the App token, not a broader GITHUB_TOKEN");
  const steps = arrayAt(tag, "steps", "release.yml.jobs.tag").map((step, index) => asRecord(step, `tag.steps[${index}]`));
  const mint = steps[0] ?? {};
  assert.match(String(mint.uses), /^actions\/create-github-app-token@[0-9a-f]{40}$/);
  const raw = await readFile(new URL("../.github/workflows/release.yml", import.meta.url), "utf8");
  assert.match(raw, /create-github-app-token@[0-9a-f]{40} # v\d+\.\d+\.\d+/, "pin carries its version comment");
  assert.deepEqual(recordAt(mint, "with", "tag.steps[0]"), {
    "client-id": "${{ vars.PUTIO_CI_APP_CLIENT_ID }}",
    "private-key": "${{ secrets.PUTIO_CI_APP_PRIVATE_KEY }}",
    owner: "${{ github.repository_owner }}",
    repositories: "${{ github.event.repository.name }}",
    "permission-contents": "write",
  });
  const serialized = JSON.stringify(tag);
  assert.deepEqual([...new Set(serialized.match(/secrets\.[A-Z_]+/g))], ["secrets.PUTIO_CI_APP_PRIVATE_KEY"]);
  assert.doesNotMatch(serialized, /actions\/checkout/);
  assert.match(JSON.stringify(steps[1]), /GH_TOKEN.*steps\.token\.outputs\.token/);
});

test("asc output piped to the summary still fails the step", async () => {
  for (const name of ["beta.yml", "release.yml", "submit.yml", "screenshots.yml"]) {
    const workflow = await loadYaml(`.github/workflows/${name}`);
    assert.deepEqual(recordAt(workflow, "defaults", name), { run: { shell: "bash" } }, `${name} runs bash with pipefail`);
  }
  // GitHub runs `shell: bash` as `bash -eo pipefail`; its implicit shell drops pipefail.
  const pipe = (flags: string[]) => spawnSync("bash", [...flags, "-c", "false | tee /dev/null"]).status;
  assert.equal(pipe(["-e"]), 0);
  assert.equal(pipe(["-eo", "pipefail"]), 1);
});

test("workflows that change one App Store version queue behind each other", async () => {
  for (const [name, input] of [
    ["release.yml", "version"],
    ["submit.yml", "version"],
    ["screenshots.yml", "app_version"],
  ] as const) {
    const concurrency = recordAt(await loadYaml(`.github/workflows/${name}`), "concurrency", name);
    assert.equal(concurrency.group, `app-store-\${{ inputs.${input} }}`, `${name} must share the per-version group`);
    assert.equal(concurrency["cancel-in-progress"], false, `${name} must not cancel a running delivery`);
  }

  // A key built from "v3.0.0" would not queue behind one built from "3.0.0".
  const screenshots = await loadYaml(".github/workflows/screenshots.yml");
  const job = recordAt(recordAt(screenshots, "jobs", "screenshots.yml"), "screenshots", "screenshots.yml.jobs");
  const first = asRecord(arrayAt(job, "steps", "screenshots.yml.jobs.screenshots")[0], "screenshots first step");
  for (const [version, ok] of [["3.0.0", true], ["v3.0.0", false], ["3.0", false]] as const) {
    const run = spawnSync("bash", ["-e", "-c", String(first.run)], { env: { ...process.env, APP_VERSION: version } });
    assert.equal(run.status === 0, ok, `screenshots must ${ok ? "accept" : "reject"} ${version} before any other step`);
  }
});

test("beta keeps notifying external testers", async () => {
  const raw = await readFile(new URL("../.github/workflows/beta.yml", import.meta.url), "utf8");
  assert.match(raw, /asc publish testflight[^\n]*(\\\n[^\n]*)*--notify/);
});

test("submit checks committed notes and validates the build it submits", async () => {
  const workflow = await loadYaml(".github/workflows/submit.yml");
  const submit = recordAt(recordAt(workflow, "jobs", "submit.yml"), "submit", "submit.yml.jobs");
  const runs = arrayAt(submit, "steps", "submit").map((step) => String(asRecord(step, "step").run ?? ""));
  const at = (pattern: RegExp) => runs.findIndex((run) => pattern.test(run));
  const check = at(/app-store\.ts check --version/);
  const attach = at(/asc versions attach-build[\s\S]*--build-number "\$BUILD_NUMBER"/);
  const validate = at(/app-store\.ts validate --version "\$VERSION" --strict/);
  const send = at(/asc review submit[\s\S]*--build-number "\$BUILD_NUMBER"/);
  const tag = at(/Build-Number: \$BUILD_NUMBER/);
  assert.ok(tag >= 0 && tag < check, "the release tag check comes before anything else uses the build number");
  assert.ok(check >= 0 && check < attach && attach < validate && validate < send, "check, attach, validate, submit in order");
});

const stepRun = async (name: string, job: string, step: string): Promise<string> => {
  const workflow = await loadYaml(`.github/workflows/${name}`);
  const steps = arrayAt(recordAt(recordAt(workflow, "jobs", name), job, `${name}.jobs`), "steps", job).map((entry, index) =>
    asRecord(entry, `${job}.steps[${index}]`),
  );
  const found = steps.find((entry) => entry.name === step);
  assert.ok(found, `${name} ${job} has a "${step}" step`);
  return String(found.run);
};

const tempDir = async (t: test.TestContext): Promise<string> => {
  const dir = await mkdtemp(join(tmpdir(), "putio-delivery-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
};

test("release refuses a version without a non-empty whatsNew before building", async (t) => {
  const run = await stepRun("release.yml", "release", "Prepare release metadata");
  const status = async (localization: unknown) => {
    const dir = await tempDir(t);
    await mkdir(join(dir, "metadata/version/3.0.1"), { recursive: true });
    if (localization !== undefined) await writeFile(join(dir, "metadata/version/3.0.1/en-US.json"), JSON.stringify(localization));
    for (const file of ["env", "output"]) await writeFile(join(dir, file), "");
    return spawnSync("bash", ["-eo", "pipefail", "-c", run], {
      cwd: dir,
      env: { PATH: process.env.PATH, RELEASE_VERSION: "3.0.1", GITHUB_ENV: join(dir, "env"), GITHUB_OUTPUT: join(dir, "output"), RUNNER_TEMP: dir },
    }).status;
  };
  assert.equal(await status({ whatsNew: "Faster folders." }), 0);
  for (const localization of [undefined, {}, { whatsNew: "" }, { whatsNew: 7 }, { whatsNew: null }, { description: "x" }]) {
    assert.equal(await status(localization), 1, JSON.stringify(localization));
  }
});

// A stand-in gh that serves the tag ref and tag object from FAKE_REF and
// FAKE_TAG, logs each call on one line (newlines escaped), and answers
// git/tags POSTs with tag object t1.
const fakeGh = `#!/bin/bash
args="$*"
printf '%s\\n' "\${args//$'\\n'/\\\\n}" >> "$GH_LOG"
case "$*" in
  *"--method POST"*"/git/tags"*) echo '{"sha":"t1"}' ;;
  *"--method POST"*) echo '{}' ;;
  *"/git/ref/tags/"*) [ -n "$FAKE_REF" ] || { echo "Not Found" >&2; exit 1; }; printf '%s\\n' "$FAKE_REF" ;;
  *"/git/tags/"*) printf '%s\\n' "$FAKE_TAG" ;;
  *) exit 1 ;;
esac
`;

const SHA = "a".repeat(40);
const annotatedRef = JSON.stringify({ object: { type: "tag", sha: "t1" } });
const lightweightRef = JSON.stringify({ object: { type: "commit", sha: SHA } });
const tagObject = (sha: string, build: string) => JSON.stringify({ object: { type: "commit", sha }, message: `put.io 3.0.1\n\nBuild-Number: ${build}\n` });

const runWithGh = async (t: test.TestContext, run: string, env: Record<string, string>) => {
  const dir = await tempDir(t);
  await writeFile(join(dir, "gh"), fakeGh);
  await chmod(join(dir, "gh"), 0o755);
  await writeFile(join(dir, "gh.log"), "");
  const result = spawnSync("bash", ["-eo", "pipefail", "-c", run], {
    encoding: "utf8",
    env: { PATH: `${dir}:${process.env.PATH}`, GH_LOG: join(dir, "gh.log"), GITHUB_REPOSITORY: "putdotio/putio-ios", GITHUB_STEP_SUMMARY: join(dir, "summary"), ...env },
  });
  return { status: result.status, stderr: result.stderr, calls: (await readFile(join(dir, "gh.log"), "utf8")).split("\n").filter(Boolean) };
};

test("release tags with an annotated tag that names the uploaded build", async (t) => {
  const run = await stepRun("release.yml", "tag", "Create v${{ inputs.version }}");
  const env = { RELEASE_VERSION: "3.0.1", SHA, BUILD_NUMBER: "2610191230" };

  const created = await runWithGh(t, run, { ...env, FAKE_REF: "" });
  assert.equal(created.status, 0, created.stderr);
  const tagPost = created.calls.find((call) => call.includes("--method POST") && call.includes("/git/tags"));
  assert.ok(tagPost, "creates a tag object");
  assert.match(tagPost, new RegExp(`object=${SHA}`));
  assert.match(tagPost, /message=put\.io 3\.0\.1\\n\\nBuild-Number: 2610191230$/m);
  assert.ok(created.calls.some((call) => call.includes("ref=refs/tags/v3.0.1") && call.includes("sha=t1")), "the ref points at the tag object");

  const rerun = await runWithGh(t, run, { ...env, FAKE_REF: annotatedRef, FAKE_TAG: tagObject(SHA, "2610191230") });
  assert.equal(rerun.status, 0, rerun.stderr);
  assert.equal(rerun.calls.some((call) => call.includes("--method POST")), false, "a re-run of the same build changes nothing");

  const refusals: [string, string][] = [[annotatedRef, tagObject("b".repeat(40), "2610191230")], [annotatedRef, tagObject(SHA, "2610181200")], [lightweightRef, ""]];
  for (const [ref, tag] of refusals) {
    const refused = await runWithGh(t, run, { ...env, FAKE_REF: ref, FAKE_TAG: tag });
    assert.equal(refused.status, 1, `${ref} ${tag}`);
    assert.equal(refused.calls.some((call) => call.includes("--method POST")), false);
  }
});

test("submit attaches only the build the release tag names, at the validated SHA", async (t) => {
  const run = await stepRun("submit.yml", "submit", "Check the release tag names this build");
  const env = { VERSION: "3.0.1", BUILD_NUMBER: "2610191230", EXPECTED_SHA: SHA };
  const status = async (ref: string, tag: string) => (await runWithGh(t, run, { ...env, FAKE_REF: ref, FAKE_TAG: tag })).status;

  assert.equal(await status(annotatedRef, tagObject(SHA, "2610191230")), 0);
  assert.equal(await status(annotatedRef, tagObject("b".repeat(40), "2610191230")), 1, "the tag must point at expected_sha");
  assert.equal(await status(annotatedRef, tagObject(SHA, "2610181200")), 1, "the tag must name build_number");
  assert.equal(await status(annotatedRef, tagObject(SHA, "26101912300")), 1, "a prefix of another build number is not a match");
  assert.equal(await status(lightweightRef, ""), 1, "a lightweight tag names no build");
  assert.equal(await status("", ""), 1, "a missing tag fails");
});

test("delivery workflow changes run their contract tests in the tooling lane", () => {
  const script = fileURLToPath(new URL("./ci-affected.sh", import.meta.url));
  for (const name of ["beta.yml", "release.yml", "screenshots.yml", "submit.yml", "delivery-ref.yml"]) {
    const result = spawnSync("sh", [script], { encoding: "utf8", input: `.github/workflows/${name}\n` });
    assert.match(result.stdout, /^tooling=true$/m, name);
  }
});

test("macOS delivery checkouts keep no GitHub token on disk", async () => {
  for (const [name, job] of [["beta.yml", "beta"], ["release.yml", "release"]] as const) {
    const workflow = await loadYaml(`.github/workflows/${name}`);
    const steps = arrayAt(recordAt(recordAt(workflow, "jobs", name), job, name), "steps", job).map((step) => asRecord(step, "step"));
    const checkouts = steps.filter((step) => String(step.uses).startsWith("actions/checkout@"));
    assert.equal(checkouts.length, 1, name);
    assert.equal(recordAt(checkouts[0] ?? {}, "with", name)["persist-credentials"], false, name);
  }
});

test("nothing runs fastlane or match: Beta and Release sign with asc and the release Environment's p12", async () => {
  await assert.rejects(readFile(new URL("../fastlane/Fastfile", import.meta.url)), { code: "ENOENT" });
  for (const file of ["Gemfile", "Gemfile.lock", ".github/actions/load-ios-release-secrets/action.yml", "scripts/archive-ios.sh"]) {
    assert.doesNotMatch(await readFile(new URL(`../${file}`, import.meta.url), "utf8"), /fastlane|MATCH_|PUTIO_APPLE_ID|PUTIO_ITC_TEAM_ID/i, file);
  }
  for (const [name, job] of [["beta.yml", "beta"], ["release.yml", "release"]] as const) {
    const raw = await readFile(new URL(`../.github/workflows/${name}`, import.meta.url), "utf8");
    assert.doesNotMatch(raw, /fastlane|MATCH_|PUTIO_APPLE_ID|PUTIO_ITC_TEAM_ID/i, name);
    const workflow = await loadYaml(`.github/workflows/${name}`);
    const steps = arrayAt(recordAt(recordAt(workflow, "jobs", name), job, name), "steps", job).map((step) => asRecord(step, "step"));
    const at = (pattern: RegExp) => steps.findIndex((step) => pattern.test(String(step.run ?? "")));
    const asc = at(/install-asc\.sh/);
    const signing = at(/scripts\/install-signing\.sh/);
    const archive = at(/scripts\/archive-ios\.sh/);
    const cleanup = at(/asc signing keychain delete --keychain "\$PUTIO_SIGNING_KEYCHAIN"/);
    assert.ok(asc >= 0 && asc < signing && signing < archive && archive < cleanup, `${name}: asc, signing, archive, then delete the keychain`);
    assert.equal(cleanup, steps.length - 1, `${name}: deleting the keychain can't hold back the upload`);
    assert.match(String(steps[cleanup]?.if), /always\(\)/);
    assert.deepEqual(
      Object.entries(recordAt(steps[signing] ?? {}, "env", name)).filter(([key]) => key.startsWith("APPLE_")),
      [["APPLE_DISTRIBUTION_P12", "${{ secrets.APPLE_DISTRIBUTION_P12 }}"], ["APPLE_DISTRIBUTION_P12_PASSWORD", "${{ secrets.APPLE_DISTRIBUTION_P12_PASSWORD }}"]],
    );
  }
});

// Stand-ins for xcodebuild and plutil: xcodebuild logs its arguments, keeps
// the export options it was handed, and exports one ipa.
const fakeXcodebuild = `#!/bin/bash
echo "$*" >> "$XCODEBUILD_LOG"
if [ "$1" = -exportArchive ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -exportOptionsPlist) cp "$2" "$EXPORT_OPTIONS" ;;
      -exportPath) mkdir -p "$2" && touch "$2/Putio.ipa" ;;
    esac
    shift
  done
fi
`;

test("the archive signs and exports with the profile install-signing.sh checked", async (t) => {
  const dir = await tempDir(t);
  await writeFile(join(dir, "xcodebuild"), fakeXcodebuild);
  await writeFile(join(dir, "plutil"), "#!/bin/sh\n");
  for (const tool of ["xcodebuild", "plutil"]) await chmod(join(dir, tool), 0o755);
  const archive = (env: Record<string, string>) =>
    spawnSync("bash", [fileURLToPath(new URL("./archive-ios.sh", import.meta.url)), "3.0.1", "1", join(dir, "a.ipa")], {
      encoding: "utf8",
      env: {
        PATH: `${dir}:${process.env.PATH}`, XCODEBUILD_LOG: join(dir, "xcodebuild.log"), EXPORT_OPTIONS: join(dir, "ExportOptions.plist"),
        PUTIO_APP_IDENTIFIER: "com.example.app", PUTIO_DEVELOPMENT_TEAM: "TEAM123456", PUTIO_PRIMARY_APP_ICON: "AppIcon", ...env,
      },
    });

  const missing = archive({});
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /PUTIO_PROVISIONING_PROFILE_UUID/, "an archive without the checked profile stops before xcodebuild");

  const uuid = "12345678-1234-1234-1234-123456789ABC";
  const signed = archive({ PUTIO_PROVISIONING_PROFILE_UUID: uuid });
  assert.equal(signed.status, 0, signed.stderr);
  assert.match(await readFile(join(dir, "xcodebuild.log"), "utf8"), new RegExp(`archive.*PROVISIONING_PROFILE_SPECIFIER=${uuid}|PROVISIONING_PROFILE_SPECIFIER=${uuid}.*archive`));
  assert.match(await readFile(join(dir, "ExportOptions.plist"), "utf8"), new RegExp(`<key>com\\.example\\.app</key>\\s*<string>${uuid}</string>`));
});

test("screenshots upload the listing after a failed Plan, but don't validate again", async () => {
  const workflow = await loadYaml(".github/workflows/screenshots.yml");
  const job = recordAt(recordAt(workflow, "jobs", "screenshots.yml"), "screenshots", "screenshots.yml.jobs");
  const steps = arrayAt(job, "steps", "screenshots").map((step) => asRecord(step, "step"));
  const named = (name: string) => steps.find((step) => step.name === name) ?? {};
  assert.equal(named("Plan").id, "plan");
  assert.match(String(named("Upload the current App Store Connect listing").if), /!cancelled\(\)/);
  assert.match(String(named("Validate submission readiness").if), /steps\.plan\.outcome == 'success'/);
});

const validSentryDsn = "https://synthetickey@o0.ingest.example.invalid/5282170";

// Runs the release preflight with every required secret set to a valid
// synthetic value, then the overrides.
const releasePreflight = async () => {
  const action = await loadYaml(".github/actions/load-ios-release-secrets/action.yml");
  const steps = arrayAt(recordAt(action, "runs", "action.yml"), "steps", "action.yml.runs");
  const preflight = steps
    .map((step, index) => asRecord(step, `action.yml.runs.steps[${index}]`))
    .find((step) => step.name === "Require release environment secrets");
  assert.ok(preflight, "action.yml must have a 'Require release environment secrets' step");
  const run = String(preflight.run);
  const secrets = Object.fromEntries([...run.matchAll(/^\s+([A-Z][A-Z0-9_]*)$/gm)].map(([, name]) => [name, "synthetic"]));
  return (overrides: Record<string, string>) =>
    spawnSync("bash", ["-c", run], {
      encoding: "utf8",
      env: { PATH: process.env.PATH, ...secrets, PUTIO_SENTRY_DSN: validSentryDsn, ...overrides },
    });
};

test("release builds fail without a Sentry DSN for project ios", async () => {
  const preflight = await releasePreflight();
  const status = (dsn: string) => preflight({ PUTIO_SENTRY_DSN: dsn }).status;

  assert.equal(status(validSentryDsn), 0);
  for (const dsn of [
    "",
    "not a dsn",
    "https://synthetickey@o0.ingest.example.invalid/5282171",
    "https://synthetickey@o0.ingest.example.invalid?x=/5282170",
  ]) {
    assert.equal(status(dsn), 1, dsn);
  }
});

test("release builds fail without well-formed Intercom keys", async () => {
  const preflight = await releasePreflight();

  for (const name of ["PUTIO_INTERCOM_API_KEY", "PUTIO_INTERCOM_APP_ID"]) {
    assert.equal(preflight({ [name]: "Synthetic.key_0:a-z" }).status, 0, name);
    for (const value of ["", "null", "canary value", "canary\n", "'canary'", "canary/key"]) {
      const result = preflight({ [name]: value });
      assert.equal(result.status, 1, `${name}=${JSON.stringify(value)}`);
      assert.match(result.stderr, new RegExp(name));
      assert.doesNotMatch(result.stdout + result.stderr, /canary/, "the preflight must not print the value");
    }
  }
});
